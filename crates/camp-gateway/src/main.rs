// Public items in pricing/tap are intentional API surface; silence dead_code in this binary crate.
#![allow(dead_code)]
//! camp-gateway — TAP-payment layer in front of the camp REST API.
//!
//! Every request must carry a signed EIP-712 TAP receipt in the `TAP-Receipt`
//! header. The gateway validates the receipt, persists it, and proxies the
//! request to the configured upstream camp instance. Background tasks aggregate
//! receipts into RAVs every 60s and call CampDataService.collect() hourly.
//!
//! DISCLAIMER: This is an experimental community project. It is not affiliated
//! with or endorsed by The Graph Foundation or Edge & Node.

use std::{net::SocketAddr, sync::Arc};

use alloy_primitives::B256;
use axum::{
    extract::State,
    http::StatusCode,
    routing::{any, get},
    Router,
};
use reqwest::Client;
use tower_governor::{governor::GovernorConfigBuilder, GovernorLayer};

mod aggregator;
mod collector;
mod config;
mod db;
mod pricing;
mod proxy;
mod tap;

use config::Config;
use db::Pool;

/// Shared state injected into every Axum handler.
#[derive(Clone)]
pub struct AppState {
    pub config:      Arc<Config>,
    pub pool:        Pool,
    pub http_client: Client,
    pub domain_sep:  B256,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "camp_gateway=info".into()),
        )
        .init();

    let config = Arc::new(Config::load()?);
    tracing::info!(
        provider  = %config.indexer.service_provider_address,
        upstream  = %config.backend.camp_url,
        "camp-gateway starting"
    );

    // Connect to Postgres and run migrations.
    let pool = db::connect(&config.database.url).await?;
    tracing::info!(url = %config.database.url, "database connected");

    // Pre-compute EIP-712 domain separator.
    let domain_sep = tap::domain_separator(
        &config.tap.eip712_domain_name,
        config.tap.eip712_chain_id,
        config.tap.eip712_verifying_contract,
    );
    tracing::info!(
        name       = %config.tap.eip712_domain_name,
        chain_id   = config.tap.eip712_chain_id,
        verifying  = %config.tap.eip712_verifying_contract,
        domain_sep = %domain_sep,
        "EIP-712 domain separator computed"
    );

    let http_client = Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    let state = AppState {
        config: Arc::clone(&config),
        pool:   pool.clone(),
        http_client,
        domain_sep,
    };

    // Spawn background tasks.
    aggregator::spawn(Arc::clone(&config), pool.clone());
    collector::spawn(Arc::clone(&config), pool.clone());

    // Rate-limit governor — per IP, token bucket.
    let period_ms = 1_000u64 / config.rate_limit.requests_per_second.max(1) as u64;
    let governor_conf = {
        let mut b = GovernorConfigBuilder::default();
        b.per_millisecond(period_ms).burst_size(config.rate_limit.burst_size);
        Arc::new(b.finish().expect("invalid rate limit config"))
    };
    tracing::info!(
        rps   = config.rate_limit.requests_per_second,
        burst = config.rate_limit.burst_size,
        "rate limiter configured"
    );

    // All /v1/* routes require a valid TAP receipt. Health endpoints are exempt.
    let api_routes = Router::new()
        .route("/v1/{*path}", any(proxy::handler))
        .route("/v1/",       any(proxy::handler))
        .layer(GovernorLayer::new(Arc::clone(&governor_conf)));

    let app = Router::new()
        .route("/health", get(health))
        .route("/ready",  get(ready))
        .route("/version", get(version))
        .merge(api_routes)
        .with_state(state);

    let addr: SocketAddr =
        format!("{}:{}", config.server.host, config.server.port).parse()?;
    tracing::info!(%addr, "camp-gateway listening");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await?;

    Ok(())
}

async fn health() -> StatusCode {
    StatusCode::OK
}

async fn ready(State(state): State<AppState>) -> StatusCode {
    match sqlx::query("SELECT 1").execute(&state.pool).await {
        Ok(_)  => StatusCode::OK,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}

async fn version() -> &'static str {
    concat!(env!("CARGO_PKG_NAME"), "/", env!("CARGO_PKG_VERSION"))
}

//! Camp REST API reverse proxy with TAP receipt validation.
//!
//! Every request must carry a valid `TAP-Receipt` header. The receipt is
//! validated (EIP-712 signature, staleness, authorised sender) and persisted.
//! The request is then forwarded to the upstream camp API unchanged.
//!
//! Pricing note: we do not enforce a per-request minimum fee here. Consumers
//! are expected to set receipt values according to the quoted pricing in
//! pricing.rs. The gateway simply accumulates whatever value is provided.

use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    response::Response,
};
use sqlx;

use crate::{db, tap, AppState};

pub async fn handler(
    State(state): State<AppState>,
    req: Request<Body>,
) -> Result<Response<Body>, (StatusCode, String)> {
    // ── 1. Extract TAP-Receipt header ─────────────────────────────────────────
    let tap_header = req
        .headers()
        .get("tap-receipt")
        .ok_or_else(|| (StatusCode::PAYMENT_REQUIRED, "TAP-Receipt header required".into()))?;

    let header_str = tap_header
        .to_str()
        .map_err(|_| (StatusCode::BAD_REQUEST, "TAP-Receipt is not valid UTF-8".into()))?;

    // ── 2. Validate receipt ───────────────────────────────────────────────────
    let now_ns = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos() as u64;

    let validated = tap::validate_receipt(
        header_str,
        state.domain_sep,
        &state.config.tap.authorized_senders,
        state.config.tap.data_service_address,
        state.config.indexer.service_provider_address,
        state.config.tap.max_receipt_age_ns,
        now_ns,
    )
    .map_err(|e| (StatusCode::PAYMENT_REQUIRED, e.to_string()))?;

    // ── 3. Persist receipt (reject replayed nonces) ───────────────────────────
    match db::insert_receipt(&state.pool, &validated).await {
        Ok(()) => {}
        Err(e) if is_duplicate_nonce(&e) => {
            return Err((StatusCode::PAYMENT_REQUIRED, "receipt nonce already used".into()));
        }
        Err(e) => return Err((StatusCode::INTERNAL_SERVER_ERROR, e.to_string())),
    }

    // ── 4. Proxy to camp REST API ─────────────────────────────────────────────
    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");

    let backend_url = format!(
        "{}{}",
        state.config.backend.camp_url.trim_end_matches('/'),
        path_and_query
    );

    let method = reqwest::Method::from_bytes(req.method().as_str().as_bytes())
        .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut builder = state.http_client.request(method, &backend_url);

    // Forward safe request headers to camp.
    for name in ["content-type", "accept", "range", "range-unit"] {
        if let Some(v) = req.headers().get(name) {
            if let Ok(s) = v.to_str() {
                builder = builder.header(name, s);
            }
        }
    }

    let body_bytes = axum::body::to_bytes(req.into_body(), 4 * 1024 * 1024)
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    if !body_bytes.is_empty() {
        builder = builder.body(body_bytes);
    }

    let resp = builder
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("upstream unreachable: {e}")))?;

    let status = StatusCode::from_u16(resp.status().as_u16())
        .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    let content_type = resp
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/json")
        .to_owned();

    let resp_bytes = resp
        .bytes()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, e.to_string()))?;

    Ok(Response::builder()
        .status(status)
        .header("content-type", content_type)
        .body(Body::from(resp_bytes))
        .unwrap())
}

fn is_duplicate_nonce(e: &anyhow::Error) -> bool {
    if let Some(sqlx::Error::Database(db_err)) = e.downcast_ref::<sqlx::Error>() {
        return db_err.code().as_deref() == Some("23505");
    }
    false
}

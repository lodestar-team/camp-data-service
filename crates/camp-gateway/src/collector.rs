//! On-chain RAV collection task.
//!
//! Runs on a configurable interval (default: 1h). For each unredeemed RAV:
//!   1. ABI-encodes the SignedRAV.
//!   2. Calls CampDataService.collect() on the configured Arbitrum network.
//!   3. Marks the RAV as redeemed in the database.
//!
//! Enable by adding a [collector] section to config.toml.

use std::{sync::Arc, time::Duration};

use alloy::{
    network::EthereumWallet,
    providers::ProviderBuilder,
    signers::local::PrivateKeySigner,
    sol,
};
use alloy_primitives::{Address, Bytes, FixedBytes, U256};
use alloy_sol_types::SolValue;
use tokio::time::timeout;

use crate::{config::Config, db};

// Minimal ABI surface for CampDataService — only collect() needed.
sol! {
    #[sol(rpc)]
    interface ICampDataService {
        function collect(
            address serviceProvider,
            uint8   paymentType,
            bytes   calldata data
        ) external returns (uint256 fees);
    }
}

// Mirror of IGraphTallyCollector.ReceiptAggregateVoucher for ABI-encoding.
sol! {
    struct RavData {
        bytes32 collectionId;
        address payer;
        address serviceProvider;
        address dataService;
        uint64  timestampNs;
        uint128 valueAggregate;
        bytes   metadata;
    }

    struct SignedRavData {
        RavData rav;
        bytes   signature;
    }
}

pub fn spawn(config: Arc<Config>, pool: db::Pool) {
    let Some(collector_cfg) = config.collector.clone() else {
        tracing::info!("no [collector] config — on-chain RAV collection disabled");
        return;
    };

    let signer: PrivateKeySigner = match config.indexer.operator_private_key.parse() {
        Ok(s)  => s,
        Err(e) => {
            tracing::error!("collector: invalid operator_private_key: {e}");
            return;
        }
    };

    let rpc_url: reqwest::Url = match collector_cfg.arbitrum_rpc_url.parse() {
        Ok(u)  => u,
        Err(e) => {
            tracing::error!("collector: invalid arbitrum_rpc_url: {e}");
            return;
        }
    };

    let interval = Duration::from_secs(collector_cfg.collect_interval_secs);
    tracing::info!(interval_secs = interval.as_secs(), "on-chain RAV collector started");

    tokio::spawn(async move {
        let wallet   = EthereumWallet::from(signer);
        let provider = ProviderBuilder::new()
            .with_recommended_fillers()
            .wallet(wallet)
            .on_http(rpc_url);

        let contract         = ICampDataService::new(config.tap.data_service_address, provider);
        let service_provider = config.indexer.service_provider_address;

        loop {
            tokio::time::sleep(interval).await;

            let result: anyhow::Result<()> = async {
                let ravs = db::fetch_unredeemed_ravs(&pool).await?;

                if ravs.is_empty() {
                    tracing::debug!("no unredeemed RAVs");
                    return Ok(());
                }

                for rav in &ravs {
                    let value: u128 = rav.value_aggregate.parse().unwrap_or(0);

                    if value < collector_cfg.min_collect_value {
                        tracing::debug!(
                            collection_id = %rav.collection_id,
                            value,
                            min = collector_cfg.min_collect_value,
                            "RAV below minimum — skipping"
                        );
                        continue;
                    }

                    let data = match encode_collect_data(
                        &rav.collection_id,
                        &rav.payer_address,
                        &rav.service_provider,
                        &rav.data_service,
                        rav.timestamp_ns as u64,
                        value,
                        &rav.signature,
                    ) {
                        Ok(d)  => d,
                        Err(e) => {
                            tracing::error!(
                                collection_id = %rav.collection_id,
                                "encode failed: {e:#}"
                            );
                            continue;
                        }
                    };

                    // IGraphPayments.PaymentTypes.QueryFee = 0
                    let call = contract.collect(service_provider, 0u8, data);

                    match timeout(Duration::from_secs(120), async {
                        call.send()
                            .await
                            .map_err(|e| anyhow::anyhow!("send: {e}"))?
                            .watch()
                            .await
                            .map_err(|e| anyhow::anyhow!("watch: {e}"))
                    })
                    .await
                    {
                        Ok(Ok(_)) => {
                            db::mark_rav_redeemed(&pool, &rav.collection_id).await?;
                            tracing::info!(
                                collection_id = %rav.collection_id,
                                value,
                                "RAV redeemed on-chain"
                            );
                        }
                        Ok(Err(e)) => {
                            tracing::error!(
                                collection_id = %rav.collection_id,
                                "collect() failed: {e:#}"
                            );
                        }
                        Err(_) => {
                            tracing::error!(
                                collection_id = %rav.collection_id,
                                "collect() timed out"
                            );
                        }
                    }
                }

                Ok(())
            }
            .await;

            if let Err(e) = result {
                tracing::warn!("RAV collection cycle failed: {e:#}");
            }
        }
    });
}

fn encode_collect_data(
    collection_id_hex: &str,
    payer_hex: &str,
    service_provider_hex: &str,
    data_service_hex: &str,
    timestamp_ns: u64,
    value_aggregate: u128,
    signature_hex: &str,
) -> anyhow::Result<Bytes> {
    let id_bytes: [u8; 32] = hex::decode(collection_id_hex.trim_start_matches("0x"))?
        .try_into()
        .map_err(|_| anyhow::anyhow!("collection_id must be 32 bytes"))?;

    let sig_bytes = hex::decode(signature_hex.trim_start_matches("0x"))?;

    let signed_rav = SignedRavData {
        rav: RavData {
            collectionId:    FixedBytes::from(id_bytes),
            payer:           payer_hex.parse::<Address>()?,
            serviceProvider: service_provider_hex.parse::<Address>()?,
            dataService:     data_service_hex.parse::<Address>()?,
            timestampNs:     timestamp_ns,
            valueAggregate:  value_aggregate,
            metadata:        Bytes::default(),
        },
        signature: Bytes::from(sig_bytes),
    };

    // abi.encode(SignedRAV, uint256 tokensToCollect=0)
    let encoded = (signed_rav, U256::ZERO).abi_encode_sequence();
    Ok(Bytes::from(encoded))
}

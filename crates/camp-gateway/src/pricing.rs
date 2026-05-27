//! Per-endpoint compute-unit (CU) pricing for camp queries.
//!
//! CU costs are multiplied by `base_price_per_cu` (GRT wei) to get the
//! minimum receipt value for a given endpoint. Consumers should set their
//! receipt value to at least `cu_cost(path) * base_price_per_cu`.
//!
//! Default base price: 4_000_000_000_000 GRT wei per CU
//!   = 0.000004 GRT ≈ $0.00000036 at $0.09/GRT
//!
//! Tier summary:
//!   BASIC (1 CU)      — status, block, tx, signatures
//!   STANDARD (5 CU)   — transfers, events, address lookups, protocol tables
//!   AGGREGATE (10 CU) — time-bucketed gas/activity/volume stats
//!   SQL (20 CU)       — raw POST /v1/sql

/// Default GRT wei per compute unit.
/// Matches dispatch-service / seahorn-gateway pricing.
pub const DEFAULT_BASE_PRICE_PER_CU: u128 = 4_000_000_000_000;

/// Compute-unit cost for the given request path.
///
/// `path` is the HTTP path component, e.g. "/v1/transfers".
/// Any unknown path defaults to STANDARD (5 CU).
pub fn cu_cost(path: &str) -> u32 {
    // Strip trailing slash for uniform matching.
    let p = path.trim_end_matches('/');

    // BASIC — 1 CU: cheap lookups with no range scan.
    if p == "/v1/status"
        || p == "/v1/signatures"
        || p.starts_with("/v1/block/")
        || p.starts_with("/v1/tx/")
    {
        return 1;
    }

    // AGGREGATE — 10 CU: time-bucketed stats; potentially large scans.
    if p.starts_with("/v1/gas/")
        || p.ends_with("/activity")
        || p.ends_with("/volume")
    {
        return 10;
    }

    // SQL — 20 CU: raw SELECT, arbitrary complexity.
    if p == "/v1/sql" {
        return 20;
    }

    // STANDARD — 5 CU (default): transfers, events, address queries, protocol tables.
    5
}

/// Minimum GRT wei required for a given path.
pub fn min_receipt_value(path: &str, base_price_per_cu: u128) -> u128 {
    cu_cost(path) as u128 * base_price_per_cu
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_is_basic() {
        assert_eq!(cu_cost("/v1/status"), 1);
    }

    #[test]
    fn block_is_basic() {
        assert_eq!(cu_cost("/v1/block/12345678"), 1);
    }

    #[test]
    fn tx_is_basic() {
        assert_eq!(cu_cost("/v1/tx/0xdeadbeef"), 1);
    }

    #[test]
    fn transfers_is_standard() {
        assert_eq!(cu_cost("/v1/transfers"), 5);
    }

    #[test]
    fn horizon_is_standard() {
        assert_eq!(cu_cost("/v1/horizon/provisions"), 5);
    }

    #[test]
    fn gas_is_aggregate() {
        assert_eq!(cu_cost("/v1/gas/blocks"), 10);
    }

    #[test]
    fn contract_activity_is_aggregate() {
        assert_eq!(cu_cost("/v1/contract/0xabc/activity"), 10);
    }

    #[test]
    fn token_volume_is_aggregate() {
        assert_eq!(cu_cost("/v1/token/0xabc/volume"), 10);
    }

    #[test]
    fn sql_is_sql() {
        assert_eq!(cu_cost("/v1/sql"), 20);
    }

    #[test]
    fn unknown_path_is_standard() {
        assert_eq!(cu_cost("/v1/something/new"), 5);
    }

    #[test]
    fn min_value_scales_with_base_price() {
        let base = 4_000_000_000_000u128;
        assert_eq!(min_receipt_value("/v1/status", base), base);
        assert_eq!(min_receipt_value("/v1/transfers", base), 5 * base);
        assert_eq!(min_receipt_value("/v1/sql", base), 20 * base);
    }
}

//! TAP v2 (GraphTally) — inlined types, EIP-712 hashing, and receipt validation.
//!
//! Kept self-contained so camp-gateway has no external TAP crate dependency.
//! Logic is identical to dispatch-tap / seahorn-gateway.

use alloy_primitives::{keccak256, Address, Bytes, B256, U256};
use alloy_sol_types::SolValue;
use k256::ecdsa::{RecoveryId, Signature as K256Sig, VerifyingKey};
use serde::{Deserialize, Serialize};

// ── Type strings ──────────────────────────────────────────────────────────────

const RECEIPT_TYPE_STRING: &str =
    "Receipt(address data_service,address service_provider,uint64 timestamp_ns,uint64 nonce,uint128 value,bytes metadata)";

pub const RAV_TYPE_STRING: &str =
    "ReceiptAggregateVoucher(bytes32 collectionId,address payer,address serviceProvider,address dataService,uint64 timestampNs,uint128 valueAggregate,bytes metadata)";

// ── Structs ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Receipt {
    pub data_service:    Address,
    pub service_provider: Address,
    pub timestamp_ns:    u64,
    pub nonce:           u64,
    pub value:           u128,
    #[serde(default)]
    pub metadata:        Bytes,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedReceipt {
    pub receipt:   Receipt,
    /// 65-byte ECDSA signature in hex: r(32) || s(32) || v(1).
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Rav {
    pub collection_id:   B256,
    pub payer:           Address,
    pub service_provider: Address,
    pub data_service:    Address,
    pub timestamp_ns:    u64,
    pub value_aggregate: u128,
    #[serde(default)]
    pub metadata:        Bytes,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedRav {
    pub rav:       Rav,
    pub signature: String,
}

/// Extract the payer (consumer) address from receipt metadata (first 20 bytes).
pub fn payer_from_metadata(metadata: &Bytes) -> Option<Address> {
    if metadata.len() >= 20 {
        Some(Address::from_slice(&metadata[..20]))
    } else {
        None
    }
}

// ── EIP-712 ───────────────────────────────────────────────────────────────────

pub fn domain_separator(name: &str, chain_id: u64, verifying_contract: Address) -> B256 {
    let type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let encoded = (
        type_hash,
        keccak256(name.as_bytes()),
        keccak256(b"1"),
        U256::from(chain_id),
        verifying_contract,
    )
        .abi_encode();
    keccak256(&encoded)
}

pub fn eip712_hash(domain_sep: B256, receipt: &Receipt) -> B256 {
    eip712_hash_raw(domain_sep, receipt_struct_hash(receipt))
}

pub fn eip712_hash_raw(domain_sep: B256, struct_hash: B256) -> B256 {
    let mut buf = [0u8; 66];
    buf[0] = 0x19;
    buf[1] = 0x01;
    buf[2..34].copy_from_slice(domain_sep.as_slice());
    buf[34..66].copy_from_slice(struct_hash.as_slice());
    keccak256(buf)
}

pub fn recover_signer(hash: B256, sig_hex: &str) -> anyhow::Result<Address> {
    let bytes = hex::decode(sig_hex.trim_start_matches("0x"))?;
    anyhow::ensure!(bytes.len() == 65, "signature must be 65 bytes, got {}", bytes.len());
    let v = bytes[64];
    let rec_id_byte = if v >= 27 { v - 27 } else { v };
    let rec_id = RecoveryId::from_byte(rec_id_byte)
        .ok_or_else(|| anyhow::anyhow!("invalid recovery id {v}"))?;
    let sig = K256Sig::from_slice(&bytes[..64])?;
    let vk = VerifyingKey::recover_from_prehash(hash.as_slice(), &sig, rec_id)?;
    let encoded = vk.to_encoded_point(false);
    let pubkey_hash = keccak256(&encoded.as_bytes()[1..]);
    Ok(Address::from_slice(&pubkey_hash[12..]))
}

fn receipt_struct_hash(r: &Receipt) -> B256 {
    let type_hash = keccak256(RECEIPT_TYPE_STRING.as_bytes());
    let encoded = (
        type_hash,
        r.data_service,
        r.service_provider,
        r.timestamp_ns,
        r.nonce,
        r.value,
        keccak256(&r.metadata),
    )
        .abi_encode();
    keccak256(&encoded)
}

pub fn rav_struct_hash(rav: &Rav) -> B256 {
    let type_hash = keccak256(RAV_TYPE_STRING.as_bytes());
    let encoded = (
        type_hash,
        rav.collection_id,
        rav.payer,
        rav.service_provider,
        rav.data_service,
        rav.timestamp_ns,
        rav.value_aggregate,
        keccak256(&rav.metadata),
    )
        .abi_encode();
    keccak256(&encoded)
}

pub fn collection_id(payer: Address, service_provider: Address, data_service: Address) -> B256 {
    keccak256((payer, service_provider, data_service).abi_encode())
}

// ── Validation ────────────────────────────────────────────────────────────────

#[derive(Debug)]
pub enum TapError {
    InvalidReceipt(String),
    ReceiptExpired,
    UnauthorizedSender(String),
}

impl std::fmt::Display for TapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TapError::InvalidReceipt(msg)     => write!(f, "invalid receipt: {msg}"),
            TapError::ReceiptExpired          => write!(f, "receipt expired"),
            TapError::UnauthorizedSender(s)   => write!(f, "unauthorized sender: {s}"),
        }
    }
}

pub struct ValidatedReceipt {
    pub receipt:   Receipt,
    pub signer:    Address,
    pub payer:     Address,
    pub signature: String,
}

pub fn validate_receipt(
    header_value: &str,
    domain_sep: B256,
    authorized_senders: &[Address],
    data_service: Address,
    service_provider: Address,
    max_age_ns: u64,
    now_ns: u64,
) -> Result<ValidatedReceipt, TapError> {
    let signed: SignedReceipt = serde_json::from_str(header_value)
        .map_err(|e| TapError::InvalidReceipt(e.to_string()))?;

    let r = &signed.receipt;

    if r.data_service != data_service {
        return Err(TapError::InvalidReceipt(format!(
            "data_service mismatch: expected {data_service}, got {}",
            r.data_service
        )));
    }

    if r.service_provider != service_provider {
        return Err(TapError::InvalidReceipt(format!(
            "service_provider mismatch: expected {service_provider}, got {}",
            r.service_provider
        )));
    }

    if now_ns.saturating_sub(r.timestamp_ns) > max_age_ns {
        return Err(TapError::ReceiptExpired);
    }

    let msg_hash = eip712_hash(domain_sep, r);
    let signer = recover_signer(msg_hash, &signed.signature)
        .map_err(|e| TapError::InvalidReceipt(format!("signature recovery failed: {e}")))?;

    if !authorized_senders.is_empty() && !authorized_senders.contains(&signer) {
        return Err(TapError::UnauthorizedSender(signer.to_string()));
    }

    let payer = payer_from_metadata(&r.metadata).unwrap_or(signer);

    Ok(ValidatedReceipt { receipt: signed.receipt, signer, payer, signature: signed.signature })
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use k256::ecdsa::SigningKey;

    fn eth_address(sk: &SigningKey) -> Address {
        let vk = sk.verifying_key();
        let encoded = vk.to_encoded_point(false);
        let hash = keccak256(&encoded.as_bytes()[1..]);
        Address::from_slice(&hash[12..])
    }

    fn sign_hex(sk: &SigningKey, hash: B256) -> String {
        let (sig, rec_id) = sk.sign_prehash_recoverable(hash.as_slice()).unwrap();
        let mut bytes = [0u8; 65];
        bytes[..64].copy_from_slice(&sig.to_bytes());
        bytes[64] = rec_id.to_byte();
        format!("0x{}", hex::encode(bytes))
    }

    fn test_sk() -> SigningKey { SigningKey::from_slice(&[1u8; 32]).unwrap() }

    fn test_domain() -> B256 {
        domain_separator("GraphTallyCollector", 421614, Address::from_slice(&[0xAB; 20]))
    }

    #[test]
    fn domain_separator_is_deterministic() {
        assert_eq!(domain_separator("X", 1, Address::ZERO), domain_separator("X", 1, Address::ZERO));
    }

    #[test]
    fn domain_separator_varies_by_chain() {
        assert_ne!(domain_separator("X", 1, Address::ZERO), domain_separator("X", 2, Address::ZERO));
    }

    #[test]
    fn recover_signer_round_trip() {
        let sk = test_sk();
        let addr = eth_address(&sk);
        let hash = B256::from([0x42u8; 32]);
        let sig = sign_hex(&sk, hash);
        assert_eq!(recover_signer(hash, &sig).unwrap(), addr);
    }

    #[test]
    fn validate_receipt_accepts_valid() {
        let sk = test_sk();
        let data_svc  = Address::from_slice(&[0x01; 20]);
        let svc_prov  = Address::from_slice(&[0x02; 20]);
        let dom       = test_domain();
        let signer    = eth_address(&sk);

        let receipt = Receipt {
            data_service:     data_svc,
            service_provider: svc_prov,
            timestamp_ns:     1_000_000_000,
            nonce:            42,
            value:            100,
            metadata:         Bytes::default(),
        };
        let msg_hash = eip712_hash(dom, &receipt);
        let sig      = sign_hex(&sk, msg_hash);
        let header   = serde_json::to_string(&SignedReceipt { receipt, signature: sig }).unwrap();

        assert!(validate_receipt(&header, dom, &[signer], data_svc, svc_prov, 60_000_000_000, 1_000_000_000).is_ok());
    }

    #[test]
    fn validate_receipt_rejects_expired() {
        let sk = test_sk();
        let data_svc = Address::from_slice(&[0x01; 20]);
        let svc_prov = Address::from_slice(&[0x02; 20]);
        let dom      = test_domain();

        let receipt = Receipt {
            data_service:     data_svc,
            service_provider: svc_prov,
            timestamp_ns:     1_000,
            nonce:            1,
            value:            1,
            metadata:         Bytes::default(),
        };
        let msg_hash = eip712_hash(dom, &receipt);
        let sig      = sign_hex(&sk, msg_hash);
        let header   = serde_json::to_string(&SignedReceipt { receipt, signature: sig }).unwrap();

        let result = validate_receipt(&header, dom, &[], data_svc, svc_prov, 1_000, 1_000_000_000);
        assert!(matches!(result, Err(TapError::ReceiptExpired)));
    }

    #[test]
    fn validate_receipt_rejects_wrong_data_service() {
        let sk       = test_sk();
        let dom      = test_domain();
        let data_svc = Address::from_slice(&[0x01; 20]);
        let wrong    = Address::from_slice(&[0xFF; 20]);
        let svc_prov = Address::from_slice(&[0x02; 20]);

        let receipt = Receipt {
            data_service:     wrong,
            service_provider: svc_prov,
            timestamp_ns:     1_000_000_000,
            nonce:            1,
            value:            1,
            metadata:         Bytes::default(),
        };
        let msg_hash = eip712_hash(dom, &receipt);
        let sig      = sign_hex(&sk, msg_hash);
        let header   = serde_json::to_string(&SignedReceipt { receipt, signature: sig }).unwrap();

        let result = validate_receipt(&header, dom, &[], data_svc, svc_prov, u64::MAX, 1_000_000_000);
        assert!(matches!(result, Err(TapError::InvalidReceipt(_))));
    }

    #[test]
    fn validate_receipt_rejects_unauthorized_sender() {
        let sk      = test_sk();
        let dom     = test_domain();
        let ds      = Address::from_slice(&[0x01; 20]);
        let sp      = Address::from_slice(&[0x02; 20]);
        let allowed = eth_address(&SigningKey::from_slice(&[0x99u8; 32]).unwrap());

        let receipt = Receipt {
            data_service:     ds,
            service_provider: sp,
            timestamp_ns:     1_000_000_000,
            nonce:            1,
            value:            1,
            metadata:         Bytes::default(),
        };
        let msg_hash = eip712_hash(dom, &receipt);
        let sig      = sign_hex(&sk, msg_hash);
        let header   = serde_json::to_string(&SignedReceipt { receipt, signature: sig }).unwrap();

        let result = validate_receipt(&header, dom, &[allowed], ds, sp, u64::MAX, 1_000_000_000);
        assert!(matches!(result, Err(TapError::UnauthorizedSender(_))));
    }
}

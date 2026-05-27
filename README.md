# camp-data-service

> **DISCLAIMER:** This is an experimental community project. It is not affiliated with or endorsed by The Graph Foundation or Edge & Node. It has not been audited. Deploy on testnet only until further notice.

A Horizon data service that turns a self-hosted [camp](https://github.com/lodestar-team/camp) instance — backed by an Amp node — into a paid provider on The Graph Protocol's Horizon payment network. Consumers deposit GRT into `PaymentsEscrow`, each query carries a signed TAP (GraphTally) receipt, and the provider collects GRT hourly via an on-chain `collect()` call.

In one sentence: **the ThinkPad running ampd becomes an indexer on Horizon, and anyone who wants decoded Arbitrum One data pays in GRT to query it.**

---

## What is camp?

[camp](https://github.com/lodestar-team/camp) is a free REST API for decoded Arbitrum One blockchain data backed by a self-hosted [Amp](https://github.com/amphitheatre-app/amp) node. It offers endpoints for ERC-20 transfers, decoded protocol events, gas analytics, whale feeds, and raw SQL — all updated at chain tip, no signup required.

camp-data-service adds a payment layer on top: instead of free queries, consumers pay per request in GRT via The Graph's Horizon micropayment system.

---

## Architecture

```
Consumer (dApp / script)
   │  TAP-Receipt: { signed EIP-712 receipt }
   │
   ▼
camp-gateway                         (this repo — Rust/Axum)
   │  validates receipt, persists, proxies
   ▼
camp REST API                        (Next.js — github.com/lodestar-team/camp)
   │  translates REST → SQL
   ▼
nginx :1604 + ampd :1603             (ThinkPad — Amp node on Arbitrum One)
```

Payment settlement (off-chain → on-chain):

```
receipts (per request)
   → aggregator (60s) → RAV
   → collector (1h)   → CampDataService.collect()
                      → GraphTallyCollector
                      → PaymentsEscrow
                      → GraphPayments
                      → GRT to provider
```

Horizon contracts live on Arbitrum Sepolia (testnet). The ampd data node runs on Arbitrum One mainnet data — you get real Arbitrum data, paid for with testnet GRT.

---

## Components

| Path | What it is |
|---|---|
| `contracts/src/CampDataService.sol` | Horizon `DataService` contract — provider registration, service lifecycle, fee collection |
| `contracts/src/interfaces/ICampDataService.sol` | Interface: types, events, errors |
| `contracts/test/CampDataService.t.sol` | Foundry test suite (full lifecycle) |
| `contracts/script/Deploy.s.sol` | UUPS proxy deployment script |
| `crates/camp-gateway/` | Rust/Axum gateway: TAP receipt validation, upstream proxy, RAV aggregation, on-chain collection |
| `subgraph/` | The Graph subgraph — indexes `CampDataService` events for provider discovery |
| `indexer-agent/` | TypeScript agent — automates `register`/`startService`/`stopService` lifecycle |

---

## Data tiers and pricing

| Tier | Value | Endpoints | CU cost |
|---|---|---|---|
| BASIC | 0 | `/v1/status`, `/v1/block/{n}`, `/v1/tx/{hash}`, `/v1/signatures` | 1 CU |
| STANDARD | 1 | `/v1/transfers`, `/v1/events`, `/v1/address/*`, `/v1/horizon/*`, `/v1/uniswap-v3/*`, `/v1/whales/*` | 5 CU |
| AGGREGATE | — | `/v1/gas/blocks`, `/v1/contract/*/activity`, `/v1/token/*/volume` | 10 CU |
| SQL | 2 | `POST /v1/sql` | 20 CU |

Base price: `4_000_000_000_000` GRT wei per CU.

| Endpoint | CUs | Per-request fee | USD at $0.09/GRT |
|---|---|---|---|
| `/v1/status` | 1 | 0.000004 GRT | ~$0.00000036 |
| `/v1/transfers` | 5 | 0.00002 GRT | ~$0.0000018 |
| `/v1/gas/blocks` | 10 | 0.00004 GRT | ~$0.0000036 |
| `POST /v1/sql` | 20 | 0.00008 GRT | ~$0.0000072 |

Providers register for specific tiers (`BASIC=0`, `DECODED=1`, `SQL=2`). A provider can serve all three simultaneously.

---

## Contract

### Deployed addresses (Arbitrum Sepolia — testnet)

| Contract | Address |
|---|---|
| CampDataService | *deploy and update* |
| HorizonStaking | `0xFf2Ee30de92F276018642A59Fb7Be95b3F9088Af` |
| GraphTallyCollector | `0xacC71844EF6beEF70106ABe6E51013189A1f3738` |
| PaymentsEscrow | `0x09B985a2042848A08bA59060EaF0f07c6F5D4d54` |

> Arbitrum One (mainnet) is not targeted yet. This is a testnet-only experiment.

### Provider lifecycle

```
1. stake GRT
   HorizonStaking.provision(yourAddress, CampDataService, ≥555e18, maxVerifierCut, thawingPeriod)

2. register
   CampDataService.register(yourAddress, abi.encode(endpoint, geoHash, paymentsDestination))

3. start serving
   CampDataService.startService(yourAddress, abi.encode(DataTier.BASIC,   endpoint))
   CampDataService.startService(yourAddress, abi.encode(DataTier.DECODED, endpoint))
   CampDataService.startService(yourAddress, abi.encode(DataTier.SQL,     endpoint))

4. serve queries (receipts accumulate → RAVs every 60s → collect() every hour)

5. stop
   CampDataService.stopService(yourAddress, abi.encode(DataTier.BASIC))
   CampDataService.deregister(yourAddress, "")
```

---

## Running

### Prerequisites

- Rust stable
- PostgreSQL 15+
- Foundry (for contract work)
- A running [camp](https://github.com/lodestar-team/camp) instance

### Build

```bash
cargo build --release
```

### Deploy the contract

```bash
# From the repo root (foundry.toml lives here):
forge install graphprotocol/contracts --no-git
forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-git

forge build
forge test -vvv

# Set deploy env vars:
export PRIVATE_KEY=0x...     # deployer private key
export OWNER=0x...           # governance address (receives onlyOwner rights)
export PAUSE_GUARDIAN=0x...  # address authorised to pause in an emergency

forge script contracts/script/Deploy.s.sol \
  --rpc-url arbitrum_sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

The script prints the deployed proxy address. Add it to your config:
```toml
# config.toml
[tap]
data_service_address = "0x..."
```

### Run the gateway

```bash
cp config.example.toml config.toml
# fill in: service_provider_address, operator_private_key, data_service_address, camp_url, database.url
RUST_LOG=camp_gateway=info cargo run --release --bin camp-gateway
```

### Docker Compose

```bash
# Starts PostgreSQL and camp-gateway.
# You still need to provide a config.toml before running.
cp config.example.toml config.toml
docker compose up
```

### Run the indexer agent

The indexer agent automates `register` / `startService` / `stopService` lifecycle calls so you don't have to call them manually.

```bash
cd indexer-agent
npm install
PROVIDER_ADDRESS=0x... \
OPERATOR_PRIVATE_KEY=0x... \
CAMP_DATA_SERVICE_ADDRESS=0x... \
CAMP_ENDPOINT=https://your-camp-gateway.example.com \
npm start
```

Or with a JSON config file:

```bash
AGENT_CONFIG=./agent.json npm start
```

---

## Querying as a consumer

Every request must carry a `TAP-Receipt` header containing a signed EIP-712 receipt.

### Receipt format

```json
{
  "receipt": {
    "data_service":     "0x<CampDataService address>",
    "service_provider": "0x<provider address>",
    "timestamp_ns":     1700000000000000000,
    "nonce":            42,
    "value":            20000000000000,
    "metadata":         "0x<consumer address padded to 20 bytes>"
  },
  "signature": "0x<65-byte r||s||v>"
}
```

`value` is in GRT wei. For a 5-CU endpoint at the default base price: `5 × 4_000_000_000_000 = 20_000_000_000_000`.

`metadata` encodes the consumer (payer) address as the first 20 bytes so the gateway knows which `PaymentsEscrow` account to charge.

### Example request

```bash
curl https://your-camp-gateway.example.com/v1/transfers \
  -H "TAP-Receipt: $(cat receipt.json)" \
  -G -d "token=0xaf88d065e77c8cC2239327C5EDb3A432268e5831&limit=10"
```

### Consumer deposit

Before querying, fund your `PaymentsEscrow` account:

```solidity
// Approve and deposit GRT into PaymentsEscrow for the provider.
GRT.approve(address(PaymentsEscrow), amount);
PaymentsEscrow.depositTo(providerAddress, amount);
```

---

## Configuration reference

### `config.toml` (camp-gateway)

```toml
[server]
host = "0.0.0.0"
port = 8090

[indexer]
service_provider_address = "0x..."   # your provider address on-chain
operator_private_key     = "0x..."   # signs collect() transactions

[tap]
data_service_address      = "0x..."  # CampDataService proxy
authorized_senders        = ["0x..."] # leave empty to accept any signer
eip712_domain_name        = "GraphTallyCollector"
eip712_chain_id           = 421614   # Arbitrum Sepolia
eip712_verifying_contract = "0xacC71844EF6beEF70106ABe6E51013189A1f3738"
max_receipt_age_ns        = 30_000_000_000  # 30s
aggregator_url            = "http://localhost:8080"
aggregation_interval_secs = 60

[backend]
camp_url = "http://localhost:3000"   # upstream camp REST API

[database]
url = "postgres://camp:camp@localhost:5432/camp_gateway"

[collector]
arbitrum_rpc_url      = "https://sepolia-rollup.arbitrum.io/rpc"
collect_interval_secs = 3600
min_collect_value     = "1_000_000_000_000_000"  # 0.001 GRT

[rate_limit]
requests_per_second = 20
burst_size          = 40
```

---

## Testing

### Foundry contract tests

```bash
forge test -vvv
```

27 tests covering the full provider lifecycle: `register`, `startService`, `stopService`, `deregister`, `collect` error paths, governance, UUPS upgrade, and pause mechanics.

### Rust unit tests

```bash
cargo test
```

18 tests covering TAP receipt validation (EIP-712 round-trip, staleness, unauthorized sender, wrong data service), pricing CU computation, and duplicate nonce rejection.

---

## Relation to existing Graph Protocol infrastructure

| Component | Status |
|---|---|
| HorizonStaking / GraphPayments / PaymentsEscrow | Reused as-is (testnet) |
| GraphTallyCollector (TAP v2) | Reused as-is (testnet) |
| `indexer-tap-agent` | Not used — TAP aggregation built into camp-gateway |
| SubgraphService dispute system | Not applicable |
| Graph Node | Not needed — camp proxies to Amp directly |

---

## Related

- [camp](https://github.com/lodestar-team/camp) — the free REST API this service monetises
- [dispatch-service](https://github.com/lodestar-team/dispatch-service) — JSON-RPC data service on Horizon (the template this project follows)
- [seahorn](https://github.com/lodestar-team/seahorn) — Solana data service on Horizon
- [GRC-005: Dispatch](https://forum.thegraph.com/t/grc-005-dispatch-an-experimental-json-rpc-data-service-on-horizon) — the RFC that inspired this work

---

## License

Apache-2.0. The underlying Amp engine is BUSL-1.1; camp-gateway consumes its REST output via the camp API only.

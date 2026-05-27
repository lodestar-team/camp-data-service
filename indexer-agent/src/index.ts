/**
 * camp-data-service indexer agent
 *
 * Automates the CampDataService provider lifecycle on The Graph Horizon:
 *   provision → register → startService → [collect loop] → stopService → deregister
 *
 * Configure via environment variables or a JSON config file.
 *
 * Usage:
 *   AGENT_CONFIG=./agent.json node dist/index.js
 *
 * Required env vars (if not using a config file):
 *   PROVIDER_ADDRESS        — your on-chain provider address
 *   OPERATOR_PRIVATE_KEY    — hex private key for the operator (signs txns)
 *   ARBITRUM_RPC_URL        — Arbitrum Sepolia or One RPC endpoint
 *   CAMP_DATA_SERVICE_ADDRESS — deployed CampDataService proxy address
 *   CAMP_ENDPOINT           — your camp-gateway public URL
 */

import { createPublicClient, createWalletClient, http, parseAbi, getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";

// ── ABI fragments ──────────────────────────────────────────────────────────────

const CAMP_ABI = parseAbi([
  "function register(address serviceProvider, bytes data) external",
  "function startService(address serviceProvider, bytes data) external",
  "function stopService(address serviceProvider, bytes data) external",
  "function isRegistered(address provider) external view returns (bool)",
  "function activeServiceCount(address provider) external view returns (uint256)",
  "function getServiceRegistrations(address provider) external view returns ((uint8 tier, string endpoint, bool active)[])",
]);

const HORIZON_STAKING_ABI = parseAbi([
  "function getProvision(address serviceProvider, address verifier) external view returns (uint256 tokens, uint256 createdAt, uint32 maxVerifierCut, uint64 thawingPeriod, uint256 tokensThawing, uint64 thawExpiration)",
  "function isAuthorized(address serviceProvider, address operator, address verifier) external view returns (bool)",
]);

// ── Types ─────────────────────────────────────────────────────────────────────

type DataTier = 0 | 1 | 2; // BASIC=0, DECODED=1, SQL=2

interface ServiceSpec {
  tier:     DataTier;
  endpoint: string;
}

interface AgentConfig {
  arbitrumRpcUrl:          string;
  campDataServiceAddress:  `0x${string}`;
  horizonStakingAddress:   `0x${string}`;
  providerAddress:         `0x${string}`;
  operatorPrivateKey:      `0x${string}`;
  geoHash:                 string;
  paymentsDestination:     `0x${string}`;
  services:                ServiceSpec[];
  pollIntervalMs:          number;
}

// Arbitrum Sepolia Horizon addresses
const DEFAULTS = {
  horizonStakingAddress: "0xFf2Ee30de92F276018642A59Fb7Be95b3F9088Af" as `0x${string}`,
};

// ── Config loading ────────────────────────────────────────────────────────────

function loadConfig(): AgentConfig {
  const configPath = process.env.AGENT_CONFIG;
  if (configPath) {
    const raw = require("fs").readFileSync(configPath, "utf-8");
    return JSON.parse(raw) as AgentConfig;
  }

  const providerAddress = getAddress(process.env.PROVIDER_ADDRESS ?? "") as `0x${string}`;
  return {
    arbitrumRpcUrl:         process.env.ARBITRUM_RPC_URL        ?? "https://sepolia-rollup.arbitrum.io/rpc",
    campDataServiceAddress: getAddress(process.env.CAMP_DATA_SERVICE_ADDRESS ?? "") as `0x${string}`,
    horizonStakingAddress:  DEFAULTS.horizonStakingAddress,
    providerAddress,
    operatorPrivateKey:     (process.env.OPERATOR_PRIVATE_KEY ?? "") as `0x${string}`,
    geoHash:                process.env.GEO_HASH ?? "u1hx",
    paymentsDestination:    getAddress(process.env.PAYMENTS_DESTINATION ?? providerAddress) as `0x${string}`,
    services:               [
      { tier: 0, endpoint: process.env.CAMP_ENDPOINT ?? "" },
      { tier: 1, endpoint: process.env.CAMP_ENDPOINT ?? "" },
    ],
    pollIntervalMs: parseInt(process.env.POLL_INTERVAL_MS ?? "60000"),
  };
}

// ── Agent ─────────────────────────────────────────────────────────────────────

class IndexerAgent {
  private config: AgentConfig;
  private publicClient:  ReturnType<typeof createPublicClient>;
  private walletClient:  ReturnType<typeof createWalletClient>;

  constructor(config: AgentConfig) {
    this.config = config;

    this.publicClient = createPublicClient({
      chain:     arbitrumSepolia,
      transport: http(config.arbitrumRpcUrl),
    });

    const account = privateKeyToAccount(config.operatorPrivateKey);
    this.walletClient = createWalletClient({
      account,
      chain:     arbitrumSepolia,
      transport: http(config.arbitrumRpcUrl),
    });
  }

  async reconcile(): Promise<void> {
    const { campDataServiceAddress, providerAddress } = this.config;

    console.log(`[agent] reconciling provider ${providerAddress}`);

    // 1. Check registration.
    const isRegistered = await this.publicClient.readContract({
      address: campDataServiceAddress,
      abi:     CAMP_ABI,
      functionName: "isRegistered",
      args:    [providerAddress],
    });

    if (!isRegistered) {
      console.log("[agent] provider not registered — registering...");
      await this.register();
      return;
    }

    // 2. Reconcile services.
    const onChainRegs = await this.publicClient.readContract({
      address: campDataServiceAddress,
      abi:     CAMP_ABI,
      functionName: "getServiceRegistrations",
      args:    [providerAddress],
    }) as Array<{ tier: number; endpoint: string; active: boolean }>;

    for (const svc of this.config.services) {
      const existing = onChainRegs.find((r) => r.tier === svc.tier);
      if (!existing || !existing.active) {
        console.log(`[agent] starting service tier=${svc.tier} endpoint=${svc.endpoint}`);
        await this.startService(svc.tier, svc.endpoint);
      } else if (existing.endpoint !== svc.endpoint) {
        console.log(`[agent] updating endpoint for tier=${svc.tier}`);
        await this.stopService(svc.tier);
        await this.startService(svc.tier, svc.endpoint);
      } else {
        console.log(`[agent] tier=${svc.tier} already active at ${svc.endpoint}`);
      }
    }
  }

  private async register(): Promise<void> {
    const { campDataServiceAddress, providerAddress, geoHash, paymentsDestination, services } = this.config;

    // Register uses the first service's endpoint as the primary endpoint.
    const primaryEndpoint = services[0]?.endpoint ?? "";

    const data = encodeRegisterData(primaryEndpoint, geoHash, paymentsDestination);

    const hash = await this.walletClient.writeContract({
      address: campDataServiceAddress,
      abi:     CAMP_ABI,
      functionName: "register",
      args:    [providerAddress, data],
    });
    console.log(`[agent] register tx: ${hash}`);
    await this.publicClient.waitForTransactionReceipt({ hash });
    console.log("[agent] registered");
  }

  private async startService(tier: DataTier, endpoint: string): Promise<void> {
    const data = encodeStartServiceData(tier, endpoint);
    const hash = await this.walletClient.writeContract({
      address: this.config.campDataServiceAddress,
      abi:     CAMP_ABI,
      functionName: "startService",
      args:    [this.config.providerAddress, data],
    });
    console.log(`[agent] startService tier=${tier} tx: ${hash}`);
    await this.publicClient.waitForTransactionReceipt({ hash });
  }

  private async stopService(tier: DataTier): Promise<void> {
    const data = encodeStopServiceData(tier);
    const hash = await this.walletClient.writeContract({
      address: this.config.campDataServiceAddress,
      abi:     CAMP_ABI,
      functionName: "stopService",
      args:    [this.config.providerAddress, data],
    });
    console.log(`[agent] stopService tier=${tier} tx: ${hash}`);
    await this.publicClient.waitForTransactionReceipt({ hash });
  }
}

// ── ABI encoding helpers ──────────────────────────────────────────────────────

import { encodeAbiParameters } from "viem";

function encodeRegisterData(
  endpoint: string,
  geoHash: string,
  paymentsDestination: `0x${string}`
): `0x${string}` {
  return encodeAbiParameters(
    [
      { type: "string",  name: "endpoint" },
      { type: "string",  name: "geoHash" },
      { type: "address", name: "paymentsDestination" },
    ],
    [endpoint, geoHash, paymentsDestination]
  );
}

function encodeStartServiceData(tier: DataTier, endpoint: string): `0x${string}` {
  return encodeAbiParameters(
    [
      { type: "uint8",  name: "tier" },
      { type: "string", name: "endpoint" },
    ],
    [tier, endpoint]
  );
}

function encodeStopServiceData(tier: DataTier): `0x${string}` {
  return encodeAbiParameters(
    [{ type: "uint8", name: "tier" }],
    [tier]
  );
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const config = loadConfig();
  const agent  = new IndexerAgent(config);

  console.log(`[agent] starting — provider=${config.providerAddress}`);
  console.log(`[agent] data service=${config.campDataServiceAddress}`);
  console.log(`[agent] poll interval=${config.pollIntervalMs}ms`);

  // Initial reconcile.
  await agent.reconcile();

  // Poll loop.
  setInterval(async () => {
    try {
      await agent.reconcile();
    } catch (err) {
      console.error("[agent] reconcile error:", err);
    }
  }, config.pollIntervalMs);
}

main().catch((err) => {
  console.error("[agent] fatal:", err);
  process.exit(1);
});

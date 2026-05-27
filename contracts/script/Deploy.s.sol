// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CampDataService} from "../src/CampDataService.sol";

/// @notice Deploy CampDataService (UUPS upgradeable proxy) to a target network.
///
/// Deploys the implementation contract and an ERC1967Proxy, calling initialize()
/// atomically via the proxy constructor.
///
/// Usage — Arbitrum Sepolia (testnet):
///   forge script contracts/script/Deploy.s.sol \
///     --rpc-url arbitrum_sepolia \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --verify \
///     -vvvv
///
/// Required env vars (see .env.example):
///   PRIVATE_KEY           — deployer private key (hex, 0x-prefixed)
///   OWNER                 — governance address (owner of the proxy)
///   PAUSE_GUARDIAN        — address authorised to pause the service
///
/// Horizon addresses — Arbitrum Sepolia (421614):
///   Controller:           0x9DB3ee191681f092607035d9BDA6e59FbEaCa695
///   HorizonStaking:       0xFf2Ee30de92F276018642A59Fb7Be95b3F9088Af
///   GraphTallyCollector:  0xacC71844EF6beEF70106ABe6E51013189A1f3738
///   PaymentsEscrow:       0x09B985a2042848A08bA59060EaF0f07c6F5D4d54
///
/// Horizon addresses — Arbitrum One (42161, mainnet — NOT for use yet):
///   Controller:           see cast call 0xb2Bb92d0DE618878E438b55D5846cfecD9301105 "controller()(address)"
///   HorizonStaking:       0x00669A4CF01450B64E8A2A20E9b1FCB71E61eF03
///   GraphTallyCollector:  0x8f69F5C07477Ac46FBc491B1E6D91E2bb0111A9e
///   PaymentsEscrow:       0xf6Fcc27aAf1fcD8B254498c9794451d82afC673E
contract Deploy is Script {
    function run() external {
        address owner_        = vm.envAddress("OWNER");
        address pauseGuardian = vm.envAddress("PAUSE_GUARDIAN");

        // Use Arbitrum Sepolia addresses by default.
        // Override via env vars if targeting a different network.
        address controller = vm.envOr(
            "GRAPH_CONTROLLER",
            address(0x9DB3ee191681f092607035d9BDA6e59FbEaCa695)
        );
        address graphTallyCollector = vm.envOr(
            "GRAPH_TALLY_COLLECTOR",
            address(0xacC71844EF6beEF70106ABe6E51013189A1f3738)
        );

        vm.startBroadcast();

        // Deploy implementation (immutables set here, initializers disabled).
        CampDataService impl = new CampDataService(controller, graphTallyCollector);
        console2.log("CampDataService implementation:", address(impl));

        // Deploy UUPS proxy — initialize() called atomically.
        bytes memory initData = abi.encodeCall(CampDataService.initialize, (owner_, pauseGuardian));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console2.log("CampDataService proxy deployed at:", address(proxy));

        vm.stopBroadcast();

        console2.log("\nAdd to your config.toml and environment:");
        console2.log("CAMP_DATA_SERVICE_ADDRESS =", vm.toString(address(proxy)));
        console2.log("CAMP_DATA_SERVICE_IMPL    =", vm.toString(address(impl)));
    }
}

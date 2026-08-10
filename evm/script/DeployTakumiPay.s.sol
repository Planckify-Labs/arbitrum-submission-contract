// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TakumiPay} from "../src/TakumiPay.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys TakumiPay behind a UUPS ERC-1967 proxy.
///
/// Usage:
///   BACKEND_SIGNER=0x... forge script script/DeployTakumiPay.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --verify
///
/// The deployer address becomes the initial owner.
/// Set INITIAL_OWNER env var to override (useful for multisig deployments).
///
/// After deploying, the owner must allowlist every token that may be used for
/// payments — including native, which is address(0):
///   cast send $PROXY "addAllowedPaymentToken(address)" 0x0000...0000
contract DeployTakumiPay is Script {
    function run() external returns (address proxy) {
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);
        address backendSigner = vm.envAddress("BACKEND_SIGNER");

        vm.startBroadcast();

        // 1. Deploy the implementation (no initializer — _disableInitializers blocks it)
        TakumiPay implementation = new TakumiPay();

        // 2. Deploy the proxy, calling initialize atomically
        bytes memory initData = abi.encodeCall(TakumiPay.initialize, (initialOwner, backendSigner));
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), initData);
        proxy = address(proxyContract);

        vm.stopBroadcast();

        console.log("Implementation:", address(implementation));
        console.log("Proxy (use this address):", proxy);
        console.log("Owner:", initialOwner);
        console.log("Backend signer:", backendSigner);

        // Persist a clean deployment record to deployments/<chainId>.json
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "proxy", proxy);
        vm.serializeAddress(obj, "implementation", address(implementation));
        vm.serializeAddress(obj, "owner", initialOwner);
        vm.serializeAddress(obj, "backendSigner", backendSigner);
        string memory json = vm.serializeUint(obj, "deployedAt", block.timestamp);

        // writeFile rather than writeJson — writeJson requires the target to already
        // exist, which it never does the first time we deploy to a new chain.
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeFile(path, json);
        console.log("Deployment record written to:", path);
    }
}

/// @notice Upgrades an existing proxy to a new TakumiPay implementation.
///
/// Usage:
///   PROXY_ADDRESS=0x... forge script script/DeployTakumiPay.s.sol:UpgradeTakumiPay \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --verify
contract UpgradeTakumiPay is Script {
    function run() external {
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");

        vm.startBroadcast();

        // Deploy new implementation
        TakumiPay newImplementation = new TakumiPay();

        // Upgrade via proxy — caller must be owner
        TakumiPay(payable(proxyAddress)).upgradeToAndCall(address(newImplementation), "");

        vm.stopBroadcast();

        console.log("New implementation:", address(newImplementation));
        console.log("Proxy upgraded:", proxyAddress);
        console.log("New version:", TakumiPay(payable(proxyAddress)).version());
    }
}

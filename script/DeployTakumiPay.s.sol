// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TakumiWallet} from "../src/TakumiPay.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys TakumiWallet behind a UUPS ERC-1967 proxy.
///
/// Usage:
///   forge script script/DeployTakumiPay.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --verify
///
/// The deployer address becomes the initial owner.
/// Set INITIAL_OWNER env var to override (useful for multisig deployments).
contract DeployTakumiPay is Script {
    function run() external returns (address proxy) {
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);

        vm.startBroadcast();

        // 1. Deploy the implementation (no initializer — _disableInitializers blocks it)
        TakumiWallet implementation = new TakumiWallet();

        // 2. Deploy the proxy, calling initialize atomically
        bytes memory initData = abi.encodeCall(TakumiWallet.initialize, (initialOwner));
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), initData);
        proxy = address(proxyContract);

        vm.stopBroadcast();

        console.log("Implementation:", address(implementation));
        console.log("Proxy (use this address):", proxy);
        console.log("Owner:", initialOwner);
    }
}

/// @notice Upgrades an existing proxy to a new TakumiWallet implementation.
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
        TakumiWallet newImplementation = new TakumiWallet();

        // Upgrade via proxy — caller must be owner
        TakumiWallet(payable(proxyAddress)).upgradeToAndCall(address(newImplementation), "");

        vm.stopBroadcast();

        console.log("New implementation:", address(newImplementation));
        console.log("Proxy upgraded:", proxyAddress);
        console.log("New version:", TakumiWallet(payable(proxyAddress)).version());
    }
}

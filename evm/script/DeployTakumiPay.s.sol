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
/// Post-deploy runbook — ORDER MATTERS. Raising a sweep cap and lowering the withdrawal
/// delay are both "loosenings", so they become subject to whatever delay is already in
/// force. Do them first, while withdrawalDelay is still 0:
///
///   1. On a stablecoin-native chain, declare the alias FIRST. On Arc the native coin
///      and the USDC ERC-20 are two views of one balance, so this closes the native
///      path and forces all value through the 6-decimal ERC-20 view:
///        cast send $PROXY "setNativeAliasToken(address)" \
///          0x3600000000000000000000000000000000000000
///
///   2. Allowlist every payment token. On a normal chain that may include native
///      (address(0)); on an alias chain step 1 makes native un-allowlistable:
///        cast send $PROXY "addAllowedPaymentToken(address)" <token>
///
///   3. Set sweep caps. Every exit — sweepPlatformFees, sweepMerchantBacking, withdraw,
///      withdrawAll, recoverToken and executeWithdrawal — is bounded by these, and an
///      unset cap fails closed, so the contract cannot pay anything out until this is
///      done. Raising from 0 is a queue/apply pair that lands in a single block only
///      while withdrawalDelay is 0:
///        cast send $PROXY "queueSweepCap(address,uint256)" <token> <cap>
///        cast send $PROXY "applySweepCap(address)" <token>
///
///   4. Only now raise the withdrawal delay. This also permanently disables the instant
///      withdraw/withdrawAll/recoverToken paths:
///        cast send $PROXY "setWithdrawalDelay(uint256)" 86400
///
/// Amounts follow the token's own decimals: 6 for USDC-style ERC-20s, 18 for native.
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

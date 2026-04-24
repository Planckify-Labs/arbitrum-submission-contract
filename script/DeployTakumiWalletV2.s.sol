// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TakumiWalletV2.sol";

/// @title DeployTakumiWalletV2
/// @notice Foundry script to deploy the V2 implementation and upgrade the proxy.
/// @dev Requires env vars: DEPLOYER_PRIVATE_KEY, PROXY_ADDRESS, BACKEND_SIGNER.
contract DeployTakumiWalletV2 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        address backendSigner = vm.envAddress("BACKEND_SIGNER");

        vm.startBroadcast(deployerKey);

        TakumiWalletV2 implV2 = new TakumiWalletV2();
        TakumiWallet proxy = TakumiWallet(payable(proxyAddress));
        proxy.upgradeToAndCall(
            address(implV2),
            abi.encodeCall(TakumiWalletV2.initializeV2, (backendSigner))
        );

        vm.stopBroadcast();

        console.log("V2 implementation:", address(implV2));
        console.log("Backend signer:", backendSigner);
    }
}

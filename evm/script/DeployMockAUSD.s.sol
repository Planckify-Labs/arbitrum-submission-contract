// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockAUSD} from "../src/MockAUSD.sol";

/// @notice Deploys the open-mint AUSD stand-in (testnet only) and mints an
/// initial demo balance to the deployer.
///
/// Usage:
///   forge script script/DeployMockAUSD.s.sol \
///     --rpc-url monad_testnet \
///     --private-key $PRIVATE_KEY \
///     --broadcast
///
/// Set MINT_TO / MINT_AMOUNT (6-decimal units) to seed a different wallet;
/// defaults to 1,000,000 AUSD to the deployer. Refuses to run on a chain
/// that is not Monad testnet (10143).
contract DeployMockAUSD is Script {
    uint256 internal constant MONAD_TESTNET = 10143;

    function run() external returns (address token) {
        require(block.chainid == MONAD_TESTNET, "MockAUSD: testnet only");

        address mintTo = vm.envOr("MINT_TO", msg.sender);
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(1_000_000 * 1e6));

        vm.startBroadcast();
        MockAUSD ausd = new MockAUSD();
        ausd.mint(mintTo, mintAmount);
        vm.stopBroadcast();

        token = address(ausd);
        console.log("MockAUSD:", token);
        console.log("Minted", mintAmount, "to", mintTo);
    }
}

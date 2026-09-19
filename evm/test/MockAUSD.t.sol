// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockAUSD} from "../src/MockAUSD.sol";

/// Pins the one property the seeded token row depends on: 6 decimals.
contract MockAUSDTest is Test {
    function test_decimalsIsSixAndMintIsOpen() public {
        MockAUSD ausd = new MockAUSD();
        assertEq(ausd.decimals(), 6);
        assertEq(ausd.symbol(), "AUSD");
        assertEq(ausd.name(), "AUSD");
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        ausd.mint(anyone, 5e6);
        assertEq(ausd.balanceOf(anyone), 5e6);
    }
}

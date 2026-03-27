// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TakumiPayProductionTest is Test {
    TakumiWallet public wallet;
    MockERC20 public usdc;
    MockERC20 public usdt;

    address public owner;
    address public admin;
    address public user1;
    address public user2;

    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        wallet = new TakumiWallet();
        usdc = new MockERC20("USD Coin", "USDC");
        usdt = new MockERC20("Tether USD", "USDT");

        wallet.addAdmin(admin);
        wallet.addAllowedPointToken(address(usdc));

        usdc.mint(user1, 10_000e6);
        usdc.mint(user2, 10_000e6);
        usdt.mint(user1, 10_000e6);

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    // ====== Global Pause ======

    function test_SetPaused_Toggles() public {
        assertFalse(wallet.paused());
        wallet.setPaused(true);
        assertTrue(wallet.paused());
        wallet.setPaused(false);
        assertFalse(wallet.paused());
    }

    function test_SetPaused_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TakumiWallet.ContractPausedToggled(true);
        wallet.setPaused(true);
    }

    function test_SetPaused_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert("Not authorized: only owner");
        wallet.setPaused(true);
    }

    function test_Paused_BlocksCreateTransaction() public {
        wallet.setPaused(true);
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert("Contract is paused");
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();
    }

    function test_Paused_BlocksDepositPoints() public {
        wallet.setPaused(true);
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert("Contract is paused");
        wallet.depositPoints(address(usdc), "pt1", 100e6);
        vm.stopPrank();
    }

    function test_Paused_BlocksBatchTransaction() public {
        wallet.setPaused(true);
        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](1);
        params[0] = TakumiWallet.TransactionParams("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert("Contract is paused");
        wallet.createTransactionBatch(params);
        vm.stopPrank();
    }

    // ====== Spending Limits ======

    function test_SetMaxTransactionAmount_Success() public {
        wallet.setMaxTransactionAmount(address(usdc), 500e6);
        assertEq(wallet.maxTransactionAmount(address(usdc)), 500e6);
    }

    function test_SetMaxTransactionAmount_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TakumiWallet.MaxTransactionAmountUpdated(address(usdc), 500e6);
        wallet.setMaxTransactionAmount(address(usdc), 500e6);
    }

    function test_SetMaxTransactionAmount_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert("Not authorized: only owner");
        wallet.setMaxTransactionAmount(address(usdc), 500e6);
    }

    function test_SpendingLimit_BlocksExcessiveAmount() public {
        wallet.setMaxTransactionAmount(address(usdc), 500e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 1000e6);
        vm.expectRevert("Amount exceeds spending limit");
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 600e6);
        vm.stopPrank();
    }

    function test_SpendingLimit_AllowsExactMax() public {
        wallet.setMaxTransactionAmount(address(usdc), 500e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 500e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 500e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
    }

    function test_SpendingLimit_ZeroMeansNoLimit() public {
        wallet.setMaxTransactionAmount(address(usdc), 0); // explicitly no limit

        vm.startPrank(user1);
        usdc.approve(address(wallet), 5000e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 5000e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
    }

    // ====== Batch Transactions ======

    function test_BatchTransaction_ERC20_Success() public {
        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](3);
        params[0] = TakumiWallet.TransactionParams("b1", 1, "v1", address(usdc), "ref1", 100e6);
        params[1] = TakumiWallet.TransactionParams("b2", 2, "v2", address(usdc), "ref2", 200e6);
        params[2] = TakumiWallet.TransactionParams("b3", 3, "v3", address(usdc), "ref3", 150e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 450e6);
        wallet.createTransactionBatch(params);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 3);
        assertEq(usdc.balanceOf(address(wallet)), 450e6);
    }

    function test_BatchTransaction_Native_Success() public {
        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](2);
        params[0] = TakumiWallet.TransactionParams("b1", 1, "v1", address(0), "ref1", 1 ether);
        params[1] = TakumiWallet.TransactionParams("b2", 2, "v2", address(0), "ref2", 2 ether);

        vm.prank(user1);
        wallet.createTransactionBatch{value: 3 ether}(params);

        assertEq(wallet.txCounter(), 2);
        assertEq(address(wallet).balance, 3 ether);
    }

    function test_BatchTransaction_Mixed_Success() public {
        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](2);
        params[0] = TakumiWallet.TransactionParams("b1", 1, "v1", address(usdc), "ref1", 100e6);
        params[1] = TakumiWallet.TransactionParams("b2", 2, "v2", address(0), "ref2", 1 ether);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransactionBatch{value: 1 ether}(params);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 2);
    }

    function test_BatchTransaction_RevertIf_Empty() public {
        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](0);
        vm.prank(user1);
        vm.expectRevert("Empty batch");
        wallet.createTransactionBatch(params);
    }

    function test_BatchTransaction_RevertIf_TooLarge() public {
        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](21);
        for (uint256 i = 0; i < 21; i++) {
            params[i] = TakumiWallet.TransactionParams("b", i, "v", address(usdc), string(abi.encodePacked("ref", i)), 1e6);
        }
        vm.prank(user1);
        vm.expectRevert("Batch too large");
        wallet.createTransactionBatch(params);
    }

    function test_BatchTransaction_RevertIf_DuplicateRefInBatch() public {
        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](2);
        params[0] = TakumiWallet.TransactionParams("b1", 1, "v1", address(usdc), "same_ref", 100e6);
        params[1] = TakumiWallet.TransactionParams("b2", 2, "v2", address(usdc), "same_ref", 100e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        vm.expectRevert("Duplicate refId in batch");
        wallet.createTransactionBatch(params);
        vm.stopPrank();
    }

    function test_BatchTransaction_RevertIf_ExistingRefId() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "existing_ref", 100e6);

        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](1);
        params[0] = TakumiWallet.TransactionParams("b2", 2, "v2", address(usdc), "existing_ref", 100e6);

        vm.expectRevert("refId must be unique");
        wallet.createTransactionBatch(params);
        vm.stopPrank();
    }

    function test_BatchTransaction_RevertIf_IncorrectETH() public {
        TakumiWallet.TransactionParams[] memory params = new TakumiWallet.TransactionParams[](1);
        params[0] = TakumiWallet.TransactionParams("b1", 1, "v1", address(0), "ref1", 1 ether);

        vm.prank(user1);
        vm.expectRevert("Incorrect ETH amount for batch");
        wallet.createTransactionBatch{value: 0.5 ether}(params);
    }

    // ====== Withdrawal Timelock ======

    function test_SetWithdrawalDelay_Success() public {
        wallet.setWithdrawalDelay(1 days);
        assertEq(wallet.withdrawalDelay(), 1 days);
    }

    function test_SetWithdrawalDelay_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TakumiWallet.WithdrawalDelayUpdated(1 days);
        wallet.setWithdrawalDelay(1 days);
    }

    function test_SetWithdrawalDelay_RevertIf_ExceedsMax() public {
        vm.expectRevert("Delay exceeds maximum");
        wallet.setWithdrawalDelay(8 days);
    }

    function test_SetWithdrawalDelay_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert("Not authorized: only owner");
        wallet.setWithdrawalDelay(1 days);
    }

    function test_QueueWithdrawal_Success() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        (address token, address to, uint256 amount, uint256 unlockTime, bool executed, bool cancelled) = wallet.withdrawalRequests(wId);
        assertEq(token, address(usdc));
        assertEq(to, owner);
        assertEq(amount, 100e6);
        assertEq(unlockTime, block.timestamp + 1 days);
        assertFalse(executed);
        assertFalse(cancelled);
    }

    function test_QueueWithdrawal_EmitsEvent() public {
        wallet.setWithdrawalDelay(1 days);

        vm.expectEmit(false, true, true, true);
        emit TakumiWallet.WithdrawalQueued(bytes32(0), address(usdc), owner, 100e6, block.timestamp + 1 days);
        wallet.queueWithdrawal(address(usdc), owner, 100e6);
    }

    function test_ExecuteWithdrawal_AfterDelay() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        vm.warp(block.timestamp + 1 days);
        wallet.executeWithdrawal(wId);

        assertEq(usdc.balanceOf(owner), 100e6);
        (,,,, bool executed,) = wallet.withdrawalRequests(wId);
        assertTrue(executed);
    }

    function test_ExecuteWithdrawal_RevertIf_TooEarly() public {
        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        vm.expectRevert("Timelock not expired");
        wallet.executeWithdrawal(wId);
    }

    function test_ExecuteWithdrawal_RevertIf_AlreadyExecuted() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);
        vm.warp(block.timestamp + 1 days);
        wallet.executeWithdrawal(wId);

        vm.expectRevert("Already executed");
        wallet.executeWithdrawal(wId);
    }

    function test_CancelWithdrawal_Success() public {
        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        wallet.cancelWithdrawal(wId);

        (,,,,, bool cancelled) = wallet.withdrawalRequests(wId);
        assertTrue(cancelled);
    }

    function test_CancelWithdrawal_EmitsEvent() public {
        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        vm.expectEmit(true, false, false, false);
        emit TakumiWallet.WithdrawalCancelled(wId);
        wallet.cancelWithdrawal(wId);
    }

    function test_CancelWithdrawal_BlocksExecution() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);
        wallet.cancelWithdrawal(wId);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("Already cancelled");
        wallet.executeWithdrawal(wId);
    }

    function test_ExecuteWithdrawal_RevertIf_NotFound() public {
        vm.expectRevert("Withdrawal not found");
        wallet.executeWithdrawal(bytes32(uint256(999)));
    }

    // ====== Token Recovery ======

    function test_RecoverToken_ERC20_Success() public {
        // Simulate accidental ERC20 send
        usdt.mint(address(wallet), 500e6);

        wallet.recoverToken(address(usdt), owner, 500e6);

        assertEq(usdt.balanceOf(owner), 500e6);
        assertEq(usdt.balanceOf(address(wallet)), 0);
    }

    function test_RecoverToken_Native_Success() public {
        vm.deal(address(wallet), 1 ether);

        uint256 before = user2.balance;
        wallet.recoverToken(address(0), user2, 1 ether);

        assertEq(user2.balance - before, 1 ether);
        assertEq(address(wallet).balance, 0);
    }

    function test_RecoverToken_EmitsEvent() public {
        usdt.mint(address(wallet), 100e6);

        vm.expectEmit(true, true, false, true);
        emit TakumiWallet.TokenRecovered(address(usdt), owner, 100e6);
        wallet.recoverToken(address(usdt), owner, 100e6);
    }

    function test_RecoverToken_RevertIf_NotOwner() public {
        usdt.mint(address(wallet), 100e6);

        vm.prank(user1);
        vm.expectRevert("Not authorized: only owner");
        wallet.recoverToken(address(usdt), user1, 100e6);
    }

    function test_RecoverToken_RevertIf_ZeroAddress() public {
        vm.expectRevert("Invalid recipient");
        wallet.recoverToken(address(usdt), address(0), 100e6);
    }

    // ====== Interaction: Global Pause vs Point Deposits Pause ======

    function test_BothPauses_Independent() public {
        // Global pause blocks everything
        wallet.setPaused(true);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert("Contract is paused");
        wallet.depositPoints(address(usdc), "pt1", 100e6);
        vm.stopPrank();

        // Unpause global, pause point deposits
        wallet.setPaused(false);
        wallet.setPointDepositsPaused(true);

        vm.startPrank(user1);
        vm.expectRevert("Point deposits are paused");
        wallet.depositPoints(address(usdc), "pt1", 100e6);
        vm.stopPrank();

        // createTransaction should still work when only point deposits are paused
        vm.startPrank(user1);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "tx_ref1", 100e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
    }
}

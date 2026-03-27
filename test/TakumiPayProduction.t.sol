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

/// @dev Malicious ERC20 that attempts reentrancy on transferFrom
contract ReentrantERC20 is ERC20 {
    address public target;
    bool public attacking;

    constructor() ERC20("Reentrant", "REENT") {}

    function setTarget(address _target) external {
        target = _target;
    }

    function setAttacking(bool _attacking) external {
        attacking = _attacking;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (attacking && target != address(0)) {
            attacking = false;
            // Attempt reentrancy into createTransaction
            TakumiWallet(payable(target)).createTransaction("b_reentry", 1, "v_reentry", address(this), "ref_reentry", amount);
        }
        return super.transferFrom(from, to, amount);
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
        wallet.setMaxTransactionAmount(address(usdc), 0);

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

        (address token, address to, uint256 amount, uint256 unlockTime, bool executed, bool cancelled) =
            wallet.withdrawalRequests(wId);
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
        wallet.setPaused(true);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert("Contract is paused");
        wallet.depositPoints(address(usdc), "pt1", 100e6);
        vm.stopPrank();

        wallet.setPaused(false);
        wallet.setPointDepositsPaused(true);

        vm.startPrank(user1);
        vm.expectRevert("Point deposits are paused");
        wallet.depositPoints(address(usdc), "pt1", 100e6);
        vm.stopPrank();

        vm.startPrank(user1);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "tx_ref1", 100e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
    }

    // ====== Security: Two-Step Ownership Transfer ======

    function test_TransferOwnership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        wallet.transferOwnership(newOwner);
        assertEq(wallet.pendingOwner(), newOwner);
        assertEq(wallet.owner(), owner); // owner unchanged until accepted

        vm.prank(newOwner);
        wallet.acceptOwnership();

        assertEq(wallet.owner(), newOwner);
        assertEq(wallet.pendingOwner(), address(0));
    }

    function test_TransferOwnership_EmitsEvents() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, false, false);
        emit TakumiWallet.OwnershipTransferInitiated(owner, newOwner);
        wallet.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, false);
        emit TakumiWallet.OwnershipTransferred(owner, newOwner);
        vm.prank(newOwner);
        wallet.acceptOwnership();
    }

    function test_TransferOwnership_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert("Not authorized: only owner");
        wallet.transferOwnership(user1);
    }

    function test_TransferOwnership_RevertIf_ZeroAddress() public {
        vm.expectRevert("Invalid owner address");
        wallet.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertIf_NotPending() public {
        wallet.transferOwnership(user2);

        vm.prank(user1);
        vm.expectRevert("Not pending owner");
        wallet.acceptOwnership();
    }

    function test_CancelOwnershipTransfer() public {
        wallet.transferOwnership(user1);
        assertEq(wallet.pendingOwner(), user1);

        wallet.cancelOwnershipTransfer();
        assertEq(wallet.pendingOwner(), address(0));

        vm.prank(user1);
        vm.expectRevert("Not pending owner");
        wallet.acceptOwnership();
    }

    // ====== Security: Admin List Integrity After Removal ======

    function test_RemoveAdmin_PrunesArray() public {
        address admin2 = makeAddr("admin2");
        address admin3 = makeAddr("admin3");

        wallet.addAdmin(admin2);
        wallet.addAdmin(admin3);

        // Remove middle admin (admin)
        wallet.removeAdmin(admin);

        address[] memory activeAdmins = wallet.getAllAdmins();
        assertEq(activeAdmins.length, 2);

        // Verify removed admin is not in the list
        for (uint256 i = 0; i < activeAdmins.length; i++) {
            assertTrue(activeAdmins[i] != admin);
        }

        // Verify isAdmin returns false
        assertFalse(wallet.isAdmin(admin));
    }

    function test_RemoveAdmin_LastElement() public {
        // Remove the only admin
        wallet.removeAdmin(admin);

        address[] memory activeAdmins = wallet.getAllAdmins();
        assertEq(activeAdmins.length, 0);
    }

    function test_AddAdmin_AfterRemove_ReuseSlot() public {
        wallet.removeAdmin(admin);
        // Re-adding same admin should work
        wallet.addAdmin(admin);
        assertTrue(wallet.isAdmin(admin));
        assertEq(wallet.getAllAdmins().length, 1);
    }

    // ====== Security: Point Token List Integrity After Removal ======

    function test_RemovePointToken_PrunesArray() public {
        wallet.addAllowedPointToken(address(usdt));

        wallet.removeAllowedPointToken(address(usdc));

        address[] memory tokens = wallet.getAllowedPointTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdt));
        assertFalse(wallet.isAllowedPointToken(address(usdc)));
    }

    function test_RemovePointToken_OnlyElement() public {
        wallet.removeAllowedPointToken(address(usdc));

        address[] memory tokens = wallet.getAllowedPointTokens();
        assertEq(tokens.length, 0);
    }

    // ====== Security: Reentrancy Guard ======

    function test_Reentrancy_BlockedOnCreateTransaction() public {
        ReentrantERC20 reentrantToken = new ReentrantERC20();
        reentrantToken.mint(user1, 1000e18);
        reentrantToken.setTarget(address(wallet));
        reentrantToken.setAttacking(true);

        vm.startPrank(user1);
        reentrantToken.approve(address(wallet), type(uint256).max);

        // Attempt reentrancy — should revert due to ReentrancyGuard
        vm.expectRevert();
        wallet.createTransaction("b_attack", 1, "v_attack", address(reentrantToken), "ref_attack", 100e18);
        vm.stopPrank();
    }

    // ====== Security: Fallback Revert ======

    function test_Fallback_RevertsOnUnknownSelector() public {
        // Calling with unknown selector should revert
        (bool success,) = address(wallet).call(abi.encodeWithSignature("nonExistentFunction()"));
        assertFalse(success);
    }

    function test_Receive_AcceptsNativeETH() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool success,) = address(wallet).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(wallet).balance, 1 ether);
    }

    // ====== Security: String Length Validation ======

    function test_CreateTransaction_RevertIf_EmptyRefId() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert("Invalid refId length");
        wallet.createTransaction("b1", 1, "v1", address(usdc), "", 100e6);
        vm.stopPrank();
    }

    function test_CreateTransaction_RevertIf_RefIdTooLong() public {
        string memory longRefId = new string(257);
        // Fill with 'a' characters
        bytes memory longRefIdBytes = bytes(longRefId);
        for (uint256 i = 0; i < 257; i++) {
            longRefIdBytes[i] = "a";
        }

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert("Invalid refId length");
        wallet.createTransaction("b1", 1, "v1", address(usdc), string(longRefIdBytes), 100e6);
        vm.stopPrank();
    }

    function test_CreateTransaction_RevertIf_EmptyBookingId() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert("Invalid bookingId length");
        wallet.createTransaction("", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();
    }

    // ====== Security: Pagination Limit Cap ======

    function test_GetUserTransactions_RevertIf_LimitTooLarge() public {
        vm.prank(user1);
        vm.expectRevert("Limit too large");
        wallet.getUserTransactions(0, 501);
    }

    function test_GetUserPointDeposits_RevertIf_LimitTooLarge() public {
        vm.prank(user1);
        vm.expectRevert("Limit too large");
        wallet.getUserPointDeposits(0, 501);
    }

    function test_GetTransactionsInRange_RevertIf_LimitTooLarge() public {
        vm.expectRevert("Limit too large");
        wallet.getTransactionsInRange(0, block.timestamp, 0, 501);
    }

    function test_GetTransactionsInRange_RevertIf_InvalidRange() public {
        vm.expectRevert("Invalid range");
        wallet.getTransactionsInRange(block.timestamp + 1, block.timestamp, 0, 10);
    }

    // ====== Security: addAdmin zero address ======

    function test_AddAdmin_RevertIf_ZeroAddress() public {
        vm.expectRevert("Invalid admin address");
        wallet.addAdmin(address(0));
    }
}

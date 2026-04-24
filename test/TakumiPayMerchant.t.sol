// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPayV2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract TakumiWalletMerchantTest is Test {
    TakumiPayV2 public wallet;
    MockUSDC public usdc;

    address public owner = address(0x1);
    uint256 public signerKey = 0xA11CE;
    address public signer;
    address public payer = address(0x3);

    function setUp() public {
        signer = vm.addr(signerKey);

        // Deploy V1 behind proxy
        TakumiWallet impl = new TakumiWallet();
        bytes memory initData = abi.encodeCall(TakumiWallet.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // Upgrade to V2
        TakumiPayV2 implV2 = new TakumiPayV2();
        vm.prank(owner);
        TakumiWallet(payable(address(proxy))).upgradeToAndCall(
            address(implV2),
            abi.encodeCall(TakumiPayV2.initializeV2, (signer))
        );

        wallet = TakumiPayV2(payable(address(proxy)));

        // Setup mock USDC
        usdc = new MockUSDC();
        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(wallet), type(uint256).max);
    }

    // ====== Helpers ======

    function _signQuote(TakumiPayV2.QuoteCommitment memory quote)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                wallet.QUOTE_TYPEHASH(),
                keccak256(bytes(quote.refId)),
                keccak256(bytes(quote.merchantId)),
                quote.tokenAddress,
                quote.amount,
                quote.platformFeeAmount,
                quote.fiatAmountMinor,
                quote.fiatCurrency,
                quote.exchangeRateId,
                quote.expiresAt
            )
        );

        bytes32 domainSeparator = wallet.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signQuoteWithKey(TakumiPayV2.QuoteCommitment memory quote, uint256 privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                wallet.QUOTE_TYPEHASH(),
                keccak256(bytes(quote.refId)),
                keccak256(bytes(quote.merchantId)),
                quote.tokenAddress,
                quote.amount,
                quote.platformFeeAmount,
                quote.fiatAmountMinor,
                quote.fiatCurrency,
                quote.exchangeRateId,
                quote.expiresAt
            )
        );

        bytes32 domainSeparator = wallet.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultQuote() internal view returns (TakumiPayV2.QuoteCommitment memory) {
        return TakumiPayV2.QuoteCommitment({
            refId: "test-ref-001",
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: 10e6,
            platformFeeAmount: 0.5e6,
            fiatAmountMinor: 150000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: block.timestamp + 900
        });
    }

    function _defaultNativeQuote() internal view returns (TakumiPayV2.QuoteCommitment memory) {
        return TakumiPayV2.QuoteCommitment({
            refId: "native-ref-001",
            merchantId: "merchant-001",
            tokenAddress: address(0),
            amount: 1 ether,
            platformFeeAmount: 0.01 ether,
            fiatAmountMinor: 5000000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 2,
            expiresAt: block.timestamp + 900
        });
    }

    // ====== processMerchantPayment: Happy Path (ERC-20) ======

    function test_processMerchantPayment_happyPath() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 walletBefore = usdc.balanceOf(address(wallet));

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        // Token transferred
        assertEq(usdc.balanceOf(payer), payerBefore - quote.amount);
        assertEq(usdc.balanceOf(address(wallet)), walletBefore + quote.amount);

        // Payment stored
        TakumiPayV2.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("test-ref-001");
        assertEq(payment.payer, payer);
        assertEq(payment.tokenAddress, address(usdc));
        assertEq(payment.amount, 10e6);
        assertEq(payment.platformFeeAmount, 0.5e6);
        assertEq(payment.fiatAmountMinor, 150000);
        assertEq(payment.fiatCurrency, bytes3("IDR"));
        assertEq(payment.exchangeRateId, 1);
        assertEq(keccak256(bytes(payment.merchantId)), keccak256(bytes("merchant-001")));
        assertEq(keccak256(bytes(payment.refId)), keccak256(bytes("test-ref-001")));

        // Fee accrued
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.5e6);
    }

    // ====== processMerchantPayment: Native Token ======

    function test_processMerchantPayment_nativeToken() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        uint256 walletBefore = address(wallet).balance;

        vm.prank(payer);
        wallet.processMerchantPayment{value: 1 ether}(quote, sig);

        assertEq(address(wallet).balance, walletBefore + 1 ether);

        TakumiPayV2.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("native-ref-001");
        assertEq(payment.payer, payer);
        assertEq(payment.tokenAddress, address(0));
        assertEq(payment.amount, 1 ether);
        assertEq(payment.platformFeeAmount, 0.01 ether);

        assertEq(wallet.platformFeeAccrued(address(0)), 0.01 ether);
    }

    // ====== processMerchantPayment: Emits Event ======

    function test_processMerchantPayment_emitsEvent() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.expectEmit(true, true, true, true);
        emit TakumiPayV2.MerchantPaymentProcessed(
            "test-ref-001",
            "merchant-001",
            payer,
            address(usdc),
            10e6,
            0.5e6,
            150000,
            1
        );

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: QuoteExpired ======

    function test_revert_quoteExpired() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        // Warp past expiry
        vm.warp(quote.expiresAt + 1);

        vm.prank(payer);
        vm.expectRevert(TakumiPayV2.QuoteExpired.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: RefConsumed ======

    function test_revert_refConsumed() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        // Second call with same refId should revert
        vm.prank(payer);
        vm.expectRevert(TakumiPayV2.RefConsumed.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: BadQuote (wrong signer) ======

    function test_revert_badQuote_wrongSigner() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        uint256 wrongKey = 0xBEEF;
        bytes memory sig = _signQuoteWithKey(quote, wrongKey);

        vm.prank(payer);
        vm.expectRevert(TakumiPayV2.BadQuote.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: FeeExceedsAmount ======

    function test_revert_feeExceedsAmount() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        quote.platformFeeAmount = quote.amount + 1; // fee > amount
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        vm.expectRevert(TakumiPayV2.FeeExceedsAmount.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: NativeAmountMismatch ======

    function test_revert_nativeAmountMismatch() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        vm.prank(payer);
        vm.expectRevert(TakumiPayV2.NativeAmountMismatch.selector);
        // Send wrong amount
        wallet.processMerchantPayment{value: 0.5 ether}(quote, sig);
    }

    // ====== Revert: UnexpectedNative ======

    function test_revert_unexpectedNative() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(TakumiPayV2.UnexpectedNative.selector);
        // Send ETH with ERC-20 quote
        wallet.processMerchantPayment{value: 0.1 ether}(quote, sig);
    }

    // ====== Revert: Contract Paused ======

    function test_revert_processMerchantPayment_whenPaused() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.prank(owner);
        wallet.setPaused(true);

        vm.prank(payer);
        vm.expectRevert(TakumiWallet.ContractPaused.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== sweepPlatformFees: Happy Path ======

    function test_sweepPlatformFees() public {
        // First create a payment to accrue fees
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        address treasury = makeAddr("treasury");
        uint256 accrued = wallet.platformFeeAccrued(address(usdc));
        assertEq(accrued, 0.5e6);

        vm.prank(owner);
        wallet.sweepPlatformFees(address(usdc), treasury, 0.5e6);

        assertEq(usdc.balanceOf(treasury), 0.5e6);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);
    }

    // ====== sweepPlatformFees: Emits Event ======

    function test_sweepPlatformFees_emitsEvent() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        address treasury = makeAddr("treasury");

        vm.expectEmit(true, true, false, true);
        emit TakumiPayV2.PlatformFeesSwept(address(usdc), treasury, 0.5e6);

        vm.prank(owner);
        wallet.sweepPlatformFees(address(usdc), treasury, 0.5e6);
    }

    // ====== Revert: sweepPlatformFees exceeds accrued ======

    function test_revert_sweepPlatformFees_exceedsAccrued() public {
        // No fees accrued yet
        vm.prank(owner);
        vm.expectRevert(TakumiPayV2.FeeAmountInvalid.selector);
        wallet.sweepPlatformFees(address(usdc), makeAddr("treasury"), 1);
    }

    function test_revert_sweepPlatformFees_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(TakumiPayV2.FeeAmountInvalid.selector);
        wallet.sweepPlatformFees(address(usdc), makeAddr("treasury"), 0);
    }

    function test_revert_sweepPlatformFees_notOwner() public {
        vm.prank(payer);
        vm.expectRevert(TakumiWallet.NotOwner.selector);
        wallet.sweepPlatformFees(address(usdc), payer, 1);
    }

    // ====== sweepMerchantBacking: Happy Path ======

    function test_sweepMerchantBacking() public {
        // Create a payment so wallet holds funds
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        // Sweep the merchant backing (amount minus fee)
        address merchant = makeAddr("merchant");
        uint256 merchantAmount = quote.amount - quote.platformFeeAmount;

        vm.prank(owner);
        wallet.sweepMerchantBacking(address(usdc), merchant, merchantAmount);

        assertEq(usdc.balanceOf(merchant), merchantAmount);
    }

    // ====== sweepMerchantBacking: Emits Event ======

    function test_sweepMerchantBacking_emitsEvent() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        address merchant = makeAddr("merchant");

        vm.expectEmit(true, true, false, true);
        emit TakumiPayV2.MerchantBackingSwept(address(usdc), merchant, 9.5e6);

        vm.prank(owner);
        wallet.sweepMerchantBacking(address(usdc), merchant, 9.5e6);
    }

    // ====== sweepMerchantBacking: Native Token ======

    function test_sweepMerchantBacking_nativeToken() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        vm.prank(payer);
        wallet.processMerchantPayment{value: 1 ether}(quote, sig);

        address merchant = makeAddr("merchant");
        uint256 merchantBefore = merchant.balance;

        vm.prank(owner);
        wallet.sweepMerchantBacking(address(0), merchant, 0.99 ether);

        assertEq(merchant.balance, merchantBefore + 0.99 ether);
    }

    function test_revert_sweepMerchantBacking_notOwner() public {
        vm.prank(payer);
        vm.expectRevert(TakumiWallet.NotOwner.selector);
        wallet.sweepMerchantBacking(address(usdc), payer, 1);
    }

    function test_revert_sweepMerchantBacking_zeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(TakumiPayV2.ZeroRecipient.selector);
        wallet.sweepMerchantBacking(address(usdc), address(0), 1);
    }

    // ====== rotateBackendSigner ======

    function test_rotateBackendSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(owner);
        wallet.rotateBackendSigner(newSigner);

        assertEq(wallet.backendSigner(), newSigner);
    }

    function test_rotateBackendSigner_emitsEvent() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, true, false, false);
        emit TakumiPayV2.BackendSignerRotated(signer, newSigner);

        vm.prank(owner);
        wallet.rotateBackendSigner(newSigner);
    }

    function test_rotateBackendSigner_newSignerWorks_oldDoesNot() public {
        uint256 newSignerKey = 0xDEAD;
        address newSignerAddr = vm.addr(newSignerKey);

        vm.prank(owner);
        wallet.rotateBackendSigner(newSignerAddr);

        // Quote signed by new signer should work
        TakumiPayV2.QuoteCommitment memory quote = TakumiPayV2.QuoteCommitment({
            refId: "rotated-ref-001",
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: 5e6,
            platformFeeAmount: 0.25e6,
            fiatAmountMinor: 75000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: block.timestamp + 900
        });
        bytes memory newSig = _signQuoteWithKey(quote, newSignerKey);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, newSig);

        // Quote signed by old signer should fail
        TakumiPayV2.QuoteCommitment memory quote2 = TakumiPayV2.QuoteCommitment({
            refId: "rotated-ref-002",
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: 5e6,
            platformFeeAmount: 0.25e6,
            fiatAmountMinor: 75000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: block.timestamp + 900
        });
        bytes memory oldSig = _signQuoteWithKey(quote2, signerKey);

        vm.prank(payer);
        vm.expectRevert(TakumiPayV2.BadQuote.selector);
        wallet.processMerchantPayment(quote2, oldSig);
    }

    function test_revert_rotateBackendSigner_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TakumiPayV2.ZeroSigner.selector);
        wallet.rotateBackendSigner(address(0));
    }

    function test_revert_rotateBackendSigner_notOwner() public {
        vm.prank(payer);
        vm.expectRevert(TakumiWallet.NotOwner.selector);
        wallet.rotateBackendSigner(makeAddr("newSigner"));
    }

    // ====== getMerchantPaymentByRef ======

    function test_getMerchantPaymentByRef() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        TakumiPayV2.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("test-ref-001");

        assertEq(payment.payer, payer);
        assertEq(payment.tokenAddress, address(usdc));
        assertEq(payment.amount, 10e6);
        assertEq(payment.platformFeeAmount, 0.5e6);
        assertEq(payment.fiatAmountMinor, 150000);
        assertEq(payment.fiatCurrency, bytes3("IDR"));
        assertEq(payment.exchangeRateId, 1);
        assertEq(payment.timestamp, block.timestamp);
        assertEq(keccak256(bytes(payment.merchantId)), keccak256(bytes("merchant-001")));
        assertEq(keccak256(bytes(payment.refId)), keccak256(bytes("test-ref-001")));
    }

    function test_getMerchantPaymentByRef_returnsEmptyForUnknown() public view {
        TakumiPayV2.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("unknown-ref");
        assertEq(payment.payer, address(0));
        assertEq(payment.amount, 0);
    }

    // ====== version ======

    function test_version() public view {
        assertEq(wallet.version(), "2.0.0");
    }

    // ====== Existing Functionality Preserved After Upgrade ======

    function test_existingFunctionalityPreserved() public {
        // createTransaction from V1 still works after V2 upgrade
        MockUSDC usdc2 = new MockUSDC();
        usdc2.mint(payer, 1000e6);

        vm.startPrank(payer);
        usdc2.approve(address(wallet), 100e6);
        wallet.createTransaction("booking-001", 1, "variant-001", address(usdc2), "v1-ref-001", 100e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);

        // Owner can still manage admins
        vm.prank(owner);
        wallet.addAdmin(makeAddr("admin2"));
        assertTrue(wallet.isAdmin(makeAddr("admin2")));

        // Owner address is preserved
        assertEq(wallet.owner(), owner);
    }

    // ====== initializeV2 cannot be called twice ======

    function test_revert_initializeV2_cannotReinitialize() public {
        vm.prank(owner);
        vm.expectRevert();
        wallet.initializeV2(makeAddr("anotherSigner"));
    }

    // ====== Sweep platform fees with native token ======

    function test_sweepPlatformFees_nativeToken() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        vm.prank(payer);
        wallet.processMerchantPayment{value: 1 ether}(quote, sig);

        address treasury = makeAddr("treasury");
        uint256 accrued = wallet.platformFeeAccrued(address(0));
        assertEq(accrued, 0.01 ether);

        uint256 treasuryBefore = treasury.balance;

        vm.prank(owner);
        wallet.sweepPlatformFees(address(0), treasury, 0.01 ether);

        assertEq(treasury.balance, treasuryBefore + 0.01 ether);
        assertEq(wallet.platformFeeAccrued(address(0)), 0);
    }

    // ====== Partial fee sweep ======

    function test_sweepPlatformFees_partialSweep() public {
        TakumiPayV2.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        address treasury = makeAddr("treasury");

        // Sweep half the fees
        vm.prank(owner);
        wallet.sweepPlatformFees(address(usdc), treasury, 0.25e6);

        assertEq(usdc.balanceOf(treasury), 0.25e6);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.25e6);

        // Sweep remaining
        vm.prank(owner);
        wallet.sweepPlatformFees(address(usdc), treasury, 0.25e6);

        assertEq(usdc.balanceOf(treasury), 0.5e6);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);
    }

    // ====== Multiple payments accumulate fees ======

    function test_multipleMerchantPayments_accumulateFees() public {
        TakumiPayV2.QuoteCommitment memory quote1 = _defaultQuote();
        bytes memory sig1 = _signQuote(quote1);
        vm.prank(payer);
        wallet.processMerchantPayment(quote1, sig1);

        TakumiPayV2.QuoteCommitment memory quote2 = TakumiPayV2.QuoteCommitment({
            refId: "test-ref-002",
            merchantId: "merchant-002",
            tokenAddress: address(usdc),
            amount: 20e6,
            platformFeeAmount: 1e6,
            fiatAmountMinor: 300000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 3,
            expiresAt: block.timestamp + 900
        });
        bytes memory sig2 = _signQuote(quote2);
        vm.prank(payer);
        wallet.processMerchantPayment(quote2, sig2);

        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.5e6 + 1e6);
    }

    // ====== Zero fee payment works ======

    function test_processMerchantPayment_zeroFee() public {
        TakumiPayV2.QuoteCommitment memory quote = TakumiPayV2.QuoteCommitment({
            refId: "zero-fee-ref",
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: 10e6,
            platformFeeAmount: 0,
            fiatAmountMinor: 150000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: block.timestamp + 900
        });
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);

        TakumiPayV2.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("zero-fee-ref");
        assertEq(payment.amount, 10e6);
        assertEq(payment.platformFeeAmount, 0);
    }

    // ====== backendSigner is set after initialization ======

    function test_backendSigner_setAfterInit() public view {
        assertEq(wallet.backendSigner(), signer);
    }
}

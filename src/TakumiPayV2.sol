// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TakumiPay.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title TakumiPayV2
/// @notice V2 upgrade of TakumiWallet adding merchant payment functionality with EIP-712 signed quotes.
/// @dev Inherits TakumiWallet (UUPS) and EIP712Upgradeable. New state is appended after parent storage.
///      The parent's 50-slot __gap remains untouched; V2 state lives in slots after the parent layout.
contract TakumiPayV2 is TakumiWallet, EIP712Upgradeable {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // === Merchant Payment Structs ===

    struct QuoteCommitment {
        string  refId;
        string  merchantId;
        address tokenAddress;
        uint256 amount;
        uint256 platformFeeAmount;
        uint256 fiatAmountMinor;
        bytes3  fiatCurrency;
        uint256 exchangeRateId;
        uint256 expiresAt;
    }

    struct MerchantPayment {
        address payer;
        address tokenAddress;
        string  merchantId;
        string  refId;
        uint256 amount;
        uint256 platformFeeAmount;
        uint256 fiatAmountMinor;
        bytes3  fiatCurrency;
        uint256 exchangeRateId;
        uint256 timestamp;
    }

    // === Merchant Payment State ===

    address public backendSigner;
    mapping(bytes32 => bool) private _consumedRefs;
    mapping(bytes32 => MerchantPayment) private _payments;
    mapping(address => uint256) public platformFeeAccrued;

    // === Events ===

    event MerchantPaymentProcessed(
        string  indexed refId,
        string  indexed merchantId,
        address indexed payer,
        address tokenAddress,
        uint256 amount,
        uint256 platformFeeAmount,
        uint256 fiatAmountMinor,
        uint256 exchangeRateId
    );
    event PlatformFeesSwept(address indexed token, address indexed recipient, uint256 amount);
    event MerchantBackingSwept(address indexed token, address indexed recipient, uint256 amount);
    event BackendSignerRotated(address indexed previous, address indexed next);

    // === Errors ===

    error QuoteExpired();
    error RefConsumed();
    error BadQuote();
    error FeeExceedsAmount();
    error NativeAmountMismatch();
    error UnexpectedNative();
    error FeeAmountInvalid();
    error ZeroSigner();
    error ZeroRecipient();
    error NativeTransferFailed();

    // === EIP-712 ===

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "QuoteCommitment(string refId,string merchantId,address tokenAddress,"
        "uint256 amount,uint256 platformFeeAmount,uint256 fiatAmountMinor,"
        "bytes3 fiatCurrency,uint256 exchangeRateId,uint256 expiresAt)"
    );

    // === Initializer for V2 ===

    /// @notice Re-initializer for the V2 upgrade. Must be called exactly once via upgradeToAndCall.
    /// @param _backendSigner Address of the backend signer that produces EIP-712 quote signatures.
    function initializeV2(address _backendSigner) external reinitializer(2) {
        if (_backendSigner == address(0)) revert ZeroSigner();
        __EIP712_init("TakumiPay", "1");
        backendSigner = _backendSigner;
    }

    // === Override version ===

    function version() external pure override returns (string memory) {
        return "2.0.0";
    }

    // === Public domain separator accessor (for off-chain tooling / tests) ===

    /// @notice Returns the EIP-712 domain separator used for quote verification.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // === Core: processMerchantPayment ===

    /// @notice Processes a merchant payment using a backend-signed EIP-712 quote.
    /// @param quote The QuoteCommitment struct with payment details.
    /// @param backendSignature The EIP-712 signature produced by backendSigner.
    function processMerchantPayment(
        QuoteCommitment calldata quote,
        bytes calldata backendSignature
    ) external payable whenNotPaused nonReentrant {
        if (block.timestamp > quote.expiresAt) revert QuoteExpired();

        bytes32 refKey = keccak256(bytes(quote.refId));
        if (_consumedRefs[refKey]) revert RefConsumed();

        bytes32 structHash = keccak256(abi.encode(
            QUOTE_TYPEHASH,
            keccak256(bytes(quote.refId)),
            keccak256(bytes(quote.merchantId)),
            quote.tokenAddress,
            quote.amount,
            quote.platformFeeAmount,
            quote.fiatAmountMinor,
            quote.fiatCurrency,
            quote.exchangeRateId,
            quote.expiresAt
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (ECDSA.recover(digest, backendSignature) != backendSigner) revert BadQuote();

        if (quote.platformFeeAmount > quote.amount) revert FeeExceedsAmount();

        if (quote.tokenAddress == address(0)) {
            if (msg.value != quote.amount) revert NativeAmountMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedNative();
            IERC20(quote.tokenAddress).safeTransferFrom(msg.sender, address(this), quote.amount);
        }

        _consumedRefs[refKey] = true;
        _payments[refKey] = MerchantPayment({
            payer:             msg.sender,
            tokenAddress:      quote.tokenAddress,
            merchantId:        quote.merchantId,
            refId:             quote.refId,
            amount:            quote.amount,
            platformFeeAmount: quote.platformFeeAmount,
            fiatAmountMinor:   quote.fiatAmountMinor,
            fiatCurrency:      quote.fiatCurrency,
            exchangeRateId:    quote.exchangeRateId,
            timestamp:         block.timestamp
        });
        platformFeeAccrued[quote.tokenAddress] += quote.platformFeeAmount;

        emit MerchantPaymentProcessed(
            quote.refId,
            quote.merchantId,
            msg.sender,
            quote.tokenAddress,
            quote.amount,
            quote.platformFeeAmount,
            quote.fiatAmountMinor,
            quote.exchangeRateId
        );
    }

    // === Read ===

    /// @notice Returns the MerchantPayment record for a given refId.
    function getMerchantPaymentByRef(string calldata refId)
        external view returns (MerchantPayment memory)
    {
        return _payments[keccak256(bytes(refId))];
    }

    // === Treasury ===

    /// @notice Sweeps platform fees (bounded by accrued amount) to a recipient.
    function sweepPlatformFees(address token, address recipient, uint256 amount)
        external onlyOwner nonReentrant
    {
        if (amount == 0 || amount > platformFeeAccrued[token]) revert FeeAmountInvalid();
        platformFeeAccrued[token] -= amount;
        _transferOutMerchant(token, recipient, amount);
        emit PlatformFeesSwept(token, recipient, amount);
    }

    /// @notice Sweeps merchant backing funds to a recipient (unbounded).
    function sweepMerchantBacking(address token, address recipient, uint256 amount)
        external onlyOwner nonReentrant
    {
        _transferOutMerchant(token, recipient, amount);
        emit MerchantBackingSwept(token, recipient, amount);
    }

    // === Signer Rotation ===

    /// @notice Rotates the backend signer address. Only callable by owner.
    function rotateBackendSigner(address next) external onlyOwner {
        if (next == address(0)) revert ZeroSigner();
        emit BackendSignerRotated(backendSigner, next);
        backendSigner = next;
    }

    // === Internal ===

    function _transferOutMerchant(address token, address recipient, uint256 amount) private {
        if (recipient == address(0)) revert ZeroRecipient();
        if (token == address(0)) {
            (bool ok,) = payable(recipient).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }
}

use anchor_lang::prelude::*;

// ── PDA Seeds ──────────────────────────────────────────────────────────────

pub const CONFIG_SEED: &[u8] = b"config";
pub const ADMIN_SEED: &[u8] = b"admin";
pub const SPENDING_LIMIT_SEED: &[u8] = b"spending_limit";
pub const TX_RECORD_SEED: &[u8] = b"tx";
pub const REF_RECORD_SEED: &[u8] = b"ref";
pub const MERCHANT_PAYMENT_SEED: &[u8] = b"merchant_payment";
pub const PLATFORM_FEE_SEED: &[u8] = b"platform_fee";
pub const POINT_DEPOSIT_SEED: &[u8] = b"point_deposit";
pub const POINT_REF_SEED: &[u8] = b"point_ref";
/// Marker PDA gating every entrypoint that moves value in: create_transaction_*,
/// process_merchant_payment_* and deposit_points. Native SOL is keyed by
/// `Pubkey::default()` — the same sentinel the `_sol` instructions already use
/// for `token_mint` — so native is allowlisted explicitly rather than bypassing.
pub const ALLOWED_PAYMENT_TOKEN_SEED: &[u8] = b"allowed_payment_token";
pub const WITHDRAWAL_SEED: &[u8] = b"withdrawal";
pub const SWEEP_CAP_SEED: &[u8] = b"sweep_cap";

// ── Constants ──────────────────────────────────────────────────────────────

pub const MAX_STRING_LEN: usize = 64;
pub const MAX_WITHDRAWAL_DELAY: i64 = 7 * 24 * 60 * 60; // 7 days

/// Rolling window for the treasury sweep rate limit (24h).
///
/// Sweeps deliberately bypass the withdrawal timelock — merchant float has to
/// settle daily and a 7-day queue would break that. The cap gives back what the
/// timelock was there for: a leaked owner key can drain at most `cap` per
/// window, visibly, instead of emptying the vault in one transaction.
pub const SWEEP_WINDOW: i64 = 24 * 60 * 60;

/// Sentinel meaning "no cap". Must be set explicitly — it is not the default.
pub const SWEEP_CAP_UNLIMITED: u64 = u64::MAX;

// ── Accounts ───────────────────────────────────────────────────────────────

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub owner: Pubkey,
    pub pending_owner: Option<Pubkey>,
    pub backend_signer: Pubkey,
    pub paused: bool,
    pub point_deposits_paused: bool,
    pub tx_counter: u64,
    pub point_deposit_counter: u64,
    pub withdrawal_delay: i64,
    pub withdrawal_nonce: u64,
    /// Queued reduction of `withdrawal_delay`. Lowering the delay weakens the
    /// timelock, so it is subject to the delay currently in force — otherwise a
    /// leaked owner key would just set it to 0 and withdraw in one transaction.
    /// `pending_delay_unlock_time == 0` means nothing is queued.
    pub pending_withdrawal_delay: i64,
    pub pending_delay_unlock_time: i64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Admin {
    pub config: Pubkey,
    pub admin: Pubkey,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct SpendingLimit {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub max_amount: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct TransactionRecord {
    pub config: Pubkey,
    pub tx_id: u64,
    pub wallet_address: Pubkey,
    pub token_mint: Pubkey,
    #[max_len(MAX_STRING_LEN)]
    pub booking_id: String,
    pub exchange_rate_id: u64,
    #[max_len(MAX_STRING_LEN)]
    pub product_variant_id: String,
    #[max_len(MAX_STRING_LEN)]
    pub ref_id: String,
    pub amount: u64,
    pub timestamp: i64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct RefRecord {
    pub config: Pubkey,
    pub record_id: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct MerchantPayment {
    pub config: Pubkey,
    pub payer: Pubkey,
    pub token_mint: Pubkey,
    #[max_len(MAX_STRING_LEN)]
    pub merchant_id: String,
    #[max_len(MAX_STRING_LEN)]
    pub ref_id: String,
    pub amount: u64,
    pub platform_fee_amount: u64,
    pub fiat_amount_minor: u64,
    pub fiat_currency: [u8; 3],
    pub exchange_rate_id: u64,
    pub timestamp: i64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct PlatformFeeAccount {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub accrued_amount: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct PointDepositRecord {
    pub config: Pubkey,
    pub deposit_id: u64,
    pub wallet_address: Pubkey,
    pub token_mint: Pubkey,
    pub amount: u64,
    #[max_len(MAX_STRING_LEN)]
    pub ref_id: String,
    pub timestamp: i64,
    pub bump: u8,
}

/// Per-token treasury sweep rate limit, plus the queued increase for it.
///
/// `cap == 0` (the default, and the state of a token that was never configured)
/// blocks sweeps entirely. Unlike `SpendingLimit`, where 0 means "unbounded",
/// this is a security control, so an unconfigured value must fail closed.
#[account]
#[derive(InitSpace)]
pub struct SweepCap {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub cap: u64,
    pub swept_in_window: u64,
    pub window_start: i64,
    /// Queued increase. Raising a cap weakens a control, so it is subject to the
    /// withdrawal delay currently in force. 0 unlock_time == nothing pending.
    pub pending_cap: u64,
    pub pending_unlock_time: i64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct AllowedPaymentToken {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct WithdrawalRequest {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
    pub unlock_time: i64,
    pub executed: bool,
    pub cancelled: bool,
    pub nonce: u64,
    pub is_native: bool,
    pub bump: u8,
}

// ── Instruction Params ─────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct CreateTransactionParams {
    pub booking_id: String,
    pub exchange_rate_id: u64,
    pub product_variant_id: String,
    pub ref_id: String,
    pub ref_id_hash: [u8; 32],
    pub amount: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct MerchantQuoteParams {
    pub ref_id: String,
    pub ref_id_hash: [u8; 32],
    pub merchant_id: String,
    pub amount: u64,
    pub platform_fee_amount: u64,
    pub fiat_amount_minor: u64,
    pub fiat_currency: [u8; 3],
    pub exchange_rate_id: u64,
    pub expires_at: i64,
}

// ── Events ─────────────────────────────────────────────────────────────────

#[event]
pub struct TransactionCreated {
    pub tx_id: u64,
    pub wallet_address: Pubkey,
    pub token_mint: Pubkey,
    pub booking_id: String,
    pub exchange_rate_id: u64,
    pub product_variant_id: String,
    pub ref_id: String,
    pub amount: u64,
    pub timestamp: i64,
}

#[event]
pub struct MerchantPaymentProcessed {
    pub ref_id: String,
    pub merchant_id: String,
    pub payer: Pubkey,
    pub token_mint: Pubkey,
    pub amount: u64,
    pub platform_fee_amount: u64,
    pub fiat_amount_minor: u64,
    pub exchange_rate_id: u64,
}

#[event]
pub struct PlatformFeesSwept {
    pub token_mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
}

#[event]
pub struct MerchantBackingSwept {
    pub token_mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
}

#[event]
pub struct BackendSignerRotated {
    pub previous: Pubkey,
    pub next: Pubkey,
}

#[event]
pub struct AdminAdded {
    pub admin: Pubkey,
}

#[event]
pub struct AdminRemoved {
    pub admin: Pubkey,
}

#[event]
pub struct WithdrawEvent {
    pub recipient: Pubkey,
    pub token_mint: Pubkey,
    pub amount: u64,
}

#[event]
pub struct ContractPausedToggled {
    pub paused: bool,
}

#[event]
pub struct MaxTransactionAmountUpdated {
    pub token_mint: Pubkey,
    pub amount: u64,
}

#[event]
pub struct WithdrawalQueued {
    pub withdrawal_id: Pubkey,
    pub token_mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
    pub unlock_time: i64,
}

#[event]
pub struct WithdrawalExecuted {
    pub withdrawal_id: Pubkey,
}

#[event]
pub struct WithdrawalCancelled {
    pub withdrawal_id: Pubkey,
}

#[event]
pub struct WithdrawalDelayUpdated {
    pub delay: i64,
}

#[event]
pub struct OwnershipTransferInitiated {
    pub current_owner: Pubkey,
    pub pending_owner: Pubkey,
}

#[event]
pub struct OwnershipTransferred {
    pub previous_owner: Pubkey,
    pub new_owner: Pubkey,
}

#[event]
pub struct OwnershipTransferCancelled {
    pub cancelled_pending_owner: Pubkey,
}

#[event]
pub struct PointDepositCreated {
    pub deposit_id: u64,
    pub wallet_address: Pubkey,
    pub token_mint: Pubkey,
    pub ref_id: String,
    pub amount: u64,
    pub timestamp: i64,
}

#[event]
pub struct AllowedPaymentTokenAdded {
    pub token_mint: Pubkey,
}

#[event]
pub struct AllowedPaymentTokenRemoved {
    pub token_mint: Pubkey,
}

#[event]
pub struct SweepCapUpdated {
    pub token_mint: Pubkey,
    pub cap: u64,
}

#[event]
pub struct PendingSweepCapQueued {
    pub token_mint: Pubkey,
    pub cap: u64,
    pub unlock_time: i64,
}

#[event]
pub struct PendingSweepCapCancelled {
    pub token_mint: Pubkey,
}

#[event]
pub struct PendingDelayQueued {
    pub delay: i64,
    pub unlock_time: i64,
}

#[event]
pub struct PendingDelayCancelled {
    pub delay: i64,
}

#[event]
pub struct PointDepositsPausedToggled {
    pub paused: bool,
}

// ── Helpers ────────────────────────────────────────────────────────────────

pub fn validate_string(s: &str) -> bool {
    !s.is_empty() && s.len() <= MAX_STRING_LEN
}

pub fn verify_ref_id_hash(ref_id: &str, expected_hash: &[u8; 32]) -> bool {
    use sha2::{Sha256, Digest};
    let result = Sha256::digest(ref_id.as_bytes());
    result.as_slice() == expected_hash
}

use soroban_sdk::{contracttype, Address, BytesN, String};

/// Mirrors the Solana/EVM sibling contracts' MAX_STRING_LEN — bounds the
/// merchant/booking/ref identifiers so a caller can't grow storage unbounded.
pub const MAX_STRING_LEN: u32 = 64;

/// Mirrors MAX_WITHDRAWAL_DELAY on the Solana and EVM contracts (7 days).
pub const MAX_WITHDRAWAL_DELAY: u64 = 7 * 24 * 60 * 60;

/// Persistent-storage TTL bump applied to every record this contract writes,
/// so ledgers don't archive it out from under us. ~30 days at 5s/ledger.
pub const PERSISTENT_BUMP_TO: u32 = 535_680;
pub const PERSISTENT_BUMP_THRESHOLD: u32 = 518_400;

/// Instance-storage TTL bump for the Config singleton. Same window as above;
/// if this ever lapses the whole contract becomes unreadable.
pub const INSTANCE_BUMP_TO: u32 = 535_680;
pub const INSTANCE_BUMP_THRESHOLD: u32 = 518_400;

#[contracttype]
#[derive(Clone)]
pub enum DataKey {
    /// Singleton config, lives in instance storage.
    Config,
    /// admin address -> marker. Presence in persistent storage == is admin.
    Admin(Address),
    /// token address -> max per-transaction amount (0 / absent = unbounded).
    SpendingLimit(Address),
    /// tx_id -> TransactionRecord.
    TxRecord(u64),
    /// sha256(ref_id) -> replay marker for create_transaction.
    RefRecord(BytesN<32>),
    /// sha256(ref_id) -> MerchantPayment. Presence == quote already consumed.
    MerchantPayment(BytesN<32>),
    /// token address -> accrued platform fee (i128).
    PlatformFee(Address),
    /// deposit_id -> PointDepositRecord.
    PointDeposit(u64),
    /// sha256(ref_id) -> replay marker for deposit_points.
    PointRef(BytesN<32>),
    /// token address -> marker. Presence == allowed for payments and point
    /// deposits (create_transaction + process_merchant_payment + deposit_points).
    AllowedPaymentToken(Address),
    /// nonce -> WithdrawalRequest.
    Withdrawal(u64),
}

#[contracttype]
#[derive(Clone)]
pub struct Config {
    pub owner: Address,
    pub pending_owner: Option<Address>,
    /// Raw Ed25519 public key of the off-chain backend signer that produces
    /// merchant-quote signatures. Deliberately not a Stellar `Address` — the
    /// backend is a pure signing key, not an on-chain account (same role as
    /// `backendSigner` on EVM and `backend_signer` on Solana).
    pub backend_signer: BytesN<32>,
    pub paused: bool,
    pub point_deposits_paused: bool,
    pub tx_counter: u64,
    pub point_deposit_counter: u64,
    pub withdrawal_delay: u64,
    pub withdrawal_nonce: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct CreateTransactionParams {
    pub booking_id: String,
    pub exchange_rate_id: u64,
    pub product_variant_id: String,
    pub ref_id: String,
    pub token: Address,
    pub amount: i128,
}

#[contracttype]
#[derive(Clone)]
pub struct TransactionRecord {
    pub tx_id: u64,
    pub wallet_address: Address,
    pub token: Address,
    pub booking_id: String,
    pub exchange_rate_id: u64,
    pub product_variant_id: String,
    pub ref_id: String,
    pub amount: i128,
    pub timestamp: u64,
}

/// The backend-signed quote a payer submits to `process_merchant_payment`.
/// Signed as part of `QuoteMessage` (see merchant.rs) so the signature binds
/// to this network and this contract instance — the Soroban analogue of an
/// EIP-712 domain separator.
#[contracttype]
#[derive(Clone)]
pub struct MerchantQuote {
    pub ref_id: String,
    pub merchant_id: String,
    pub token: Address,
    pub amount: i128,
    pub platform_fee_amount: i128,
    pub fiat_amount_minor: u64,
    pub fiat_currency: BytesN<3>,
    pub exchange_rate_id: u64,
    pub expires_at: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct MerchantPayment {
    pub payer: Address,
    pub token: Address,
    pub merchant_id: String,
    pub ref_id: String,
    pub amount: i128,
    pub platform_fee_amount: i128,
    pub fiat_amount_minor: u64,
    pub fiat_currency: BytesN<3>,
    pub exchange_rate_id: u64,
    pub timestamp: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct PointDepositRecord {
    pub deposit_id: u64,
    pub wallet_address: Address,
    pub token: Address,
    pub amount: i128,
    pub ref_id: String,
    pub timestamp: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct WithdrawalRequest {
    pub token: Address,
    pub recipient: Address,
    pub amount: i128,
    pub unlock_time: u64,
    pub executed: bool,
    pub cancelled: bool,
    pub nonce: u64,
}

pub fn validate_string_len(s: &String) -> bool {
    let len = s.len();
    len > 0 && len <= MAX_STRING_LEN
}

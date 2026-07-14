use soroban_sdk::{contractevent, Address, BytesN, String};

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminAdded {
    #[topic]
    pub admin: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminRemoved {
    #[topic]
    pub admin: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnershipTransferInitiated {
    #[topic]
    pub previous_owner: Address,
    pub pending_owner: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnershipTransferred {
    #[topic]
    pub previous_owner: Address,
    pub new_owner: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnershipTransferCancelled {
    #[topic]
    pub cancelled_pending_owner: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PausedToggled {
    pub paused: bool,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PointDepositsPausedToggled {
    pub paused: bool,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpendingLimitUpdated {
    #[topic]
    pub token: Address,
    pub max_amount: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BackendSignerRotated {
    pub previous: BytesN<32>,
    pub next: BytesN<32>,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AllowedPaymentTokenAdded {
    #[topic]
    pub token: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AllowedPaymentTokenRemoved {
    #[topic]
    pub token: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransactionCreated {
    #[topic]
    pub payer: Address,
    #[topic]
    pub token: Address,
    pub tx_id: u64,
    pub ref_id: String,
    pub amount: i128,
    pub timestamp: u64,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MerchantPaymentProcessed {
    #[topic]
    pub payer: Address,
    #[topic]
    pub token: Address,
    pub ref_id: String,
    pub merchant_id: String,
    pub amount: i128,
    pub platform_fee_amount: i128,
    pub fiat_amount_minor: u64,
    pub exchange_rate_id: u64,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PointDepositCreated {
    #[topic]
    pub payer: Address,
    #[topic]
    pub token: Address,
    pub deposit_id: u64,
    pub ref_id: String,
    pub amount: i128,
    pub timestamp: u64,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlatformFeesSwept {
    #[topic]
    pub token: Address,
    #[topic]
    pub recipient: Address,
    pub amount: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MerchantBackingSwept {
    #[topic]
    pub token: Address,
    #[topic]
    pub recipient: Address,
    pub amount: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawEvent {
    #[topic]
    pub token: Address,
    #[topic]
    pub recipient: Address,
    pub amount: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawalQueued {
    #[topic]
    pub token: Address,
    #[topic]
    pub recipient: Address,
    pub nonce: u64,
    pub amount: i128,
    pub unlock_time: u64,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawalExecuted {
    #[topic]
    pub nonce: u64,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawalCancelled {
    #[topic]
    pub nonce: u64,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawalDelayUpdated {
    pub delay: u64,
}

use soroban_sdk::{token, Address, Env};

use crate::admin::{bump_persistent, get_config, require_owner};
use crate::errors::Error;
use crate::events::{MerchantBackingSwept, PlatformFeesSwept};
use crate::types::DataKey;

/// Sweeps accrued platform fees (bounded by what merchant payments have
/// actually accrued for this token) to `recipient`.
pub fn sweep_platform_fees(
    env: &Env,
    owner: Address,
    token: Address,
    recipient: Address,
    amount: i128,
) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if amount <= 0 {
        return Err(Error::ZeroAmount);
    }

    let fee_key = DataKey::PlatformFee(token.clone());
    let accrued: i128 = env.storage().persistent().get(&fee_key).unwrap_or(0);
    if amount > accrued {
        return Err(Error::FeeAmountInvalid);
    }
    let remaining = accrued - amount;
    env.storage().persistent().set(&fee_key, &remaining);
    bump_persistent(env, &fee_key);

    token::TokenClient::new(env, &token).transfer(
        &env.current_contract_address(),
        &recipient,
        &amount,
    );

    PlatformFeesSwept {
        token,
        recipient,
        amount,
    }
    .publish(env);
    Ok(())
}

/// Sweeps merchant-backing funds (unbounded by fee accrual — this is the
/// float backing merchant payouts) to `recipient`.
pub fn sweep_merchant_backing(
    env: &Env,
    owner: Address,
    token: Address,
    recipient: Address,
    amount: i128,
) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if amount <= 0 {
        return Err(Error::ZeroAmount);
    }

    let balance = token::TokenClient::new(env, &token).balance(&env.current_contract_address());
    if amount > balance {
        return Err(Error::InsufficientBalance);
    }

    token::TokenClient::new(env, &token).transfer(
        &env.current_contract_address(),
        &recipient,
        &amount,
    );

    MerchantBackingSwept {
        token,
        recipient,
        amount,
    }
    .publish(env);
    Ok(())
}

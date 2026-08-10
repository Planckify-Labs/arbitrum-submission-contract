use soroban_sdk::{token, Address, Env};

use crate::admin::{bump_persistent, get_config, require_owner};
use crate::errors::Error;
use crate::events::{
    MerchantBackingSwept, PendingSweepCapCancelled, PendingSweepCapQueued, PlatformFeesSwept,
    SweepCapUpdated,
};
use crate::types::{DataKey, PendingCap, SWEEP_CAP_UNLIMITED, SWEEP_WINDOW};

// ── Sweep rate limit ──────────────────────────────────────────────────────

/// Charges `amount` against the token's rolling per-window sweep allowance.
/// An unset cap fails closed: unlike `SpendingLimit`, where absent means
/// "unbounded", this is a security control, so it must deny by default.
fn consume_sweep_allowance(env: &Env, token: &Address, amount: i128) -> Result<(), Error> {
    let cap: i128 = env
        .storage()
        .persistent()
        .get(&DataKey::SweepCap(token.clone()))
        .unwrap_or(0);
    if cap == 0 {
        return Err(Error::SweepCapNotSet);
    }
    if cap == SWEEP_CAP_UNLIMITED {
        return Ok(());
    }

    let now = env.ledger().timestamp();
    let window_start: u64 = env
        .storage()
        .persistent()
        .get(&DataKey::SweepWindowStart(token.clone()))
        .unwrap_or(0);

    let mut swept: i128 = if now.saturating_sub(window_start) >= SWEEP_WINDOW {
        let key = DataKey::SweepWindowStart(token.clone());
        env.storage().persistent().set(&key, &now);
        bump_persistent(env, &key);
        0
    } else {
        env.storage()
            .persistent()
            .get(&DataKey::SweptInWindow(token.clone()))
            .unwrap_or(0)
    };

    swept = swept.checked_add(amount).ok_or(Error::SweepCapExceeded)?;
    if swept > cap {
        return Err(Error::SweepCapExceeded);
    }

    let key = DataKey::SweptInWindow(token.clone());
    env.storage().persistent().set(&key, &swept);
    bump_persistent(env, &key);
    Ok(())
}

/// Lowers (tightens) a token's sweep cap. Immediate — tightening is always safe.
/// Raising must go through `queue_sweep_cap`, otherwise the rate limit would be
/// one call away from being defeated.
pub fn set_sweep_cap(env: &Env, owner: Address, token: Address, cap: i128) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if cap < 0 {
        return Err(Error::ZeroAmount);
    }
    let current: i128 = env
        .storage()
        .persistent()
        .get(&DataKey::SweepCap(token.clone()))
        .unwrap_or(0);
    if cap > current {
        return Err(Error::NotALoosening);
    }

    let key = DataKey::SweepCap(token.clone());
    env.storage().persistent().set(&key, &cap);
    bump_persistent(env, &key);

    SweepCapUpdated { token, cap }.publish(env);
    Ok(())
}

pub fn queue_sweep_cap(env: &Env, owner: Address, token: Address, cap: i128) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let current: i128 = env
        .storage()
        .persistent()
        .get(&DataKey::SweepCap(token.clone()))
        .unwrap_or(0);
    if cap <= current {
        return Err(Error::NotALoosening);
    }

    let unlock_time = env.ledger().timestamp() + config.withdrawal_delay;
    let key = DataKey::PendingSweepCap(token.clone());
    env.storage().persistent().set(
        &key,
        &PendingCap {
            value: cap,
            unlock_time,
        },
    );
    bump_persistent(env, &key);

    PendingSweepCapQueued {
        token,
        cap,
        unlock_time,
    }
    .publish(env);
    Ok(())
}

pub fn apply_sweep_cap(env: &Env, owner: Address, token: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::PendingSweepCap(token.clone());
    let pending: PendingCap = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingChange)?;
    if env.ledger().timestamp() < pending.unlock_time {
        return Err(Error::TimelockNotExpired);
    }
    env.storage().persistent().remove(&key);

    let cap_key = DataKey::SweepCap(token.clone());
    env.storage().persistent().set(&cap_key, &pending.value);
    bump_persistent(env, &cap_key);

    SweepCapUpdated {
        token,
        cap: pending.value,
    }
    .publish(env);
    Ok(())
}

pub fn cancel_sweep_cap(env: &Env, owner: Address, token: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::PendingSweepCap(token.clone());
    if !env.storage().persistent().has(&key) {
        return Err(Error::NoPendingChange);
    }
    env.storage().persistent().remove(&key);

    PendingSweepCapCancelled { token }.publish(env);
    Ok(())
}

pub fn get_sweep_cap(env: &Env, token: Address) -> i128 {
    env.storage()
        .persistent()
        .get(&DataKey::SweepCap(token))
        .unwrap_or(0)
}

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
    consume_sweep_allowance(env, &token, amount)?;
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
    consume_sweep_allowance(env, &token, amount)?;

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

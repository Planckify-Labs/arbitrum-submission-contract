use soroban_sdk::{token, Address, Env};

use crate::admin::{bump_persistent, get_config, require_owner, save_config};
use crate::errors::Error;
use crate::events::{
    PendingDelayCancelled, PendingDelayQueued, WithdrawalCancelled,
    WithdrawalDelayUpdated, WithdrawalExecuted, WithdrawalQueued, WithdrawEvent,
};
use crate::types::{DataKey, PendingDelay, WithdrawalRequest, MAX_WITHDRAWAL_DELAY};

/// Immediate withdrawal — only usable while no timelock delay is configured.
/// Once `set_withdrawal_delay` is set above 0, callers must use
/// queue/execute so every withdrawal has a mandatory cooling-off period.
pub fn withdraw(
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
    if config.withdrawal_delay != 0 {
        return Err(Error::TimelockActive);
    }

    token::TokenClient::new(env, &token).transfer(
        &env.current_contract_address(),
        &recipient,
        &amount,
    );

    WithdrawEvent {
        token,
        recipient,
        amount,
    }
    .publish(env);
    Ok(())
}

/// Raises the withdrawal delay. Immediate — tightening a control is always safe.
///
/// Lowering must go through `queue_withdrawal_delay` / `apply_withdrawal_delay`
/// so the reduction is itself subject to the delay currently in force. Without
/// that the timelock is decorative: an owner key that leaks would simply set the
/// delay to 0 and withdraw in the same transaction.
pub fn set_withdrawal_delay(env: &Env, owner: Address, delay: u64) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    if delay > MAX_WITHDRAWAL_DELAY {
        return Err(Error::DelayExceedsMax);
    }
    if delay < config.withdrawal_delay {
        return Err(Error::NotALoosening);
    }
    config.withdrawal_delay = delay;
    save_config(env, &config);

    WithdrawalDelayUpdated { delay }.publish(env);
    Ok(())
}

pub fn queue_withdrawal_delay(env: &Env, owner: Address, delay: u64) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if delay >= config.withdrawal_delay {
        return Err(Error::NotALoosening);
    }

    let unlock_time = env.ledger().timestamp() + config.withdrawal_delay;
    let key = DataKey::PendingWithdrawalDelay;
    env.storage().persistent().set(
        &key,
        &PendingDelay {
            value: delay,
            unlock_time,
        },
    );
    bump_persistent(env, &key);

    PendingDelayQueued { delay, unlock_time }.publish(env);
    Ok(())
}

pub fn apply_withdrawal_delay(env: &Env, owner: Address) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::PendingWithdrawalDelay;
    let pending: PendingDelay = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingChange)?;
    if env.ledger().timestamp() < pending.unlock_time {
        return Err(Error::TimelockNotExpired);
    }
    env.storage().persistent().remove(&key);

    config.withdrawal_delay = pending.value;
    save_config(env, &config);

    WithdrawalDelayUpdated {
        delay: pending.value,
    }
    .publish(env);
    Ok(())
}

pub fn cancel_withdrawal_delay(env: &Env, owner: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::PendingWithdrawalDelay;
    let pending: PendingDelay = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingChange)?;
    env.storage().persistent().remove(&key);

    PendingDelayCancelled {
        delay: pending.value,
    }
    .publish(env);
    Ok(())
}

pub fn queue_withdrawal(
    env: &Env,
    owner: Address,
    token: Address,
    recipient: Address,
    amount: i128,
) -> Result<u64, Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    if amount <= 0 {
        return Err(Error::ZeroAmount);
    }
    if config.withdrawal_delay == 0 {
        return Err(Error::NoDelaySet);
    }

    config.withdrawal_nonce += 1;
    let nonce = config.withdrawal_nonce;
    let unlock_time = env.ledger().timestamp() + config.withdrawal_delay;

    let request = WithdrawalRequest {
        token: token.clone(),
        recipient: recipient.clone(),
        amount,
        unlock_time,
        executed: false,
        cancelled: false,
        nonce,
    };
    let key = DataKey::Withdrawal(nonce);
    env.storage().persistent().set(&key, &request);
    bump_persistent(env, &key);

    save_config(env, &config);

    WithdrawalQueued {
        token,
        recipient,
        nonce,
        amount,
        unlock_time,
    }
    .publish(env);
    Ok(nonce)
}

pub fn execute_withdrawal(env: &Env, owner: Address, nonce: u64) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::Withdrawal(nonce);
    let mut request: WithdrawalRequest = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingTransfer)?;

    if request.executed {
        return Err(Error::AlreadyExecuted);
    }
    if request.cancelled {
        return Err(Error::AlreadyCancelled);
    }
    if env.ledger().timestamp() < request.unlock_time {
        return Err(Error::TimelockNotExpired);
    }

    request.executed = true;
    env.storage().persistent().set(&key, &request);
    bump_persistent(env, &key);

    token::TokenClient::new(env, &request.token).transfer(
        &env.current_contract_address(),
        &request.recipient,
        &request.amount,
    );

    WithdrawalExecuted { nonce }.publish(env);
    Ok(())
}

pub fn cancel_withdrawal(env: &Env, owner: Address, nonce: u64) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::Withdrawal(nonce);
    let mut request: WithdrawalRequest = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingTransfer)?;

    if request.executed {
        return Err(Error::AlreadyExecuted);
    }
    if request.cancelled {
        return Err(Error::AlreadyCancelled);
    }

    request.cancelled = true;
    env.storage().persistent().set(&key, &request);
    bump_persistent(env, &key);

    WithdrawalCancelled { nonce }.publish(env);
    Ok(())
}

pub fn get_withdrawal(env: &Env, nonce: u64) -> Option<WithdrawalRequest> {
    env.storage().persistent().get(&DataKey::Withdrawal(nonce))
}

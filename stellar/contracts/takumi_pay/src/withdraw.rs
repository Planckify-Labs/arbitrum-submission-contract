use soroban_sdk::{token, Address, Env};

use crate::admin::{bump_persistent, get_config, require_owner, save_config};
use crate::errors::Error;
use crate::events::{
    WithdrawalCancelled, WithdrawalDelayUpdated, WithdrawalExecuted, WithdrawalQueued,
    WithdrawEvent,
};
use crate::types::{DataKey, WithdrawalRequest, MAX_WITHDRAWAL_DELAY};

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

pub fn set_withdrawal_delay(env: &Env, owner: Address, delay: u64) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    if delay > MAX_WITHDRAWAL_DELAY {
        return Err(Error::DelayExceedsMax);
    }
    config.withdrawal_delay = delay;
    save_config(env, &config);

    WithdrawalDelayUpdated { delay }.publish(env);
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

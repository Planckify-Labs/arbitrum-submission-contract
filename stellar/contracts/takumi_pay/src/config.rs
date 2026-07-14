use soroban_sdk::{Address, BytesN, Env};

use crate::admin::{
    bump_persistent, get_config, require_admin_or_owner, require_owner, save_config,
};
use crate::errors::Error;
use crate::events::{
    AllowedPaymentTokenAdded, AllowedPaymentTokenRemoved, BackendSignerRotated, PausedToggled,
    PointDepositsPausedToggled, SpendingLimitUpdated,
};
use crate::types::DataKey;

pub fn set_paused(env: &Env, caller: Address, paused: bool) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_admin_or_owner(env, &config, &caller)?;

    config.paused = paused;
    save_config(env, &config);

    PausedToggled { paused }.publish(env);
    Ok(())
}

pub fn set_point_deposits_paused(env: &Env, caller: Address, paused: bool) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_admin_or_owner(env, &config, &caller)?;

    config.point_deposits_paused = paused;
    save_config(env, &config);

    PointDepositsPausedToggled { paused }.publish(env);
    Ok(())
}

pub fn set_spending_limit(
    env: &Env,
    owner: Address,
    token: Address,
    max_amount: i128,
) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::SpendingLimit(token.clone());
    env.storage().persistent().set(&key, &max_amount);
    bump_persistent(env, &key);

    SpendingLimitUpdated { token, max_amount }.publish(env);
    Ok(())
}

pub fn rotate_backend_signer(
    env: &Env,
    owner: Address,
    new_signer: BytesN<32>,
) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    let previous = config.backend_signer.clone();
    config.backend_signer = new_signer.clone();
    save_config(env, &config);

    BackendSignerRotated {
        previous,
        next: new_signer,
    }
    .publish(env);
    Ok(())
}

pub fn add_allowed_payment_token(env: &Env, owner: Address, token: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::AllowedPaymentToken(token.clone());
    if env.storage().persistent().has(&key) {
        return Err(Error::AllowedTokenAlreadyExists);
    }
    env.storage().persistent().set(&key, &true);
    bump_persistent(env, &key);

    AllowedPaymentTokenAdded { token }.publish(env);
    Ok(())
}

pub fn remove_allowed_payment_token(
    env: &Env,
    owner: Address,
    token: Address,
) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::AllowedPaymentToken(token.clone());
    if !env.storage().persistent().has(&key) {
        return Err(Error::AllowedTokenNotFound);
    }
    env.storage().persistent().remove(&key);

    AllowedPaymentTokenRemoved { token }.publish(env);
    Ok(())
}

/// Reads the per-token cap set by `set_spending_limit`. 0 or unset means
/// unbounded, matching the Solana/EVM sibling contracts.
pub fn check_spending_limit(env: &Env, token: &Address, amount: i128) -> Result<(), Error> {
    let limit: Option<i128> = env
        .storage()
        .persistent()
        .get(&DataKey::SpendingLimit(token.clone()));
    if let Some(max_amount) = limit {
        if max_amount > 0 && amount > max_amount {
            return Err(Error::AmountExceedsLimit);
        }
    }
    Ok(())
}

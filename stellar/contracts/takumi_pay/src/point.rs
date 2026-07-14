use soroban_sdk::{token, Address, Env, String};

use crate::admin::{bump_persistent, get_config, save_config};
use crate::errors::Error;
use crate::events::PointDepositCreated;
use crate::types::{validate_string_len, DataKey, PointDepositRecord};
use crate::util::hash_string;

pub fn deposit_points(
    env: &Env,
    payer: Address,
    token: Address,
    ref_id: String,
    amount: i128,
) -> Result<u64, Error> {
    payer.require_auth();

    let mut config = get_config(env)?;
    if config.paused {
        return Err(Error::ContractPaused);
    }
    if config.point_deposits_paused {
        return Err(Error::PointDepositsPaused);
    }
    if amount <= 0 {
        return Err(Error::ZeroAmount);
    }
    if !validate_string_len(&ref_id) {
        return Err(Error::InvalidStringLength);
    }
    if !env
        .storage()
        .persistent()
        .has(&DataKey::AllowedPaymentToken(token.clone()))
    {
        return Err(Error::TokenNotAllowed);
    }

    let ref_hash = hash_string(env, &ref_id);
    let ref_key = DataKey::PointRef(ref_hash);
    if env.storage().persistent().has(&ref_key) {
        return Err(Error::RefConsumed);
    }

    token::TokenClient::new(env, &token).transfer(
        &payer,
        env.current_contract_address(),
        &amount,
    );

    config.point_deposit_counter += 1;
    let deposit_id = config.point_deposit_counter;
    let timestamp = env.ledger().timestamp();

    let record = PointDepositRecord {
        deposit_id,
        wallet_address: payer.clone(),
        token: token.clone(),
        amount,
        ref_id: ref_id.clone(),
        timestamp,
    };
    let deposit_key = DataKey::PointDeposit(deposit_id);
    env.storage().persistent().set(&deposit_key, &record);
    bump_persistent(env, &deposit_key);

    env.storage().persistent().set(&ref_key, &true);
    bump_persistent(env, &ref_key);

    save_config(env, &config);

    PointDepositCreated {
        payer,
        token,
        deposit_id,
        ref_id,
        amount,
        timestamp,
    }
    .publish(env);

    Ok(deposit_id)
}

pub fn get_point_deposit(env: &Env, deposit_id: u64) -> Option<PointDepositRecord> {
    env.storage()
        .persistent()
        .get(&DataKey::PointDeposit(deposit_id))
}

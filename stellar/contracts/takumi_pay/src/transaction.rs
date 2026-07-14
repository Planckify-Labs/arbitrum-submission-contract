use soroban_sdk::{token, Address, Env};

use crate::admin::{bump_persistent, get_config, save_config};
use crate::config::check_spending_limit;
use crate::errors::Error;
use crate::events::TransactionCreated;
use crate::types::{validate_string_len, CreateTransactionParams, DataKey, TransactionRecord};
use crate::util::hash_string;

pub fn create_transaction(
    env: &Env,
    payer: Address,
    params: CreateTransactionParams,
) -> Result<u64, Error> {
    payer.require_auth();

    let mut config = get_config(env)?;
    if config.paused {
        return Err(Error::ContractPaused);
    }
    if params.amount <= 0 {
        return Err(Error::ZeroAmount);
    }
    if !validate_string_len(&params.booking_id)
        || !validate_string_len(&params.product_variant_id)
        || !validate_string_len(&params.ref_id)
    {
        return Err(Error::InvalidStringLength);
    }
    if !env
        .storage()
        .persistent()
        .has(&DataKey::AllowedPaymentToken(params.token.clone()))
    {
        return Err(Error::TokenNotAllowed);
    }
    check_spending_limit(env, &params.token, params.amount)?;

    let ref_hash = hash_string(env, &params.ref_id);
    let ref_key = DataKey::RefRecord(ref_hash);
    if env.storage().persistent().has(&ref_key) {
        return Err(Error::RefConsumed);
    }

    token::TokenClient::new(env, &params.token).transfer(
        &payer,
        env.current_contract_address(),
        &params.amount,
    );

    config.tx_counter += 1;
    let tx_id = config.tx_counter;
    let timestamp = env.ledger().timestamp();

    let record = TransactionRecord {
        tx_id,
        wallet_address: payer.clone(),
        token: params.token.clone(),
        booking_id: params.booking_id.clone(),
        exchange_rate_id: params.exchange_rate_id,
        product_variant_id: params.product_variant_id.clone(),
        ref_id: params.ref_id.clone(),
        amount: params.amount,
        timestamp,
    };
    let tx_key = DataKey::TxRecord(tx_id);
    env.storage().persistent().set(&tx_key, &record);
    bump_persistent(env, &tx_key);

    env.storage().persistent().set(&ref_key, &true);
    bump_persistent(env, &ref_key);

    save_config(env, &config);

    TransactionCreated {
        payer,
        token: params.token,
        tx_id,
        ref_id: params.ref_id,
        amount: params.amount,
        timestamp,
    }
    .publish(env);

    Ok(tx_id)
}

pub fn get_transaction(env: &Env, tx_id: u64) -> Option<TransactionRecord> {
    env.storage().persistent().get(&DataKey::TxRecord(tx_id))
}

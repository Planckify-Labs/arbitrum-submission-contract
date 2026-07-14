use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{contracttype, token, Address, Bytes, BytesN, Env};

use crate::admin::{bump_persistent, get_config};
use crate::errors::Error;
use crate::events::MerchantPaymentProcessed;
use crate::types::{validate_string_len, DataKey, MerchantPayment, MerchantQuote};
use crate::util::hash_string;

/// Wraps the payer-visible quote with network + contract identity so a
/// signature over one quote can't be replayed against a different network or
/// a different deployment of this contract. This is the Soroban analogue of
/// an EIP-712 domain separator (EVM) / the extra `token_mint` byte prefix the
/// Solana contract mixes into its manually-built message.
#[contracttype]
#[derive(Clone)]
pub(crate) struct QuoteMessage {
    pub(crate) network_id: BytesN<32>,
    pub(crate) contract: Address,
    pub(crate) quote: MerchantQuote,
}

pub fn process_merchant_payment(
    env: &Env,
    payer: Address,
    quote: MerchantQuote,
    backend_signature: BytesN<64>,
) -> Result<(), Error> {
    payer.require_auth();

    let config = get_config(env)?;
    if config.paused {
        return Err(Error::ContractPaused);
    }
    if quote.amount <= 0 {
        return Err(Error::ZeroAmount);
    }
    if quote.platform_fee_amount > quote.amount {
        return Err(Error::FeeExceedsAmount);
    }
    if !validate_string_len(&quote.ref_id) || !validate_string_len(&quote.merchant_id) {
        return Err(Error::InvalidStringLength);
    }
    if env.ledger().timestamp() > quote.expires_at {
        return Err(Error::QuoteExpired);
    }
    if !env
        .storage()
        .persistent()
        .has(&DataKey::AllowedPaymentToken(quote.token.clone()))
    {
        return Err(Error::TokenNotAllowed);
    }

    let ref_hash = hash_string(env, &quote.ref_id);
    let payment_key = DataKey::MerchantPayment(ref_hash);
    if env.storage().persistent().has(&payment_key) {
        return Err(Error::RefConsumed);
    }

    let message = QuoteMessage {
        network_id: env.ledger().network_id(),
        contract: env.current_contract_address(),
        quote: quote.clone(),
    };
    let message_bytes: Bytes = message.to_xdr(env);
    // Traps (aborts the whole invocation) if the signature doesn't match —
    // there is no recoverable Err path for a bad signature by design.
    env.crypto()
        .ed25519_verify(&config.backend_signer, &message_bytes, &backend_signature);

    token::TokenClient::new(env, &quote.token).transfer(
        &payer,
        env.current_contract_address(),
        &quote.amount,
    );

    let timestamp = env.ledger().timestamp();
    let payment = MerchantPayment {
        payer: payer.clone(),
        token: quote.token.clone(),
        merchant_id: quote.merchant_id.clone(),
        ref_id: quote.ref_id.clone(),
        amount: quote.amount,
        platform_fee_amount: quote.platform_fee_amount,
        fiat_amount_minor: quote.fiat_amount_minor,
        fiat_currency: quote.fiat_currency.clone(),
        exchange_rate_id: quote.exchange_rate_id,
        timestamp,
    };
    env.storage().persistent().set(&payment_key, &payment);
    bump_persistent(env, &payment_key);

    let fee_key = DataKey::PlatformFee(quote.token.clone());
    let accrued: i128 = env.storage().persistent().get(&fee_key).unwrap_or(0);
    let accrued = accrued
        .checked_add(quote.platform_fee_amount)
        .ok_or(Error::FeeAmountInvalid)?;
    env.storage().persistent().set(&fee_key, &accrued);
    bump_persistent(env, &fee_key);

    MerchantPaymentProcessed {
        payer,
        token: quote.token,
        ref_id: quote.ref_id,
        merchant_id: quote.merchant_id,
        amount: quote.amount,
        platform_fee_amount: quote.platform_fee_amount,
        fiat_amount_minor: quote.fiat_amount_minor,
        exchange_rate_id: quote.exchange_rate_id,
    }
    .publish(env);

    Ok(())
}

pub fn get_merchant_payment(env: &Env, ref_id: &soroban_sdk::String) -> Option<MerchantPayment> {
    let ref_hash = hash_string(env, ref_id);
    env.storage()
        .persistent()
        .get(&DataKey::MerchantPayment(ref_hash))
}

extern crate std;

use ed25519_dalek::{Signer, SigningKey};
use soroban_sdk::testutils::{Address as _, Ledger};
use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{token, Address, BytesN, Env, String};

use crate::merchant::QuoteMessage;
use crate::types::MerchantQuote;
use crate::{Error, TakumiPay, TakumiPayClient};

fn signing_key(env: &Env) -> (SigningKey, BytesN<32>) {
    let mut csprng = rand::rngs::OsRng;
    let key = SigningKey::generate(&mut csprng);
    let pubkey = BytesN::from_array(env, &key.verifying_key().to_bytes());
    (key, pubkey)
}

fn sign_quote(
    env: &Env,
    contract_id: &Address,
    key: &SigningKey,
    quote: &MerchantQuote,
) -> BytesN<64> {
    let message = QuoteMessage {
        network_id: env.ledger().network_id(),
        contract: contract_id.clone(),
        quote: quote.clone(),
    };
    let bytes = message.to_xdr(env);
    let buffer = bytes.to_buffer::<1024>();
    let sig = key.sign(buffer.as_slice());
    BytesN::from_array(env, &sig.to_bytes())
}

fn setup(env: &Env) -> (TakumiPayClient<'_>, Address, Address, SigningKey) {
    env.mock_all_auths();
    let owner = Address::generate(env);
    let (backend_key, backend_pubkey) = signing_key(env);

    let contract_id = env.register(TakumiPay, ());
    let client = TakumiPayClient::new(env, &contract_id);
    client.initialize(&owner, &backend_pubkey);

    (client, owner, contract_id, backend_key)
}

fn setup_token(env: &Env, admin: &Address) -> Address {
    env.register_stellar_asset_contract_v2(admin.clone()).address()
}

fn mint(env: &Env, token: &Address, to: &Address, amount: i128) {
    token::StellarAssetClient::new(env, token).mint(to, &amount);
}

fn default_quote(env: &Env, token: &Address, ref_id: &str, expires_at: u64) -> MerchantQuote {
    MerchantQuote {
        ref_id: String::from_str(env, ref_id),
        merchant_id: String::from_str(env, "merchant-1"),
        token: token.clone(),
        amount: 1_000_000,
        platform_fee_amount: 10_000,
        fiat_amount_minor: 150_000,
        fiat_currency: BytesN::from_array(env, b"USD"),
        exchange_rate_id: 42,
        expires_at,
    }
}

#[test]
fn test_initialize_and_config() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let config = client.get_config();
    assert_eq!(config.owner, owner);
    assert!(!config.paused);
    assert!(!config.point_deposits_paused);
    assert_eq!(config.tx_counter, 0);
}

#[test]
fn test_admin_management_and_pause() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let admin = Address::generate(&env);
    client.add_admin(&owner, &admin);
    assert!(client.is_admin(&admin));

    // Admin (not owner) can pause.
    client.set_paused(&admin, &true);
    assert!(client.get_config().paused);

    client.set_paused(&owner, &false);
    assert!(!client.get_config().paused);

    client.remove_admin(&owner, &admin);
    assert!(!client.is_admin(&admin));
}

#[test]
fn test_ownership_transfer_flow() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let new_owner = Address::generate(&env);
    client.transfer_ownership(&owner, &new_owner);
    assert_eq!(client.get_config().pending_owner, Some(new_owner.clone()));

    client.accept_ownership(&new_owner);
    let config = client.get_config();
    assert_eq!(config.owner, new_owner);
    assert_eq!(config.pending_owner, None);

    // Old owner no longer has authority.
    let result = client.try_set_paused(&owner, &true);
    assert_eq!(result, Err(Ok(Error::NotAdminOrOwner)));
}

#[test]
fn test_create_transaction_and_spending_limit() {
    let env = Env::default();
    let (client, owner, contract_id, _backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    client.set_spending_limit(&owner, &token, &500_000);

    let params = crate::types::CreateTransactionParams {
        booking_id: String::from_str(&env, "booking-1"),
        exchange_rate_id: 1,
        product_variant_id: String::from_str(&env, "variant-1"),
        ref_id: String::from_str(&env, "ref-1"),
        token: token.clone(),
        amount: 1_000_000,
    };

    let result = client.try_create_transaction(&payer, &params);
    assert_eq!(result, Err(Ok(Error::AmountExceedsLimit)));

    let mut ok_params = params.clone();
    ok_params.amount = 400_000;
    let tx_id = client.create_transaction(&payer, &ok_params);
    assert_eq!(tx_id, 1);

    let record = client.get_transaction(&tx_id).unwrap();
    assert_eq!(record.wallet_address, payer);
    assert_eq!(record.amount, 400_000);

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&contract_id), 400_000);
    assert_eq!(token_client.balance(&payer), 10_000_000 - 400_000);

    // Replaying the same ref_id is rejected.
    let replay = client.try_create_transaction(&payer, &ok_params);
    assert_eq!(replay, Err(Ok(Error::RefConsumed)));
}

#[test]
fn test_process_merchant_payment_happy_path() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let quote = default_quote(&env, &token, "quote-1", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);

    client.process_merchant_payment(&payer, &quote, &signature);

    let payment = client.get_merchant_payment(&quote.ref_id).unwrap();
    assert_eq!(payment.payer, payer);
    assert_eq!(payment.amount, 1_000_000);
    assert_eq!(payment.platform_fee_amount, 10_000);

    assert_eq!(client.get_platform_fee_accrued(&token), 10_000);

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&contract_id), 1_000_000);

    // Same ref_id cannot be replayed even with a fresh valid signature.
    let replay_sig = sign_quote(&env, &contract_id, &backend_key, &quote);
    let replay = client.try_process_merchant_payment(&payer, &quote, &replay_sig);
    assert_eq!(replay, Err(Ok(Error::RefConsumed)));
}

#[test]
fn test_process_merchant_payment_expired_quote() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);

    env.ledger().set_timestamp(1_000_000);
    let quote = default_quote(&env, &token, "quote-expired", 999_999);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);

    let result = client.try_process_merchant_payment(&payer, &quote, &signature);
    assert_eq!(result, Err(Ok(Error::QuoteExpired)));
}

#[test]
#[should_panic]
fn test_process_merchant_payment_bad_signature_panics() {
    let env = Env::default();
    let (client, owner, contract_id, _backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let (wrong_key, _) = signing_key(&env);
    let quote = default_quote(&env, &token, "quote-bad-sig", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &wrong_key, &quote);

    client.process_merchant_payment(&payer, &quote, &signature);
}

#[test]
fn test_deposit_points_requires_allowed_token() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 1_000_000);

    let ref_id = String::from_str(&env, "point-ref-1");
    let not_allowed = client.try_deposit_points(&payer, &token, &ref_id, &1000);
    assert_eq!(not_allowed, Err(Ok(Error::TokenNotAllowed)));

    client.add_allowed_payment_token(&owner, &token);
    let deposit_id = client.deposit_points(&payer, &token, &ref_id, &1000);
    assert_eq!(deposit_id, 1);

    let record = client.get_point_deposit(&deposit_id).unwrap();
    assert_eq!(record.amount, 1000);
    assert_eq!(record.wallet_address, payer);
}

#[test]
fn test_create_transaction_requires_allowed_token() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);

    let params = crate::types::CreateTransactionParams {
        booking_id: String::from_str(&env, "booking-1"),
        exchange_rate_id: 1,
        product_variant_id: String::from_str(&env, "variant-1"),
        ref_id: String::from_str(&env, "ref-1"),
        token: token.clone(),
        amount: 400_000,
    };

    let not_allowed = client.try_create_transaction(&payer, &params);
    assert_eq!(not_allowed, Err(Ok(Error::TokenNotAllowed)));

    client.add_allowed_payment_token(&owner, &token);
    let tx_id = client.create_transaction(&payer, &params);
    assert_eq!(tx_id, 1);
}

#[test]
fn test_process_merchant_payment_requires_allowed_token() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);

    let quote = default_quote(&env, &token, "quote-not-allowed", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);

    let not_allowed = client.try_process_merchant_payment(&payer, &quote, &signature);
    assert_eq!(not_allowed, Err(Ok(Error::TokenNotAllowed)));

    client.add_allowed_payment_token(&owner, &token);
    client.process_merchant_payment(&payer, &quote, &signature);
    assert!(client.get_merchant_payment(&quote.ref_id).is_some());
}

#[test]
fn test_treasury_sweeps() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let recipient = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let quote = default_quote(&env, &token, "quote-treasury", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);
    client.process_merchant_payment(&payer, &quote, &signature);

    // Fee sweep is bounded by accrued fees.
    let over = client.try_sweep_platform_fees(&owner, &token, &recipient, &20_000);
    assert_eq!(over, Err(Ok(Error::FeeAmountInvalid)));

    client.sweep_platform_fees(&owner, &token, &recipient, &10_000);
    assert_eq!(client.get_platform_fee_accrued(&token), 0);

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&recipient), 10_000);
    assert_eq!(token_client.balance(&contract_id), 1_000_000 - 10_000);

    // Backing sweep moves the remaining merchant-payment principal.
    client.sweep_merchant_backing(&owner, &token, &recipient, &990_000);
    assert_eq!(token_client.balance(&contract_id), 0);
    assert_eq!(token_client.balance(&recipient), 1_000_000);
}

#[test]
fn test_withdrawal_timelock_flow() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let recipient = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let quote = default_quote(&env, &token, "quote-withdraw", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);
    client.process_merchant_payment(&payer, &quote, &signature);

    client.set_withdrawal_delay(&owner, &3600);

    // Immediate withdraw is blocked once a delay is configured.
    let blocked = client.try_withdraw(&owner, &token, &recipient, &1000);
    assert_eq!(blocked, Err(Ok(Error::TimelockActive)));

    let nonce = client.queue_withdrawal(&owner, &token, &recipient, &500_000);
    assert_eq!(nonce, 1);

    let too_early = client.try_execute_withdrawal(&owner, &nonce);
    assert_eq!(too_early, Err(Ok(Error::TimelockNotExpired)));

    env.ledger().set_timestamp(env.ledger().timestamp() + 3601);
    client.execute_withdrawal(&owner, &nonce);

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&recipient), 500_000);

    let already = client.try_execute_withdrawal(&owner, &nonce);
    assert_eq!(already, Err(Ok(Error::AlreadyExecuted)));
}

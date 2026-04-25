use anchor_lang::prelude::*;
use anchor_lang::solana_program::sysvar::instructions::{
    load_current_index_checked, load_instruction_at_checked,
};
use anchor_lang::system_program;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};

use crate::errors::TakumiPayError;
use crate::state::*;

// Ed25519SigVerify111111111111111111111111111
const ED25519_PROGRAM_ID: Pubkey = Pubkey::new_from_array([
    3, 125, 70, 214, 124, 147, 251, 190, 18, 249, 66, 143, 131, 141, 64, 255, 5, 112, 116, 73,
    39, 244, 138, 100, 252, 202, 112, 68, 128, 0, 0, 0,
]);

// ── Process Merchant Payment SOL ───────────────────────────────────────────

#[derive(Accounts)]
#[instruction(params: MerchantQuoteParams)]
pub struct ProcessMerchantPaymentSol<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ TakumiPayError::ContractPaused,
    )]
    pub config: Account<'info, Config>,

    #[account(
        init,
        payer = payer,
        space = 8 + MerchantPayment::INIT_SPACE,
        seeds = [MERCHANT_PAYMENT_SEED, config.key().as_ref(), &params.ref_id_hash],
        bump,
    )]
    pub merchant_payment: Account<'info, MerchantPayment>,

    #[account(
        init_if_needed,
        payer = payer,
        space = 8 + PlatformFeeAccount::INIT_SPACE,
        seeds = [PLATFORM_FEE_SEED, config.key().as_ref(), Pubkey::default().as_ref()],
        bump,
    )]
    pub platform_fee_account: Account<'info, PlatformFeeAccount>,

    /// CHECK: Instructions sysvar for Ed25519 signature verification.
    #[account(address = anchor_lang::solana_program::sysvar::instructions::id())]
    pub instructions_sysvar: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_process_merchant_payment_sol(
    ctx: Context<ProcessMerchantPaymentSol>,
    params: MerchantQuoteParams,
) -> Result<()> {
    validate_merchant_params(&params)?;

    let config = &ctx.accounts.config;
    let clock = Clock::get()?;
    require!(
        clock.unix_timestamp <= params.expires_at,
        TakumiPayError::QuoteExpired
    );
    require!(
        params.platform_fee_amount <= params.amount,
        TakumiPayError::FeeExceedsAmount
    );

    let message = build_quote_message(&params, &Pubkey::default());
    verify_ed25519_signature(
        &ctx.accounts.instructions_sysvar,
        &config.backend_signer.to_bytes(),
        &message,
    )?;

    let cpi_ctx = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: ctx.accounts.payer.to_account_info(),
            to: ctx.accounts.config.to_account_info(),
        },
    );
    system_program::transfer(cpi_ctx, params.amount)?;

    write_merchant_payment(
        &mut ctx.accounts.merchant_payment,
        &ctx.accounts.config,
        &ctx.accounts.payer,
        &Pubkey::default(),
        &params,
        clock.unix_timestamp,
        ctx.bumps.merchant_payment,
    );

    let pfa = &mut ctx.accounts.platform_fee_account;
    pfa.config = config.key();
    pfa.token_mint = Pubkey::default();
    pfa.accrued_amount = pfa
        .accrued_amount
        .checked_add(params.platform_fee_amount)
        .ok_or(TakumiPayError::Overflow)?;
    pfa.bump = ctx.bumps.platform_fee_account;

    emit!(MerchantPaymentProcessed {
        ref_id: params.ref_id,
        merchant_id: params.merchant_id,
        payer: ctx.accounts.payer.key(),
        token_mint: Pubkey::default(),
        amount: params.amount,
        platform_fee_amount: params.platform_fee_amount,
        fiat_amount_minor: params.fiat_amount_minor,
        exchange_rate_id: params.exchange_rate_id,
    });

    Ok(())
}

// ── Process Merchant Payment Token ─────────────────────────────────────────

#[derive(Accounts)]
#[instruction(params: MerchantQuoteParams)]
pub struct ProcessMerchantPaymentToken<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ TakumiPayError::ContractPaused,
    )]
    pub config: Account<'info, Config>,

    #[account(
        init,
        payer = payer,
        space = 8 + MerchantPayment::INIT_SPACE,
        seeds = [MERCHANT_PAYMENT_SEED, config.key().as_ref(), &params.ref_id_hash],
        bump,
    )]
    pub merchant_payment: Account<'info, MerchantPayment>,

    #[account(
        init_if_needed,
        payer = payer,
        space = 8 + PlatformFeeAccount::INIT_SPACE,
        seeds = [PLATFORM_FEE_SEED, config.key().as_ref(), token_mint.key().as_ref()],
        bump,
    )]
    pub platform_fee_account: Account<'info, PlatformFeeAccount>,

    pub token_mint: Account<'info, Mint>,

    #[account(
        mut,
        associated_token::mint = token_mint,
        associated_token::authority = payer,
    )]
    pub payer_token_account: Account<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = token_mint,
        associated_token::authority = config,
    )]
    pub vault_token_account: Account<'info, TokenAccount>,

    /// CHECK: Instructions sysvar for Ed25519 signature verification.
    #[account(address = anchor_lang::solana_program::sysvar::instructions::id())]
    pub instructions_sysvar: AccountInfo<'info>,

    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handle_process_merchant_payment_token(
    ctx: Context<ProcessMerchantPaymentToken>,
    params: MerchantQuoteParams,
) -> Result<()> {
    validate_merchant_params(&params)?;

    let config = &ctx.accounts.config;
    let clock = Clock::get()?;
    require!(
        clock.unix_timestamp <= params.expires_at,
        TakumiPayError::QuoteExpired
    );
    require!(
        params.platform_fee_amount <= params.amount,
        TakumiPayError::FeeExceedsAmount
    );

    let mint_key = ctx.accounts.token_mint.key();
    let message = build_quote_message(&params, &mint_key);
    verify_ed25519_signature(
        &ctx.accounts.instructions_sysvar,
        &config.backend_signer.to_bytes(),
        &message,
    )?;

    let cpi_accounts = Transfer {
        from: ctx.accounts.payer_token_account.to_account_info(),
        to: ctx.accounts.vault_token_account.to_account_info(),
        authority: ctx.accounts.payer.to_account_info(),
    };
    token::transfer(
        CpiContext::new(ctx.accounts.token_program.to_account_info(), cpi_accounts),
        params.amount,
    )?;

    write_merchant_payment(
        &mut ctx.accounts.merchant_payment,
        &ctx.accounts.config,
        &ctx.accounts.payer,
        &mint_key,
        &params,
        clock.unix_timestamp,
        ctx.bumps.merchant_payment,
    );

    let pfa = &mut ctx.accounts.platform_fee_account;
    pfa.config = config.key();
    pfa.token_mint = mint_key;
    pfa.accrued_amount = pfa
        .accrued_amount
        .checked_add(params.platform_fee_amount)
        .ok_or(TakumiPayError::Overflow)?;
    pfa.bump = ctx.bumps.platform_fee_account;

    emit!(MerchantPaymentProcessed {
        ref_id: params.ref_id,
        merchant_id: params.merchant_id,
        payer: ctx.accounts.payer.key(),
        token_mint: mint_key,
        amount: params.amount,
        platform_fee_amount: params.platform_fee_amount,
        fiat_amount_minor: params.fiat_amount_minor,
        exchange_rate_id: params.exchange_rate_id,
    });

    Ok(())
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn validate_merchant_params(params: &MerchantQuoteParams) -> Result<()> {
    require!(params.amount > 0, TakumiPayError::ZeroAmount);
    require!(
        verify_ref_id_hash(&params.ref_id, &params.ref_id_hash),
        TakumiPayError::InvalidRefIdHash
    );
    require!(
        validate_string(&params.ref_id),
        TakumiPayError::InvalidStringLength
    );
    require!(
        validate_string(&params.merchant_id),
        TakumiPayError::InvalidStringLength
    );
    Ok(())
}

fn write_merchant_payment(
    mp: &mut Account<MerchantPayment>,
    config: &Account<Config>,
    payer: &Signer,
    token_mint: &Pubkey,
    params: &MerchantQuoteParams,
    timestamp: i64,
    bump: u8,
) {
    mp.config = config.key();
    mp.payer = payer.key();
    mp.token_mint = *token_mint;
    mp.merchant_id = params.merchant_id.clone();
    mp.ref_id = params.ref_id.clone();
    mp.amount = params.amount;
    mp.platform_fee_amount = params.platform_fee_amount;
    mp.fiat_amount_minor = params.fiat_amount_minor;
    mp.fiat_currency = params.fiat_currency;
    mp.exchange_rate_id = params.exchange_rate_id;
    mp.timestamp = timestamp;
    mp.bump = bump;
}

/// Builds a deterministic message from quote parameters for Ed25519 verification.
/// Format: Borsh-like manual serialization for cross-platform compatibility.
///   [ref_id_len:u32][ref_id_bytes]
///   [merchant_id_len:u32][merchant_id_bytes]
///   [token_mint:32]
///   [amount:u64le][platform_fee:u64le][fiat_amount:u64le]
///   [fiat_currency:3]
///   [exchange_rate_id:u64le][expires_at:i64le]
fn build_quote_message(params: &MerchantQuoteParams, token_mint: &Pubkey) -> Vec<u8> {
    let mut msg = Vec::with_capacity(256);

    let ref_id_bytes = params.ref_id.as_bytes();
    msg.extend_from_slice(&(ref_id_bytes.len() as u32).to_le_bytes());
    msg.extend_from_slice(ref_id_bytes);

    let merchant_id_bytes = params.merchant_id.as_bytes();
    msg.extend_from_slice(&(merchant_id_bytes.len() as u32).to_le_bytes());
    msg.extend_from_slice(merchant_id_bytes);

    msg.extend_from_slice(token_mint.as_ref());
    msg.extend_from_slice(&params.amount.to_le_bytes());
    msg.extend_from_slice(&params.platform_fee_amount.to_le_bytes());
    msg.extend_from_slice(&params.fiat_amount_minor.to_le_bytes());
    msg.extend_from_slice(&params.fiat_currency);
    msg.extend_from_slice(&params.exchange_rate_id.to_le_bytes());
    msg.extend_from_slice(&params.expires_at.to_le_bytes());

    msg
}

/// Verifies that a preceding Ed25519 signature verification instruction exists
/// in the same transaction with the expected public key and message.
fn verify_ed25519_signature(
    instructions_sysvar: &AccountInfo,
    expected_pubkey: &[u8; 32],
    expected_message: &[u8],
) -> Result<()> {
    let current_ix_index = load_current_index_checked(instructions_sysvar)
        .map_err(|_| error!(TakumiPayError::InvalidEd25519Instruction))?;

    let mut ed25519_ix_data: Option<Vec<u8>> = None;

    for i in 0..current_ix_index {
        let ix = load_instruction_at_checked(i as usize, instructions_sysvar)
            .map_err(|_| error!(TakumiPayError::InvalidEd25519Instruction))?;
        if ix.program_id == ED25519_PROGRAM_ID {
            ed25519_ix_data = Some(ix.data);
            break;
        }
    }

    let ix_data =
        ed25519_ix_data.ok_or_else(|| error!(TakumiPayError::MissingEd25519Instruction))?;

    // Ed25519 instruction data layout (single signature):
    // [0]      num_signatures: u8
    // [1]      padding: u8
    // [2..4]   signature_offset: u16
    // [4..6]   signature_instruction_index: u16
    // [6..8]   public_key_offset: u16
    // [8..10]  public_key_instruction_index: u16
    // [10..12] message_data_offset: u16
    // [12..14] message_data_size: u16
    // [14..16] message_instruction_index: u16
    require!(
        ix_data.len() >= 16,
        TakumiPayError::InvalidEd25519Instruction
    );
    require!(ix_data[0] == 1, TakumiPayError::InvalidEd25519Instruction);

    let pubkey_offset = u16::from_le_bytes([ix_data[6], ix_data[7]]) as usize;
    let msg_offset = u16::from_le_bytes([ix_data[10], ix_data[11]]) as usize;
    let msg_size = u16::from_le_bytes([ix_data[12], ix_data[13]]) as usize;

    require!(
        ix_data.len() >= pubkey_offset + 32,
        TakumiPayError::InvalidEd25519Instruction
    );
    require!(
        &ix_data[pubkey_offset..pubkey_offset + 32] == expected_pubkey.as_ref(),
        TakumiPayError::BadQuote
    );

    require!(
        ix_data.len() >= msg_offset + msg_size,
        TakumiPayError::InvalidEd25519Instruction
    );
    require!(
        &ix_data[msg_offset..msg_offset + msg_size] == expected_message,
        TakumiPayError::BadQuote
    );

    Ok(())
}

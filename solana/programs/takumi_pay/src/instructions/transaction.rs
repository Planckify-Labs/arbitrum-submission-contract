use anchor_lang::prelude::*;
use anchor_lang::system_program;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{self, Mint, TokenInterface, TokenAccount, TransferChecked};

use crate::errors::TakumiPayError;
use crate::state::*;

// ── Create Transaction SOL ─────────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(params: CreateTransactionParams)]
pub struct CreateTransactionSol<'info> {
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
        space = 8 + TransactionRecord::INIT_SPACE,
        seeds = [TX_RECORD_SEED, config.key().as_ref(), &(config.tx_counter + 1).to_le_bytes()],
        bump,
    )]
    pub tx_record: Account<'info, TransactionRecord>,

    #[account(
        init,
        payer = payer,
        space = 8 + RefRecord::INIT_SPACE,
        seeds = [REF_RECORD_SEED, config.key().as_ref(), &params.ref_id_hash],
        bump,
    )]
    pub ref_record: Account<'info, RefRecord>,

    pub spending_limit: Option<Account<'info, SpendingLimit>>,

    pub system_program: Program<'info, System>,
}

pub fn handle_create_transaction_sol(
    ctx: Context<CreateTransactionSol>,
    params: CreateTransactionParams,
) -> Result<()> {
    validate_tx_params(&params)?;
    check_spending_limit(&ctx.accounts.spending_limit, &ctx.accounts.config, &Pubkey::default(), params.amount)?;

    let cpi_ctx = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: ctx.accounts.payer.to_account_info(),
            to: ctx.accounts.config.to_account_info(),
        },
    );
    system_program::transfer(cpi_ctx, params.amount)?;

    let config = &mut ctx.accounts.config;
    config.tx_counter += 1;
    let tx_id = config.tx_counter;
    let clock = Clock::get()?;

    let tx_rec = &mut ctx.accounts.tx_record;
    tx_rec.config = config.key();
    tx_rec.tx_id = tx_id;
    tx_rec.wallet_address = ctx.accounts.payer.key();
    tx_rec.token_mint = Pubkey::default();
    tx_rec.booking_id = params.booking_id.clone();
    tx_rec.exchange_rate_id = params.exchange_rate_id;
    tx_rec.product_variant_id = params.product_variant_id.clone();
    tx_rec.ref_id = params.ref_id.clone();
    tx_rec.amount = params.amount;
    tx_rec.timestamp = clock.unix_timestamp;
    tx_rec.bump = ctx.bumps.tx_record;

    let ref_rec = &mut ctx.accounts.ref_record;
    ref_rec.config = config.key();
    ref_rec.record_id = tx_id;
    ref_rec.bump = ctx.bumps.ref_record;

    emit!(TransactionCreated {
        tx_id,
        wallet_address: ctx.accounts.payer.key(),
        token_mint: Pubkey::default(),
        booking_id: params.booking_id,
        exchange_rate_id: params.exchange_rate_id,
        product_variant_id: params.product_variant_id,
        ref_id: params.ref_id,
        amount: params.amount,
        timestamp: clock.unix_timestamp,
    });

    Ok(())
}

// ── Create Transaction Token ───────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(params: CreateTransactionParams)]
pub struct CreateTransactionToken<'info> {
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
        space = 8 + TransactionRecord::INIT_SPACE,
        seeds = [TX_RECORD_SEED, config.key().as_ref(), &(config.tx_counter + 1).to_le_bytes()],
        bump,
    )]
    pub tx_record: Account<'info, TransactionRecord>,

    #[account(
        init,
        payer = payer,
        space = 8 + RefRecord::INIT_SPACE,
        seeds = [REF_RECORD_SEED, config.key().as_ref(), &params.ref_id_hash],
        bump,
    )]
    pub ref_record: Account<'info, RefRecord>,

    pub token_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        associated_token::mint = token_mint,
        associated_token::authority = payer,
    )]
    pub payer_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = token_mint,
        associated_token::authority = config,
    )]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,

    pub spending_limit: Option<Account<'info, SpendingLimit>>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handle_create_transaction_token(
    ctx: Context<CreateTransactionToken>,
    params: CreateTransactionParams,
) -> Result<()> {
    validate_tx_params(&params)?;
    let mint_key = ctx.accounts.token_mint.key();
    check_spending_limit(&ctx.accounts.spending_limit, &ctx.accounts.config, &mint_key, params.amount)?;

    let cpi_accounts = TransferChecked {
        from: ctx.accounts.payer_token_account.to_account_info(),
        to: ctx.accounts.vault_token_account.to_account_info(),
        authority: ctx.accounts.payer.to_account_info(),
        mint: ctx.accounts.token_mint.to_account_info(),
    };
    token_interface::transfer_checked(
        CpiContext::new(ctx.accounts.token_program.to_account_info(), cpi_accounts),
        params.amount,
        ctx.accounts.token_mint.decimals,
    )?;

    let config = &mut ctx.accounts.config;
    config.tx_counter += 1;
    let tx_id = config.tx_counter;
    let clock = Clock::get()?;

    let tx_rec = &mut ctx.accounts.tx_record;
    tx_rec.config = config.key();
    tx_rec.tx_id = tx_id;
    tx_rec.wallet_address = ctx.accounts.payer.key();
    tx_rec.token_mint = mint_key;
    tx_rec.booking_id = params.booking_id.clone();
    tx_rec.exchange_rate_id = params.exchange_rate_id;
    tx_rec.product_variant_id = params.product_variant_id.clone();
    tx_rec.ref_id = params.ref_id.clone();
    tx_rec.amount = params.amount;
    tx_rec.timestamp = clock.unix_timestamp;
    tx_rec.bump = ctx.bumps.tx_record;

    let ref_rec = &mut ctx.accounts.ref_record;
    ref_rec.config = config.key();
    ref_rec.record_id = tx_id;
    ref_rec.bump = ctx.bumps.ref_record;

    emit!(TransactionCreated {
        tx_id,
        wallet_address: ctx.accounts.payer.key(),
        token_mint: mint_key,
        booking_id: params.booking_id,
        exchange_rate_id: params.exchange_rate_id,
        product_variant_id: params.product_variant_id,
        ref_id: params.ref_id,
        amount: params.amount,
        timestamp: clock.unix_timestamp,
    });

    Ok(())
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn validate_tx_params(params: &CreateTransactionParams) -> Result<()> {
    require!(params.amount > 0, TakumiPayError::ZeroAmount);
    require!(
        verify_ref_id_hash(&params.ref_id, &params.ref_id_hash),
        TakumiPayError::InvalidRefIdHash
    );
    require!(
        validate_string(&params.booking_id),
        TakumiPayError::InvalidStringLength
    );
    require!(
        validate_string(&params.product_variant_id),
        TakumiPayError::InvalidStringLength
    );
    require!(
        validate_string(&params.ref_id),
        TakumiPayError::InvalidStringLength
    );
    Ok(())
}

fn check_spending_limit(
    spending_limit: &Option<Account<SpendingLimit>>,
    config: &Account<Config>,
    token_mint: &Pubkey,
    amount: u64,
) -> Result<()> {
    if let Some(sl) = spending_limit {
        if sl.config == config.key() && sl.token_mint == *token_mint && sl.max_amount > 0 {
            require!(amount <= sl.max_amount, TakumiPayError::AmountExceedsLimit);
        }
    }
    Ok(())
}

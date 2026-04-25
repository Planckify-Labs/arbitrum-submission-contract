use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};

use crate::errors::TakumiPayError;
use crate::state::*;

// ── Deposit Points ─────────────────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(ref_id: String, ref_id_hash: [u8; 32])]
pub struct DepositPoints<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ TakumiPayError::ContractPaused,
        constraint = !config.point_deposits_paused @ TakumiPayError::PointDepositsPaused,
    )]
    pub config: Account<'info, Config>,

    pub token_mint: Account<'info, Mint>,

    #[account(
        seeds = [ALLOWED_POINT_TOKEN_SEED, config.key().as_ref(), token_mint.key().as_ref()],
        bump = allowed_token.bump,
        has_one = config,
    )]
    pub allowed_token: Account<'info, AllowedPointToken>,

    #[account(
        init,
        payer = payer,
        space = 8 + PointDepositRecord::INIT_SPACE,
        seeds = [
            POINT_DEPOSIT_SEED,
            config.key().as_ref(),
            &(config.point_deposit_counter + 1).to_le_bytes(),
        ],
        bump,
    )]
    pub point_deposit: Account<'info, PointDepositRecord>,

    #[account(
        init,
        payer = payer,
        space = 8 + RefRecord::INIT_SPACE,
        seeds = [POINT_REF_SEED, config.key().as_ref(), &ref_id_hash],
        bump,
    )]
    pub point_ref_record: Account<'info, RefRecord>,

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

    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handle_deposit_points(
    ctx: Context<DepositPoints>,
    ref_id: String,
    ref_id_hash: [u8; 32],
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    require!(validate_string(&ref_id), TakumiPayError::InvalidStringLength);
    require!(
        verify_ref_id_hash(&ref_id, &ref_id_hash),
        TakumiPayError::InvalidRefIdHash
    );

    let cpi_accounts = Transfer {
        from: ctx.accounts.payer_token_account.to_account_info(),
        to: ctx.accounts.vault_token_account.to_account_info(),
        authority: ctx.accounts.payer.to_account_info(),
    };
    token::transfer(
        CpiContext::new(ctx.accounts.token_program.to_account_info(), cpi_accounts),
        amount,
    )?;

    let config = &mut ctx.accounts.config;
    config.point_deposit_counter += 1;
    let deposit_id = config.point_deposit_counter;
    let clock = Clock::get()?;

    let pd = &mut ctx.accounts.point_deposit;
    pd.config = config.key();
    pd.deposit_id = deposit_id;
    pd.wallet_address = ctx.accounts.payer.key();
    pd.token_mint = ctx.accounts.token_mint.key();
    pd.amount = amount;
    pd.ref_id = ref_id.clone();
    pd.timestamp = clock.unix_timestamp;
    pd.bump = ctx.bumps.point_deposit;

    let pr = &mut ctx.accounts.point_ref_record;
    pr.config = config.key();
    pr.record_id = deposit_id;
    pr.bump = ctx.bumps.point_ref_record;

    emit!(PointDepositCreated {
        deposit_id,
        wallet_address: ctx.accounts.payer.key(),
        token_mint: ctx.accounts.token_mint.key(),
        ref_id,
        amount,
        timestamp: clock.unix_timestamp,
    });

    Ok(())
}

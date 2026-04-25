use anchor_lang::prelude::*;
use anchor_spl::token_interface::{self, Mint, TokenInterface, TokenAccount, TransferChecked};

use crate::errors::TakumiPayError;
use crate::state::*;

// ── Sweep Platform Fees SOL ────────────────────────────────────────────────

#[derive(Accounts)]
pub struct SweepPlatformFeesSol<'info> {
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [PLATFORM_FEE_SEED, config.key().as_ref(), Pubkey::default().as_ref()],
        bump = platform_fee_account.bump,
        has_one = config,
    )]
    pub platform_fee_account: Account<'info, PlatformFeeAccount>,

    /// CHECK: Recipient for SOL fees. Validated as non-default in handler.
    #[account(mut)]
    pub recipient: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_sweep_platform_fees_sol(
    ctx: Context<SweepPlatformFeesSol>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    require!(
        ctx.accounts.recipient.key() != Pubkey::default(),
        TakumiPayError::ZeroRecipient
    );

    let pfa = &mut ctx.accounts.platform_fee_account;
    require!(
        amount <= pfa.accrued_amount,
        TakumiPayError::FeeAmountInvalid
    );
    pfa.accrued_amount -= amount;

    let rent = Rent::get()?;
    let min_balance = rent.minimum_balance(ctx.accounts.config.to_account_info().data_len());
    let available = ctx
        .accounts
        .config
        .to_account_info()
        .lamports()
        .checked_sub(min_balance)
        .ok_or(TakumiPayError::InsufficientBalance)?;
    require!(amount <= available, TakumiPayError::InsufficientBalance);

    **ctx
        .accounts
        .config
        .to_account_info()
        .try_borrow_mut_lamports()? -= amount;
    **ctx.accounts.recipient.try_borrow_mut_lamports()? += amount;

    emit!(PlatformFeesSwept {
        token_mint: Pubkey::default(),
        recipient: ctx.accounts.recipient.key(),
        amount,
    });

    Ok(())
}

// ── Sweep Platform Fees Token ──────────────────────────────────────────────

#[derive(Accounts)]
pub struct SweepPlatformFeesToken<'info> {
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    pub token_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        seeds = [PLATFORM_FEE_SEED, config.key().as_ref(), token_mint.key().as_ref()],
        bump = platform_fee_account.bump,
        has_one = config,
    )]
    pub platform_fee_account: Account<'info, PlatformFeeAccount>,

    #[account(
        mut,
        associated_token::mint = token_mint,
        associated_token::authority = config,
    )]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut)]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
}

pub fn handle_sweep_platform_fees_token(
    ctx: Context<SweepPlatformFeesToken>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);

    let pfa = &mut ctx.accounts.platform_fee_account;
    require!(
        amount <= pfa.accrued_amount,
        TakumiPayError::FeeAmountInvalid
    );
    pfa.accrued_amount -= amount;

    let config_bump = ctx.accounts.config.bump;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[config_bump]];
    let signer_seeds = &[seeds];

    let cpi_accounts = TransferChecked {
        from: ctx.accounts.vault_token_account.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.config.to_account_info(),
        mint: ctx.accounts.token_mint.to_account_info(),
    };
    token_interface::transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            cpi_accounts,
            signer_seeds,
        ),
        amount,
        ctx.accounts.token_mint.decimals,
    )?;

    emit!(PlatformFeesSwept {
        token_mint: ctx.accounts.token_mint.key(),
        recipient: ctx.accounts.recipient_token_account.key(),
        amount,
    });

    Ok(())
}

// ── Sweep Merchant Backing SOL ─────────────────────────────────────────────

#[derive(Accounts)]
pub struct SweepMerchantBackingSol<'info> {
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: Recipient for SOL. Validated as non-default in handler.
    #[account(mut)]
    pub recipient: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_sweep_merchant_backing_sol(
    ctx: Context<SweepMerchantBackingSol>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    require!(
        ctx.accounts.recipient.key() != Pubkey::default(),
        TakumiPayError::ZeroRecipient
    );

    let rent = Rent::get()?;
    let min_balance = rent.minimum_balance(ctx.accounts.config.to_account_info().data_len());
    let available = ctx
        .accounts
        .config
        .to_account_info()
        .lamports()
        .checked_sub(min_balance)
        .ok_or(TakumiPayError::InsufficientBalance)?;
    require!(amount <= available, TakumiPayError::InsufficientBalance);

    **ctx
        .accounts
        .config
        .to_account_info()
        .try_borrow_mut_lamports()? -= amount;
    **ctx.accounts.recipient.try_borrow_mut_lamports()? += amount;

    emit!(MerchantBackingSwept {
        token_mint: Pubkey::default(),
        recipient: ctx.accounts.recipient.key(),
        amount,
    });

    Ok(())
}

// ── Sweep Merchant Backing Token ───────────────────────────────────────────

#[derive(Accounts)]
pub struct SweepMerchantBackingToken<'info> {
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    pub token_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        associated_token::mint = token_mint,
        associated_token::authority = config,
    )]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut)]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
}

pub fn handle_sweep_merchant_backing_token(
    ctx: Context<SweepMerchantBackingToken>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);

    let config_bump = ctx.accounts.config.bump;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[config_bump]];
    let signer_seeds = &[seeds];

    let cpi_accounts = TransferChecked {
        from: ctx.accounts.vault_token_account.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.config.to_account_info(),
        mint: ctx.accounts.token_mint.to_account_info(),
    };
    token_interface::transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            cpi_accounts,
            signer_seeds,
        ),
        amount,
        ctx.accounts.token_mint.decimals,
    )?;

    emit!(MerchantBackingSwept {
        token_mint: ctx.accounts.token_mint.key(),
        recipient: ctx.accounts.recipient_token_account.key(),
        amount,
    });

    Ok(())
}

use anchor_lang::prelude::*;
use anchor_spl::token_interface::{self, Mint, TokenInterface, TokenAccount, TransferChecked};

use crate::errors::TakumiPayError;
use crate::state::*;

// ── Withdraw SOL (Immediate) ───────────────────────────────────────────────

#[derive(Accounts)]
pub struct WithdrawSol<'info> {
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

pub fn handle_withdraw_sol(ctx: Context<WithdrawSol>, amount: u64) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    require!(
        ctx.accounts.recipient.key() != Pubkey::default(),
        TakumiPayError::ZeroRecipient
    );
    require!(
        ctx.accounts.config.withdrawal_delay == 0,
        TakumiPayError::TimelockActive
    );

    transfer_sol_from_config(&ctx.accounts.config, &ctx.accounts.recipient, amount)?;

    emit!(WithdrawEvent {
        recipient: ctx.accounts.recipient.key(),
        token_mint: Pubkey::default(),
        amount,
    });

    Ok(())
}

// ── Withdraw Token (Immediate) ─────────────────────────────────────────────

#[derive(Accounts)]
pub struct WithdrawToken<'info> {
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

pub fn handle_withdraw_token(ctx: Context<WithdrawToken>, amount: u64) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    require!(
        ctx.accounts.config.withdrawal_delay == 0,
        TakumiPayError::TimelockActive
    );

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

    emit!(WithdrawEvent {
        recipient: ctx.accounts.recipient_token_account.key(),
        token_mint: ctx.accounts.token_mint.key(),
        amount,
    });

    Ok(())
}

// ── Set Withdrawal Delay ───────────────────────────────────────────────────

#[derive(Accounts)]
pub struct SetWithdrawalDelay<'info> {
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,
}

pub fn handle_set_withdrawal_delay(ctx: Context<SetWithdrawalDelay>, delay: i64) -> Result<()> {
    require!(delay >= 0 && delay <= MAX_WITHDRAWAL_DELAY, TakumiPayError::DelayExceedsMax);

    ctx.accounts.config.withdrawal_delay = delay;

    emit!(WithdrawalDelayUpdated { delay });
    Ok(())
}

// ── Queue Withdrawal ───────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct QueueWithdrawal<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        init,
        payer = owner,
        space = 8 + WithdrawalRequest::INIT_SPACE,
        seeds = [
            WITHDRAWAL_SEED,
            config.key().as_ref(),
            &(config.withdrawal_nonce + 1).to_le_bytes(),
        ],
        bump,
    )]
    pub withdrawal_request: Account<'info, WithdrawalRequest>,

    pub system_program: Program<'info, System>,
}

pub fn handle_queue_withdrawal(
    ctx: Context<QueueWithdrawal>,
    token_mint: Pubkey,
    recipient: Pubkey,
    amount: u64,
    is_native: bool,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    require!(recipient != Pubkey::default(), TakumiPayError::ZeroRecipient);
    require!(
        ctx.accounts.config.withdrawal_delay > 0,
        TakumiPayError::NoDelaySet
    );

    let config = &mut ctx.accounts.config;
    config.withdrawal_nonce += 1;

    let clock = Clock::get()?;
    let unlock_time = clock
        .unix_timestamp
        .checked_add(config.withdrawal_delay)
        .ok_or(TakumiPayError::Overflow)?;

    let wr = &mut ctx.accounts.withdrawal_request;
    wr.config = config.key();
    wr.token_mint = token_mint;
    wr.recipient = recipient;
    wr.amount = amount;
    wr.unlock_time = unlock_time;
    wr.executed = false;
    wr.cancelled = false;
    wr.nonce = config.withdrawal_nonce;
    wr.is_native = is_native;
    wr.bump = ctx.bumps.withdrawal_request;

    emit!(WithdrawalQueued {
        withdrawal_id: ctx.accounts.withdrawal_request.key(),
        token_mint,
        recipient,
        amount,
        unlock_time,
    });

    Ok(())
}

// ── Execute Withdrawal SOL ─────────────────────────────────────────────────

#[derive(Accounts)]
pub struct ExecuteWithdrawalSol<'info> {
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
        has_one = config,
        constraint = !withdrawal_request.executed @ TakumiPayError::AlreadyExecuted,
        constraint = !withdrawal_request.cancelled @ TakumiPayError::AlreadyCancelled,
        constraint = withdrawal_request.is_native @ TakumiPayError::WithdrawalTypeMismatch,
        seeds = [
            WITHDRAWAL_SEED,
            config.key().as_ref(),
            &withdrawal_request.nonce.to_le_bytes(),
        ],
        bump = withdrawal_request.bump,
    )]
    pub withdrawal_request: Account<'info, WithdrawalRequest>,

    /// CHECK: Validated against withdrawal_request.recipient.
    #[account(
        mut,
        constraint = recipient.key() == withdrawal_request.recipient @ TakumiPayError::ZeroRecipient,
    )]
    pub recipient: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_execute_withdrawal_sol(ctx: Context<ExecuteWithdrawalSol>) -> Result<()> {
    let clock = Clock::get()?;
    require!(
        clock.unix_timestamp >= ctx.accounts.withdrawal_request.unlock_time,
        TakumiPayError::TimelockNotExpired
    );

    let amount = ctx.accounts.withdrawal_request.amount;
    ctx.accounts.withdrawal_request.executed = true;

    transfer_sol_from_config(&ctx.accounts.config, &ctx.accounts.recipient, amount)?;

    emit!(WithdrawalExecuted {
        withdrawal_id: ctx.accounts.withdrawal_request.key(),
    });

    Ok(())
}

// ── Execute Withdrawal Token ───────────────────────────────────────────────

#[derive(Accounts)]
pub struct ExecuteWithdrawalToken<'info> {
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        has_one = config,
        constraint = !withdrawal_request.executed @ TakumiPayError::AlreadyExecuted,
        constraint = !withdrawal_request.cancelled @ TakumiPayError::AlreadyCancelled,
        constraint = !withdrawal_request.is_native @ TakumiPayError::WithdrawalTypeMismatch,
        seeds = [
            WITHDRAWAL_SEED,
            config.key().as_ref(),
            &withdrawal_request.nonce.to_le_bytes(),
        ],
        bump = withdrawal_request.bump,
    )]
    pub withdrawal_request: Account<'info, WithdrawalRequest>,

    #[account(
        constraint = token_mint.key() == withdrawal_request.token_mint,
    )]
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

pub fn handle_execute_withdrawal_token(ctx: Context<ExecuteWithdrawalToken>) -> Result<()> {
    let clock = Clock::get()?;
    require!(
        clock.unix_timestamp >= ctx.accounts.withdrawal_request.unlock_time,
        TakumiPayError::TimelockNotExpired
    );

    let amount = ctx.accounts.withdrawal_request.amount;
    ctx.accounts.withdrawal_request.executed = true;

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

    emit!(WithdrawalExecuted {
        withdrawal_id: ctx.accounts.withdrawal_request.key(),
    });

    Ok(())
}

// ── Cancel Withdrawal ──────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct CancelWithdrawal<'info> {
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        has_one = config,
        constraint = !withdrawal_request.executed @ TakumiPayError::AlreadyExecuted,
        constraint = !withdrawal_request.cancelled @ TakumiPayError::AlreadyCancelled,
        seeds = [
            WITHDRAWAL_SEED,
            config.key().as_ref(),
            &withdrawal_request.nonce.to_le_bytes(),
        ],
        bump = withdrawal_request.bump,
    )]
    pub withdrawal_request: Account<'info, WithdrawalRequest>,
}

pub fn handle_cancel_withdrawal(ctx: Context<CancelWithdrawal>) -> Result<()> {
    ctx.accounts.withdrawal_request.cancelled = true;

    emit!(WithdrawalCancelled {
        withdrawal_id: ctx.accounts.withdrawal_request.key(),
    });

    Ok(())
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn transfer_sol_from_config<'info>(
    config: &Account<'info, Config>,
    recipient: &AccountInfo<'info>,
    amount: u64,
) -> Result<()> {
    let rent = Rent::get()?;
    let min_balance = rent.minimum_balance(config.to_account_info().data_len());
    let available = config
        .to_account_info()
        .lamports()
        .checked_sub(min_balance)
        .ok_or(TakumiPayError::InsufficientBalance)?;
    require!(amount <= available, TakumiPayError::InsufficientBalance);

    **config.to_account_info().try_borrow_mut_lamports()? -= amount;
    **recipient.try_borrow_mut_lamports()? += amount;

    Ok(())
}

use anchor_lang::prelude::*;

use crate::errors::TakumiPayError;
use crate::state::*;

// ── Shared enforcement ─────────────────────────────────────────────────────

/// Charges `amount` against the token's rolling per-window sweep allowance.
///
/// An unset cap fails closed. Every treasury sweep routes through here, which is
/// what bounds the blast radius of a leaked owner key: sweeps intentionally skip
/// the withdrawal timelock so merchant float can settle daily, and without this
/// the timelock would be trivially sidestepped by sweeping instead of withdrawing.
pub fn consume_sweep_allowance(sweep_cap: &mut Account<SweepCap>, amount: u64) -> Result<()> {
    require!(sweep_cap.cap > 0, TakumiPayError::SweepCapNotSet);
    if sweep_cap.cap == SWEEP_CAP_UNLIMITED {
        return Ok(());
    }

    let now = Clock::get()?.unix_timestamp;
    if now.saturating_sub(sweep_cap.window_start) >= SWEEP_WINDOW {
        sweep_cap.window_start = now;
        sweep_cap.swept_in_window = 0;
    }

    let swept = sweep_cap
        .swept_in_window
        .checked_add(amount)
        .ok_or(TakumiPayError::Overflow)?;
    require!(swept <= sweep_cap.cap, TakumiPayError::SweepCapExceeded);
    sweep_cap.swept_in_window = swept;

    Ok(())
}

// ── Set Sweep Cap (lower / tighten — immediate) ────────────────────────────

#[derive(Accounts)]
#[instruction(token_mint: Pubkey)]
pub struct SetSweepCap<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = owner,
        space = 8 + SweepCap::INIT_SPACE,
        seeds = [SWEEP_CAP_SEED, config.key().as_ref(), token_mint.as_ref()],
        bump,
    )]
    pub sweep_cap: Account<'info, SweepCap>,

    pub system_program: Program<'info, System>,
}

/// Lowers a token's sweep cap. Immediate — tightening a control is always safe.
/// Raising must go through `queue_sweep_cap`, otherwise the rate limit would be
/// one call away from being defeated.
pub fn handle_set_sweep_cap(ctx: Context<SetSweepCap>, token_mint: Pubkey, cap: u64) -> Result<()> {
    let sc = &mut ctx.accounts.sweep_cap;

    // Freshly initialised accounts start at cap 0; only a lowering is valid here.
    if sc.config == Pubkey::default() {
        sc.config = ctx.accounts.config.key();
        sc.token_mint = token_mint;
        sc.bump = ctx.bumps.sweep_cap;
    }
    require!(cap <= sc.cap, TakumiPayError::NotALoosening);

    sc.cap = cap;

    emit!(SweepCapUpdated {
        token_mint,
        cap,
    });
    Ok(())
}

// ── Queue Sweep Cap increase ───────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(token_mint: Pubkey)]
pub struct QueueSweepCap<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = owner,
        space = 8 + SweepCap::INIT_SPACE,
        seeds = [SWEEP_CAP_SEED, config.key().as_ref(), token_mint.as_ref()],
        bump,
    )]
    pub sweep_cap: Account<'info, SweepCap>,

    pub system_program: Program<'info, System>,
}

pub fn handle_queue_sweep_cap(
    ctx: Context<QueueSweepCap>,
    token_mint: Pubkey,
    cap: u64,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let delay = ctx.accounts.config.withdrawal_delay;
    let config_key = ctx.accounts.config.key();
    let bump = ctx.bumps.sweep_cap;
    let sc = &mut ctx.accounts.sweep_cap;

    if sc.config == Pubkey::default() {
        sc.config = config_key;
        sc.token_mint = token_mint;
        sc.bump = bump;
    }
    require!(cap > sc.cap, TakumiPayError::NotALoosening);

    let unlock_time = now.checked_add(delay).ok_or(TakumiPayError::Overflow)?;
    sc.pending_cap = cap;
    sc.pending_unlock_time = unlock_time;

    emit!(PendingSweepCapQueued {
        token_mint,
        cap,
        unlock_time,
    });
    Ok(())
}

// ── Apply / Cancel queued Sweep Cap ────────────────────────────────────────

#[derive(Accounts)]
#[instruction(token_mint: Pubkey)]
pub struct ModifyPendingSweepCap<'info> {
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [SWEEP_CAP_SEED, config.key().as_ref(), token_mint.as_ref()],
        bump = sweep_cap.bump,
        has_one = config,
    )]
    pub sweep_cap: Account<'info, SweepCap>,
}

pub fn handle_apply_sweep_cap(
    ctx: Context<ModifyPendingSweepCap>,
    token_mint: Pubkey,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let sc = &mut ctx.accounts.sweep_cap;

    require!(
        sc.pending_unlock_time > 0,
        TakumiPayError::NoPendingChange
    );
    require!(
        now >= sc.pending_unlock_time,
        TakumiPayError::PendingChangeLocked
    );

    let cap = sc.pending_cap;
    sc.cap = cap;
    sc.pending_cap = 0;
    sc.pending_unlock_time = 0;

    emit!(SweepCapUpdated {
        token_mint,
        cap,
    });
    Ok(())
}

pub fn handle_cancel_sweep_cap(
    ctx: Context<ModifyPendingSweepCap>,
    token_mint: Pubkey,
) -> Result<()> {
    let sc = &mut ctx.accounts.sweep_cap;

    require!(
        sc.pending_unlock_time > 0,
        TakumiPayError::NoPendingChange
    );
    sc.pending_cap = 0;
    sc.pending_unlock_time = 0;

    emit!(PendingSweepCapCancelled { token_mint });
    Ok(())
}

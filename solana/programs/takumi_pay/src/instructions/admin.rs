use anchor_lang::prelude::*;

use crate::errors::TakumiPayError;
use crate::state::*;

// ── Initialize ─────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        init,
        payer = owner,
        space = 8 + Config::INIT_SPACE,
        seeds = [CONFIG_SEED],
        bump,
    )]
    pub config: Account<'info, Config>,

    pub system_program: Program<'info, System>,
}

pub fn handle_initialize(ctx: Context<Initialize>, backend_signer: Pubkey) -> Result<()> {
    require!(
        backend_signer != Pubkey::default(),
        TakumiPayError::ZeroSigner
    );

    let config = &mut ctx.accounts.config;
    config.owner = ctx.accounts.owner.key();
    config.pending_owner = None;
    config.backend_signer = backend_signer;
    config.paused = false;
    config.point_deposits_paused = false;
    config.tx_counter = 0;
    config.point_deposit_counter = 0;
    config.withdrawal_delay = 0;
    config.withdrawal_nonce = 0;
    config.pending_withdrawal_delay = 0;
    config.pending_delay_unlock_time = 0;
    config.bump = ctx.bumps.config;

    Ok(())
}

// ── Add Admin ──────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct AddAdmin<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: The admin address to add. Validated as non-default in handler.
    pub admin_pubkey: AccountInfo<'info>,

    #[account(
        init,
        payer = owner,
        space = 8 + Admin::INIT_SPACE,
        seeds = [ADMIN_SEED, config.key().as_ref(), admin_pubkey.key().as_ref()],
        bump,
    )]
    pub admin_record: Account<'info, Admin>,

    pub system_program: Program<'info, System>,
}

pub fn handle_add_admin(ctx: Context<AddAdmin>) -> Result<()> {
    require!(
        ctx.accounts.admin_pubkey.key() != Pubkey::default(),
        TakumiPayError::ZeroAddress
    );

    let admin_record = &mut ctx.accounts.admin_record;
    admin_record.config = ctx.accounts.config.key();
    admin_record.admin = ctx.accounts.admin_pubkey.key();
    admin_record.bump = ctx.bumps.admin_record;

    emit!(AdminAdded {
        admin: ctx.accounts.admin_pubkey.key(),
    });

    Ok(())
}

// ── Remove Admin ───────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct RemoveAdmin<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: The admin address to remove.
    pub admin_pubkey: AccountInfo<'info>,

    #[account(
        mut,
        close = owner,
        seeds = [ADMIN_SEED, config.key().as_ref(), admin_pubkey.key().as_ref()],
        bump = admin_record.bump,
        has_one = config,
    )]
    pub admin_record: Account<'info, Admin>,
}

pub fn handle_remove_admin(ctx: Context<RemoveAdmin>) -> Result<()> {
    emit!(AdminRemoved {
        admin: ctx.accounts.admin_pubkey.key(),
    });
    Ok(())
}

// ── Transfer Ownership ─────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct TransferOwnership<'info> {
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,
}

pub fn handle_transfer_ownership(
    ctx: Context<TransferOwnership>,
    new_owner: Pubkey,
) -> Result<()> {
    require!(new_owner != Pubkey::default(), TakumiPayError::ZeroAddress);
    require!(
        new_owner != ctx.accounts.config.owner,
        TakumiPayError::AlreadyOwner
    );

    let config = &mut ctx.accounts.config;
    config.pending_owner = Some(new_owner);

    emit!(OwnershipTransferInitiated {
        current_owner: config.owner,
        pending_owner: new_owner,
    });

    Ok(())
}

// ── Accept Ownership ───────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct AcceptOwnership<'info> {
    pub new_owner: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,
}

pub fn handle_accept_ownership(ctx: Context<AcceptOwnership>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let pending = config
        .pending_owner
        .ok_or(TakumiPayError::NoPendingTransfer)?;

    require!(
        ctx.accounts.new_owner.key() == pending,
        TakumiPayError::NotPendingOwner
    );

    let previous = config.owner;
    config.owner = pending;
    config.pending_owner = None;

    emit!(OwnershipTransferred {
        previous_owner: previous,
        new_owner: config.owner,
    });

    Ok(())
}

// ── Cancel Ownership Transfer ──────────────────────────────────────────────

#[derive(Accounts)]
pub struct CancelOwnershipTransfer<'info> {
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,
}

pub fn handle_cancel_ownership_transfer(ctx: Context<CancelOwnershipTransfer>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let cancelled = config
        .pending_owner
        .ok_or(TakumiPayError::NoPendingTransfer)?;
    config.pending_owner = None;

    emit!(OwnershipTransferCancelled {
        cancelled_pending_owner: cancelled,
    });

    Ok(())
}

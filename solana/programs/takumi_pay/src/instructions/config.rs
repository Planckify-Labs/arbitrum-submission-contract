use anchor_lang::prelude::*;
use anchor_spl::token::Mint;

use crate::errors::TakumiPayError;
use crate::state::*;

// ── Set Paused ─────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct SetPaused<'info> {
    pub authority: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    /// Optional admin record — required when caller is not the owner.
    pub admin_record: Option<Account<'info, Admin>>,
}

pub fn handle_set_paused(ctx: Context<SetPaused>, paused: bool) -> Result<()> {
    verify_admin_or_owner(&ctx.accounts.config, &ctx.accounts.authority, &ctx.accounts.admin_record)?;

    ctx.accounts.config.paused = paused;

    emit!(ContractPausedToggled { paused });
    Ok(())
}

// ── Set Spending Limit ─────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct SetSpendingLimit<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    pub token_mint: Account<'info, Mint>,

    #[account(
        init_if_needed,
        payer = owner,
        space = 8 + SpendingLimit::INIT_SPACE,
        seeds = [SPENDING_LIMIT_SEED, config.key().as_ref(), token_mint.key().as_ref()],
        bump,
    )]
    pub spending_limit: Account<'info, SpendingLimit>,

    pub system_program: Program<'info, System>,
}

pub fn handle_set_spending_limit(ctx: Context<SetSpendingLimit>, max_amount: u64) -> Result<()> {
    let sl = &mut ctx.accounts.spending_limit;
    sl.config = ctx.accounts.config.key();
    sl.token_mint = ctx.accounts.token_mint.key();
    sl.max_amount = max_amount;
    sl.bump = ctx.bumps.spending_limit;

    emit!(MaxTransactionAmountUpdated {
        token_mint: ctx.accounts.token_mint.key(),
        amount: max_amount,
    });

    Ok(())
}

// ── Rotate Backend Signer ──────────────────────────────────────────────────

#[derive(Accounts)]
pub struct RotateBackendSigner<'info> {
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,
}

pub fn handle_rotate_backend_signer(
    ctx: Context<RotateBackendSigner>,
    new_signer: Pubkey,
) -> Result<()> {
    require!(new_signer != Pubkey::default(), TakumiPayError::ZeroSigner);

    let config = &mut ctx.accounts.config;
    let previous = config.backend_signer;
    config.backend_signer = new_signer;

    emit!(BackendSignerRotated {
        previous,
        next: new_signer,
    });

    Ok(())
}

// ── Set Point Deposits Paused ──────────────────────────────────────────────

#[derive(Accounts)]
pub struct SetPointDepositsPaused<'info> {
    pub authority: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    pub admin_record: Option<Account<'info, Admin>>,
}

pub fn handle_set_point_deposits_paused(
    ctx: Context<SetPointDepositsPaused>,
    paused: bool,
) -> Result<()> {
    verify_admin_or_owner(&ctx.accounts.config, &ctx.accounts.authority, &ctx.accounts.admin_record)?;

    ctx.accounts.config.point_deposits_paused = paused;

    emit!(PointDepositsPausedToggled { paused });
    Ok(())
}

// ── Add Allowed Point Token ────────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(token_mint: Pubkey)]
pub struct AddAllowedPaymentToken<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        init,
        payer = owner,
        space = 8 + AllowedPaymentToken::INIT_SPACE,
        seeds = [ALLOWED_PAYMENT_TOKEN_SEED, config.key().as_ref(), token_mint.as_ref()],
        bump,
    )]
    pub allowed_token: Account<'info, AllowedPaymentToken>,

    pub system_program: Program<'info, System>,
}

/// `token_mint` is an argument rather than a `Mint` account so native SOL —
/// keyed by `Pubkey::default()`, which is not a mint — can be allowlisted with
/// the same instruction. The payment entrypoints still validate the real mint
/// through `InterfaceAccount<Mint>`.
pub fn handle_add_allowed_payment_token(
    ctx: Context<AddAllowedPaymentToken>,
    token_mint: Pubkey,
) -> Result<()> {
    let at = &mut ctx.accounts.allowed_token;
    at.config = ctx.accounts.config.key();
    at.token_mint = token_mint;
    at.bump = ctx.bumps.allowed_token;

    emit!(AllowedPaymentTokenAdded { token_mint });

    Ok(())
}

// ── Remove Allowed Point Token ─────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(token_mint: Pubkey)]
pub struct RemoveAllowedPaymentToken<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        close = owner,
        seeds = [ALLOWED_PAYMENT_TOKEN_SEED, config.key().as_ref(), token_mint.as_ref()],
        bump = allowed_token.bump,
        has_one = config,
    )]
    pub allowed_token: Account<'info, AllowedPaymentToken>,
}

pub fn handle_remove_allowed_payment_token(
    _ctx: Context<RemoveAllowedPaymentToken>,
    token_mint: Pubkey,
) -> Result<()> {
    emit!(AllowedPaymentTokenRemoved { token_mint });
    Ok(())
}

// ── Helpers ────────────────────────────────────────────────────────────────

pub fn verify_admin_or_owner(
    config: &Account<Config>,
    authority: &Signer,
    admin_record: &Option<Account<Admin>>,
) -> Result<()> {
    if authority.key() == config.owner {
        return Ok(());
    }
    if let Some(record) = admin_record {
        if record.admin == authority.key() && record.config == config.key() {
            return Ok(());
        }
    }
    Err(TakumiPayError::NotAdminOrOwner.into())
}

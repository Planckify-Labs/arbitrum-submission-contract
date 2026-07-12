use soroban_sdk::{Address, BytesN, Env};

use crate::errors::Error;
use crate::events::{
    AdminAdded, AdminRemoved, OwnershipTransferCancelled, OwnershipTransferInitiated,
    OwnershipTransferred,
};
use crate::types::{
    Config, DataKey, INSTANCE_BUMP_THRESHOLD, INSTANCE_BUMP_TO, PERSISTENT_BUMP_THRESHOLD,
    PERSISTENT_BUMP_TO,
};

// ── Shared storage / auth helpers (used by every other module) ────────────

pub fn get_config(env: &Env) -> Result<Config, Error> {
    env.storage()
        .instance()
        .get(&DataKey::Config)
        .ok_or(Error::NotInitialized)
}

pub fn save_config(env: &Env, config: &Config) {
    env.storage().instance().set(&DataKey::Config, config);
    env.storage()
        .instance()
        .extend_ttl(INSTANCE_BUMP_THRESHOLD, INSTANCE_BUMP_TO);
}

pub fn bump_persistent<K: soroban_sdk::IntoVal<Env, soroban_sdk::Val>>(env: &Env, key: &K) {
    env.storage().persistent().extend_ttl(
        key,
        PERSISTENT_BUMP_THRESHOLD,
        PERSISTENT_BUMP_TO,
    );
}

/// Requires `caller` to be the current owner. Also requires the owner's
/// signature via `require_auth` — every privileged entrypoint must call this
/// (or `require_admin_or_owner`) before mutating state.
pub fn require_owner(config: &Config, caller: &Address) -> Result<(), Error> {
    caller.require_auth();
    if *caller != config.owner {
        return Err(Error::NotOwner);
    }
    Ok(())
}

pub fn require_admin_or_owner(env: &Env, config: &Config, caller: &Address) -> Result<(), Error> {
    caller.require_auth();
    if *caller == config.owner {
        return Ok(());
    }
    if env
        .storage()
        .persistent()
        .has(&DataKey::Admin(caller.clone()))
    {
        return Ok(());
    }
    Err(Error::NotAdminOrOwner)
}

// ── Initialize ──────────────────────────────────────────────────────────

pub fn initialize(env: &Env, owner: Address, backend_signer: BytesN<32>) -> Result<(), Error> {
    if env.storage().instance().has(&DataKey::Config) {
        return Err(Error::AlreadyInitialized);
    }
    owner.require_auth();

    let config = Config {
        owner,
        pending_owner: None,
        backend_signer,
        paused: false,
        point_deposits_paused: false,
        tx_counter: 0,
        point_deposit_counter: 0,
        withdrawal_delay: 0,
        withdrawal_nonce: 0,
    };
    save_config(env, &config);
    Ok(())
}

// ── Admin management ───────────────────────────────────────────────────

pub fn add_admin(env: &Env, owner: Address, admin: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::Admin(admin.clone());
    if env.storage().persistent().has(&key) {
        return Err(Error::AdminAlreadyExists);
    }
    env.storage().persistent().set(&key, &true);
    bump_persistent(env, &key);

    AdminAdded { admin }.publish(env);
    Ok(())
}

pub fn remove_admin(env: &Env, owner: Address, admin: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::Admin(admin.clone());
    if !env.storage().persistent().has(&key) {
        return Err(Error::AdminNotFound);
    }
    env.storage().persistent().remove(&key);

    AdminRemoved { admin }.publish(env);
    Ok(())
}

// ── Ownership transfer (two-step) ─────────────────────────────────────

pub fn transfer_ownership(env: &Env, owner: Address, new_owner: Address) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    if new_owner == config.owner {
        return Err(Error::AlreadyOwner);
    }
    config.pending_owner = Some(new_owner.clone());
    save_config(env, &config);

    OwnershipTransferInitiated {
        previous_owner: config.owner,
        pending_owner: new_owner,
    }
    .publish(env);
    Ok(())
}

pub fn accept_ownership(env: &Env, new_owner: Address) -> Result<(), Error> {
    new_owner.require_auth();
    let mut config = get_config(env)?;

    let pending = config.pending_owner.clone().ok_or(Error::NoPendingTransfer)?;
    if new_owner != pending {
        return Err(Error::NotPendingOwner);
    }

    let previous = config.owner.clone();
    config.owner = pending;
    config.pending_owner = None;
    save_config(env, &config);

    OwnershipTransferred {
        previous_owner: previous,
        new_owner: config.owner,
    }
    .publish(env);
    Ok(())
}

pub fn cancel_ownership_transfer(env: &Env, owner: Address) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    let cancelled = config.pending_owner.clone().ok_or(Error::NoPendingTransfer)?;
    config.pending_owner = None;
    save_config(env, &config);

    OwnershipTransferCancelled {
        cancelled_pending_owner: cancelled,
    }
    .publish(env);
    Ok(())
}

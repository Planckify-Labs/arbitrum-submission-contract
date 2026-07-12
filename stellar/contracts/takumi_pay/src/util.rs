use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{Bytes, BytesN, Env, String};

/// Hashes a caller-supplied identifier (ref_id, etc.) into a fixed-size key
/// suitable for a storage map. Unlike the Solana sibling contract, the caller
/// does not need to pre-compute and pass this hash — Soroban lets us hash
/// on-chain from the `String` XDR encoding directly, which removes an entire
/// class of "hash doesn't match ref_id" bugs.
pub fn hash_string(env: &Env, s: &String) -> BytesN<32> {
    let bytes: Bytes = s.clone().to_xdr(env);
    env.crypto().sha256(&bytes).into()
}

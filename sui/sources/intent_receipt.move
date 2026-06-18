/// Intent receipt — a thin, additive on-chain audit log for the Takumi
/// Agentic Web Intent Engine (Phase 1 spec §10).
///
/// The Intent Engine appends `record` as the FINAL command of the SAME
/// Programmable Transaction Block that performs the user's action (a DeepBook
/// swap, a Scallop supply). Because a PTB executes atomically, the audit log is
/// part of the same all-or-nothing transaction.
///
/// AUTHENTICITY MODEL (read before indexing these events). `record` is
/// permissionless by design — every user records their OWN intent — so there is
/// no capability to forge or mis-scope. Two facts make a receipt trustworthy:
///   1. `who` is `ctx.sender()` — the real signer; it cannot be set to another
///      address.
///   2. `timestamp_ms` comes from the system `Clock` (the shared singleton at
///      0x6). `Clock` has no public constructor, so the type system guarantees
///      the argument IS the genuine 0x6 clock — it cannot be faked. (This is
///      precisely the property Pawtato's bug violated by trusting a forgeable
///      shared `UpgradeCap` — OZ "Notorious Bug Digest #8".)
/// An off-chain indexer must NOT treat a lone `IntentRecorded` as proof the app
/// acted — the guarantee is that it shares one atomic PTB with the real
/// swap/supply command. Filter by transactions that contain both.
///
/// Security posture, audited against OZ "Critical Bug Patterns in Sui Move" and
/// "Notorious Bug Digest #8": no arithmetic (no overflow/rounding — cf. the
/// math-lib silent-zero and Neutron rounding bugs), no generics (no
/// type-parameter mismatch), no hot-potato receipt (no ID-validation gap), no
/// mutable references (no value-vs-reference assignment bug), no stored objects
/// or capabilities (no ownership / access-control surface). `record` is
/// external-facing and stateless, so `public` with no capability is the correct
/// visibility (OZ pattern #3) — there is no privileged state to protect. The
/// only input is bounded below as defense-in-depth.
module takumi_intent::intent_receipt {
    use std::string::{Self, String};
    use sui::clock::Clock;
    use sui::event;

    /// Descriptor byte cap (defense-in-depth). The client truncates well below
    /// this, so a real call never reaches it; the assert bounds every event's
    /// size even if a caller passes a pathological string of their own.
    const MAX_DESCRIPTOR_BYTES: u64 = 256;

    /// `descriptor` exceeds `MAX_DESCRIPTOR_BYTES`.
    const EDescriptorTooLong: u64 = 0;

    /// One event per executed intent.
    /// * `who`          — the signer (from the transaction context).
    /// * `descriptor`   — the plain-language intent the agent compiled
    ///                    (e.g. "swap 5 SUI->USDC"). Never a raw SDK string.
    /// * `timestamp_ms` — on-chain time from the shared Clock.
    public struct IntentRecorded has copy, drop {
        who: address,
        descriptor: String,
        timestamp_ms: u64,
    }

    /// Append this as the final PTB command. `ctx` is supplied by the runtime
    /// (NOT a PTB argument); the caller passes only `descriptor` and the shared
    /// `Clock` object (`0x6`).
    public fun record(descriptor: String, clock: &Clock, ctx: &TxContext) {
        assert!(
            string::length(&descriptor) <= MAX_DESCRIPTOR_BYTES,
            EDescriptorTooLong,
        );
        event::emit(IntentRecorded {
            who: ctx.sender(),
            descriptor,
            timestamp_ms: clock.timestamp_ms(),
        });
    }
}

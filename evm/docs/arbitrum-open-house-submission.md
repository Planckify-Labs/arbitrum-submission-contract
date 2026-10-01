# TakumiPay: Arbitrum Open House submission

## One-liner

Send USDG across borders. The recipient signs up with a passkey, converts USDG into spendable
points, and pays everyday bills without ever cashing out.

## The problem

Stablecoin holders can't spend directly on the bills they actually pay: electricity, phone, mobile
top-ups. Remittance recipients end up cashing out through fee-heavy off-ramps just to cover them.
Crypto onboarding (seed phrases, gas) keeps non-crypto users out entirely.

## The product

1. **Passkey onboarding.** No seed phrase shown; Face ID / fingerprint creates the wallet.
2. **Receive USDG** on Arbitrum (or Robinhood Chain).
3. **Deposit USDG for points** (`depositPoints`). Points are a stored-value balance, not a reward
   scheme.
4. **Pay bills / merchants** with points or directly with USDG (`processMerchantPayment`, priced by a
   signed EIP-712 quote).

## Deployments (TakumiPay 2.1.0, UUPS proxy)

| Network | Chain ID | Proxy | Tokens |
|---|---|---|---|
| Arbitrum One | 42161 | `0xdE981573883294dfD35A7F0F399DB7e439E1f56B` | USDG, USDC |
| Arbitrum Sepolia | 421614 | `0x2469Bd87e809772f491af0E7847fbf7B62c388ae` | USDC, testnet USDG |
| Robinhood Chain testnet | 46630 | `0x479B0843C3e0627f36551660506dEd5b349Fa968` | testnet USDG |

Token addresses: USDG (Arbitrum One) `0x004B506865409877C9fA29bfb1ebA929984B9bbC`, USDG (Arbitrum
Sepolia) `0xFFC95faa3d63Cde504a05B567C600B78C0b41892`, USDG (Robinhood testnet)
`0x7E955252E15c84f5768B83c41a71F9eba181802F`. Full records, including every config transaction hash,
are in `evm/deployments/{42161,421614,46630}.json`.

### Live proof (testnet, real Paxos testnet USDG)

- Robinhood testnet: `createTransaction`, `depositPoints` and `processMerchantPayment` (with an EIP-712
  quote signed by the backend signer) all succeeded; the transaction hashes are in `46630.json`.
- Arbitrum Sepolia: `createTransaction` and `depositPoints` with USDG succeeded (`421614.json`).
- Arbitrum One is deployed and configured for USDG and USDC. The live demo runs on testnet.

## Smart contract design

- **Quote-signed pricing.** Merchant payments are only accepted with an EIP-712 `QuoteCommitment`
  signature from the backend signer, with expiry and a one-shot `refId` (replay protection).
- **Token allowlist.** Only allowlisted tokens are accepted; fee-on-transfer mismatches are rejected
  at pull time.
- **Treasury controls.** Every exit (fee sweeps, merchant backing, withdrawals, token recovery) is
  bounded by a per-token sweep cap that fails closed when unset. Raising a cap or lowering the
  withdrawal delay is itself time-delayed once a delay is set.
- **Withdrawal delay.** Arbitrum One runs a 24h delay, which disables the instant withdrawal paths.
- **Upgradeability.** UUPS, owner-gated, append-only storage with a `__gap`.
- **Tests.** Foundry suites cover merchant payments, point deposits, the native-alias path and
  production hardening: `forge test`.

## Demo script (2-3 minutes)

1. Sign up with a passkey (no seed phrase).
2. Show the wallet holding testnet USDG on Robinhood Chain.
3. Deposit USDG, then show the points balance.
4. Pay a bill with points; show the on-chain transaction on the explorer.
5. Close on the deployments table and the multi-chain footprint (EVM, Solana, Stellar, Sui).

## Why Arbitrum and USDG

Low fees make small remittances and bill payments viable, and Robinhood Chain (an Arbitrum Orbit L2)
reaches a large retail audience. USDG is a regulated Paxos stablecoin, which suits payment flows
where recipients need trust in the asset.

## Roadmap (grant milestones)

1. Verify contracts on Arbiscan and publish an independent review.
2. Move ownership to a multisig and the quote signer to a managed key (HSM/KMS).
3. Pilot with one bill-payment partner on Arbitrum One with capped volume.
4. Open the recipient flow to additional corridors.

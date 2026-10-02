# TakumiPay smart contract (Arbitrum submission)

> Part of the TakumiPay submission to the Arbitrum Open House Singapore Online Buildathon. Start at the hub: **[https://github.com/Planckify-Labs/arbitrum-submission](https://github.com/Planckify-Labs/arbitrum-submission)** (fact sheet, deployments with transaction hashes, known limitations, reproduction commands).

**Role of this repository:** the `TakumiPay` v2.1.0 UUPS contract, Foundry tests and deployment records.

**Chains:** Arbitrum One (42161), Arbitrum Sepolia (421614), Robinhood Chain testnet (46630). **Stablecoin:** Paxos USDG. **License:** GPL-3.0.

## Where to look
- Contract: `evm/src/TakumiPay.sol`
- Design notes: [`evm/README.md`](./evm/README.md)
- Tests: `evm/test/*.t.sol` (178 test functions by grep count; run `cd evm && forge test`)
- Deploy script: `evm/script/DeployTakumiPay.s.sol`
- Deployment records with every config transaction hash: `evm/deployments/42161.json`, `421614.json`, `46630.json`
- Submission notes: `evm/docs/arbitrum-open-house-submission.md`

| Network | Proxy |
|---|---|
| Arbitrum One | `0xdE981573883294dfD35A7F0F399DB7e439E1f56B` |
| Arbitrum Sepolia | `0x2469Bd87e809772f491af0E7847fbf7B62c388ae` |
| Robinhood Chain testnet | `0x479B0843C3e0627f36551660506dEd5b349Fa968` |

Known limitations (backend signer is a public key, single-EOA owner, Arbitrum One not smoke-tested, no audit) are listed in the hub README section 5. `evm/deployments` also holds records for earlier non-Arbitrum deployments (Base Sepolia, Monad, Arc). Solana, Stellar and Sui contracts in this repository are from earlier work and are not part of this submission.

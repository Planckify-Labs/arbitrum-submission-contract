// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockAUSD — open-mint 6-decimal stand-in for Agora's AUSD on Monad TESTNET.
///
/// Why this exists (mobile-app/docs/monad-metropolis-2026-spec.md §6.6 step 2):
/// Agora's testnet AUSD (`0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC`, chain 10143)
/// has a permissioned `mint` and no faucet, so there is no permissionless way to
/// fund a demo wallet with it. The QRIS merchant-settlement rail under test is
/// token-agnostic — what it proves is `processMerchantPayment` settling an
/// arbitrary registered ERC-20 — so a stand-in is honest here. The REAL AUSD
/// contract is exercised on Monad mainnet by the remittance leg.
///
/// `decimals()` is pinned to 6 to match the real token: the backend's fiat
/// conversion and the mobile amount parsing both read `decimals` from the
/// seeded token row, and that row must agree with the contract.
///
/// TESTNET ONLY. Anyone can mint; never deploy this to a mainnet.
contract MockAUSD is ERC20 {
    constructor() ERC20("AUSD", "AUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

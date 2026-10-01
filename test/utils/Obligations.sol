// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoverVault} from "../../src/CoverVault.sol";
import {ICoverVault} from "../../src/interfaces/ICoverVault.sol";

/// @title Obligations
/// @notice Independent recomputation of everything a CoverVault owes (plan U8, I3 new form;
///         design §9.1 "saldo ≥ semua kewajiban"). It never reads the vault's own
///         `_obligations` counter: it rebuilds the liability from the cohort books, the
///         parked payouts and the keeper budget, so a bug that keeps the vault's counter
///         self-consistent while a cohort book drifts (SC-01: a FUNDING withdraw that left
///         phantom capital behind) still shows up as owed > balance.
///
///         Per cohort (anything the underwriters, or LPs through refunds/payouts, can still
///         claim out of that book):
///           book = totalCapital + premiumsCollected − claimsPaid − paidOut
///         - FUNDING: capital not yet at risk (premiums are 0).
///         - ACTIVE / SETTLING: capital + premiums − claims paid so far. Refunds still owed
///           and payouts not yet settled are both inside it (they come out of this book).
///         - SETTLED: the nets of the deposits still in, plus the rounding dust — which
///           stays the cohort's until EVERY deposit has exited (plan "Akuntansi").
///         A SETTLED cohort whose deposits have all exited owes nothing more: its dust has
///         become residual. Then: + Σ parked payouts/refunds (`unclaimed`) + keeper budget.
library Obligations {
    struct Report {
        uint256 balance; // settlement-token balance of the vault
        uint256 owed; // independently recomputed obligations
        uint256 vaultCounter; // the vault's own totalObligations(), for the cross-check
        bool bookUnderflow; // some cohort spent more than it ever held
    }

    /// @param maxCid Highest cohort id that can hold anything (inclusive).
    /// @param holders Every address that can hold an `unclaimed` balance.
    function compute(CoverVault v, uint32 maxCid, address[] memory holders)
        internal
        view
        returns (Report memory r)
    {
        r.balance = v.settlementToken().balanceOf(address(v));
        r.vaultCounter = v.totalObligations();
        for (uint32 cid = 0; cid <= maxCid; cid++) {
            ICoverVault.Cohort memory c = v.cohort(cid);
            if (c.status == ICoverVault.Status.SETTLED && c.remainingPrincipal == 0) continue;
            uint256 assets = uint256(c.totalCapital) + c.premiumsCollected;
            uint256 spent = uint256(c.claimsPaid) + c.paidOut;
            if (spent > assets) {
                r.bookUnderflow = true;
                continue;
            }
            r.owed += assets - spent;
        }
        for (uint256 i = 0; i < holders.length; i++) {
            r.owed += v.unclaimed(holders[i]);
        }
        r.owed += v.keeperBudget();
    }

    /// @notice I3: the vault can pay everything it owes.
    function solvent(Report memory r) internal pure returns (bool) {
        return !r.bookUnderflow && r.balance >= r.owed;
    }
}

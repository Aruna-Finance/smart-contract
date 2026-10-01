// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Calendar
/// @notice Test helper for the v2 cohort calendar (plan "Kalender dan status"):
///         startsAt(n) = anchor + n·(tenor + gap); endsAt(n) = startsAt(n) + tenor;
///         the gap of cohort n is [endsAt(n), startsAt(n+1)).
library Calendar {
    function startsAt(uint64 anchor, uint32 n, uint32 tenor, uint32 gap)
        internal
        pure
        returns (uint64)
    {
        return anchor + uint64(n) * (uint64(tenor) + uint64(gap));
    }

    function endsAt(uint64 anchor, uint32 n, uint32 tenor, uint32 gap)
        internal
        pure
        returns (uint64)
    {
        return startsAt(anchor, n, tenor, gap) + tenor;
    }

    /// @notice End (exclusive) of cohort n's gap, i.e. startsAt(n + 1).
    function gapEnd(uint64 anchor, uint32 n, uint32 tenor, uint32 gap)
        internal
        pure
        returns (uint64)
    {
        return startsAt(anchor, n + 1, tenor, gap);
    }
}

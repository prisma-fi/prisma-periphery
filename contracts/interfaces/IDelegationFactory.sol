// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDelegationFactory {
    function forwardFeePct(
        address claimant,
        address receiver,
        address boostDelegate,
        uint amount,
        uint previousAmount,
        uint totalWeeklyEmissions
    ) external view returns (uint256 feePct);

    function forwardCallback(
        address claimant,
        address receiver,
        address boostDelegate,
        uint amount,
        uint adjustedAmount,
        uint fee,
        uint previousAmount,
        uint totalWeeklyEmissions
    ) external returns (bool success);
}

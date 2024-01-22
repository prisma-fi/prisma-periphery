// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
    @title Prisma Boost Forwarder Callback interface
    @notice Optional callback functions that can be set within `DelegationFactory`
 */
interface IBoostCallback {
    /**
        @notice Get the current fee percent charged to use this boost delegate
        @dev Only called if the feePct is set to `type(uint16).max` when
             enabling delegation within the vault, and `feeCallback` is set within
             `DelegationFactory`.
        @param claimant Address that will perform the claim
        @param receiver Address that will receive the claimed rewards
        @param boostDelegate Address to be used as a boost delegate during the claim
        @param amount Amount to be claimed (before applying boost or fee)
        @param previousAmount Previous amount claimed this week by this contract
        @param totalWeeklyEmissions Total weekly emissions released this week
        @return feePct Fee % charged for claims that use this contracts' delegated boost.
                      Given as a whole number out of 10000. If a claim would be rejected,
                      the preferred return value is `type(uint256).max`.
     */
    function getFeePct(
        address claimant,
        address receiver,
        address boostDelegate,
        uint amount,
        uint previousAmount,
        uint totalWeeklyEmissions
    ) external view returns (uint256 feePct);

    /**
        @notice Callback function for boost delegators
        @dev Only called if `delegateCallback` is set within `DelegationFactory`
        @param claimant Address that performed the claim
        @param receiver Address that is receiving the claimed rewards
        @param boostDelegate Address of the boost delegate used during the claim.
                             THIS ADDRESS CAN BE INCORRECT IF THE VAULT DELEGATION
                             PARAMS ARE MISCONFIGURED. Logic within the function
                             should not rely on it's correctness.
        @param amount Amount being claimed (before applying boost or fee)
        @param adjustedAmount Actual amount received by `claimant`
        @param fee Fee amount paid by `claimant`
        @param previousAmount Previous amount claimed this week by this contract
        @param totalWeeklyEmissions Total weekly emissions released this week
     */
    function delegateCallback(
        address claimant,
        address receiver,
        address boostDelegate,
        uint amount,
        uint adjustedAmount,
        uint fee,
        uint previousAmount,
        uint totalWeeklyEmissions
    ) external returns (bool success);

    /**
        @notice Callback to the reward receiver upon a successful reward claim
        @dev Only called if `receiverCallback` is set within `DelegationFactory`.
     */
    function receiverCallback(address claimant, address receiver, uint amount) external returns (bool success);
}

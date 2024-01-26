// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IDiscountCalculator {
    /**
     * @notice Calculates collateral's discounted price
     * @param amountPaid Amount paid by the pool during liquidations
     * @param marketValue Collateral's current market value
     * @return cost Cost to acquire collateral
     * @return retainedGain Gain retained by this contract upon sale
     */
    function calculateDiscountedPrice(
        uint256 amountPaid,
        uint256 marketValue
    ) external view returns (uint256 cost, uint256 retainedGain);
}

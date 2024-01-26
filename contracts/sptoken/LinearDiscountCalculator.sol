// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;
import { IStabilityPool } from "../interfaces/IStabilityPool.sol";
import { IPriceFeed } from "../interfaces/IPriceFeed.sol";
import "../dependencies/PrismaOwnable.sol";
import "../interfaces/ITroveManager.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IDiscountCalculator.sol";

/**
    @title Linear Discount Calculator
    @notice Discount calculator with a configurable linear curve. Discount multipliers can be assigned to
            three configurable regions defined by 2 cutoff points.
 */
contract LinearDiscountCalculator is PrismaOwnable, IDiscountCalculator {
    struct DiscountCurveParams {
        uint16 fastDiscountCutoff; // level of gain where the variable discount starts
        uint16 terminalDiscountCutoff; // level of gain where the fixed discount starts
        uint96 fastDiscountMultiplier; // multiplier for the fast discount interval
        uint96 terminalDiscountMultiplier; // multiplier for the terminal discount interval
    }

    uint256 public constant Y_AXIS_UNIT = 1e18;
    uint256 public constant BPS_MULTIPLIER = 1e4;

    DiscountCurveParams public curveParams;

    event CurveParamsSet(
        uint256 fastDiscountCutoff,
        uint256 terminalDiscountCutoff,
        uint256 fastDiscount,
        uint256 terminalDiscount
    );

    constructor(address _prismaCore) PrismaOwnable(_prismaCore) {
        //[0%, 3%) Sell at market price
        //[3%, 10%] Sell at 3% discount
        //(10%, inf) Sell at 1% discount
        curveParams = DiscountCurveParams({
            fastDiscountCutoff: uint16(10300),
            terminalDiscountCutoff: uint16(11000),
            fastDiscountMultiplier: uint96(Y_AXIS_UNIT - 3e16),
            terminalDiscountMultiplier: uint96(Y_AXIS_UNIT - 1e16)
        });
        emit CurveParamsSet(10300, 11000, 3e16, 1e16);
    }

    /**
        @notice Set params for the discount curve
        @dev x values are gains levels % expressed in bps (e.g. 6% gain is 10060)
             y values are price multipliers % with 18 digits (e.g 1.1*10^18 is 110% )
        @param fastDiscountCutoff Gain cutoff where the variable discount region starts
        @param terminalDiscountCutoff Gain cutoff where the variable discount region ends
        @param fastDiscount Amount of discount compared to the market price when approaching break-even
        @param terminalDiscount Amount of discount compared to the market price when in deep profit
     */
    function setDiscountParams(
        uint256 fastDiscountCutoff,
        uint256 terminalDiscountCutoff,
        uint256 fastDiscount,
        uint256 terminalDiscount
    ) external onlyOwner {
        require(
            fastDiscountCutoff > 9999 && fastDiscountCutoff < terminalDiscountCutoff,
            "Invalid fast discount cutoff"
        );
        require(fastDiscount < Y_AXIS_UNIT, "Invalid fast discount");
        require(terminalDiscount <= fastDiscount, "Invalid terminal discount");

        curveParams = DiscountCurveParams({
            fastDiscountCutoff: uint16(fastDiscountCutoff),
            terminalDiscountCutoff: uint16(terminalDiscountCutoff),
            fastDiscountMultiplier: uint96(Y_AXIS_UNIT - fastDiscount),
            terminalDiscountMultiplier: uint96(Y_AXIS_UNIT - terminalDiscount)
        });
        emit CurveParamsSet(fastDiscountCutoff, terminalDiscountCutoff, fastDiscount, terminalDiscount);
    }

    ///@inheritdoc IDiscountCalculator
    function calculateDiscountedPrice(
        uint256 amountPaid,
        uint256 marketValue
    ) public view returns (uint256 cost, uint256 retainedGain) {
        DiscountCurveParams memory params = curveParams;

        // Express gain in bps e.g. 11100 represents 11% gain over the cost basis
        uint256 gainPct = ((BPS_MULTIPLIER * marketValue) / amountPaid);
        if (gainPct < params.fastDiscountCutoff) {
            // This branch covers also the case of capital losses (see burn mechanism for mitigation)
            cost = amountPaid;
        } else {
            uint256 multiplier = gainPct > params.terminalDiscountCutoff
                ? params.terminalDiscountMultiplier
                : params.fastDiscountMultiplier;
            cost = (marketValue * multiplier) / 1e18; // bring it back to 18 decimals
            cost = cost < amountPaid ? amountPaid : cost; // 100% is the cost floor regardless of curve values
        }
        retainedGain = cost - amountPaid;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "../interfaces/IForwarder.sol";
import "../interfaces/IDelegationFactory.sol";

contract Forwarder is IForwarder {
    address public boostDelegate;
    address public immutable vault;
    IDelegationFactory public immutable factory;

    constructor(address _vault, IDelegationFactory _factory) {
        vault = _vault;
        factory = _factory;
    }

    function initialize(address _delegate) external returns (bool) {
        require(msg.sender == address(factory));
        boostDelegate = _delegate;

        return true;
    }

    function getFeePct(
        address claimant,
        address receiver,
        uint amount,
        uint previousAmount,
        uint totalWeeklyEmissions
    ) external view returns (uint256 feePct) {
        return factory.forwardFeePct(claimant, receiver, boostDelegate, amount, previousAmount, totalWeeklyEmissions);
    }

    function delegatedBoostCallback(
        address claimant,
        address receiver,
        uint amount,
        uint adjustedAmount,
        uint fee,
        uint previousAmount,
        uint totalWeeklyEmissions
    ) external returns (bool success) {
        require(msg.sender == vault);
        factory.forwardCallback(
            claimant,
            receiver,
            boostDelegate,
            amount,
            adjustedAmount,
            fee,
            previousAmount,
            totalWeeklyEmissions
        );
        return true;
    }
}

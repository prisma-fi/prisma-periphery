// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../interfaces/IBoostCallback.sol";
import "../interfaces/IDelegationFactory.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IForwarder.sol";
import "../dependencies/DelegatedOps.sol";

contract DelegationFactory is IDelegationFactory, DelegatedOps {
    using Clones for address;

    IPrismaVault public immutable vault;
    address public immutable forwarderImplementation;

    mapping(address => address) public forwarder;
    mapping(address delegate => IBoostCallback) public feeCallback;
    mapping(address delegate => IBoostCallback) public delegateCallback;
    mapping(address receiver => IBoostCallback) public receiverCallback;

    event ForwarderDeployed(address boostDelegate, address forwarder);
    event ForwarderConfigured(
        address indexed boostDelegate,
        address feeCallback,
        address delegateCallback,
        address receiverCallback
    );

    constructor(IPrismaVault _vault, address _fwdImplementation) {
        vault = _vault;
        forwarderImplementation = _fwdImplementation;
    }

    /**
        @notice Configure boost delegate forwarder for the caller
        @dev Deploys a new `Forwarder` contract on the first call from a new address.
             To activate the forwarder, the caller must set it as their delegate callback
             with `Vault.setBoostDelegationParams`.
        @param _feeCallback If set, the forwarder calls `IBoostCallback.getFeePct` at this address
                            to retrieve the delegation fee percent. You must additionally set the
                            `feePct` to `type(uint16).max` when configuring boost delegation params
                            in the vault.
        @param _delegateCallback If set, the forwarder calls `IBoostCallback.delegateCallback` at this
                                address when `msg.sender` is specified as `boostDelegate` during a call
                                to `Vault.batchClaimRewards`
        @param _receiverCallback If set, the forwarder calls `IBoostCallback.receiverCallback` at this
                                address when `msg.sender` is specified as `receiver` during a call
                                to `Vault.batchClaimRewards`.
     */
    function configureForwarder(
        address account,
        address _feeCallback,
        address _delegateCallback,
        address _receiverCallback
    ) external callerOrDelegated(account) returns (bool) {
        if (forwarder[account] == address(0)) {
            address fwd = forwarderImplementation.cloneDeterministic(bytes32(bytes20(account)));
            IForwarder(fwd).initialize(account);
            forwarder[account] = fwd;
            emit ForwarderDeployed(account, fwd);
        }

        feeCallback[account] = IBoostCallback(_feeCallback);
        delegateCallback[account] = IBoostCallback(_delegateCallback);
        receiverCallback[account] = IBoostCallback(_receiverCallback);

        emit ForwarderConfigured(account, _feeCallback, _delegateCallback, _receiverCallback);

        return true;
    }

    /**
        @notice Returns `true` if the given `boostDelegate` has set their forwarder
                as the callback address within the vault.
        @dev Receivers that have configured a callback should only be used in combination
             with delegates that have an active forwarder, otherwise the receiver callback
             will not occur.
     */
    function isForwarderActive(address boostDelegate) external view returns (bool) {
        if (forwarder[boostDelegate] == address(0)) return false;
        (, , address callback) = vault.boostDelegation(boostDelegate);
        return callback == forwarder[boostDelegate];
    }

    /**
        @notice Forwards a call to the fee callback set by `boostDelegate`
     */
    function forwardFeePct(
        address claimant,
        address receiver,
        address boostDelegate,
        uint amount,
        uint previousAmount,
        uint totalWeeklyEmissions
    ) external view returns (uint256 feePct) {
        return
            feeCallback[boostDelegate].getFeePct(
                claimant,
                receiver,
                boostDelegate,
                amount,
                previousAmount,
                totalWeeklyEmissions
            );
    }

    /**
        @notice Forwards delegate and receiver callbacks
     */
    function forwardCallback(
        address claimant,
        address receiver,
        address boostDelegate,
        uint amount,
        uint adjustedAmount,
        uint fee,
        uint previousAmount,
        uint totalWeeklyEmissions
    ) external returns (bool success) {
        require(msg.sender == forwarder[boostDelegate], "!forwarder");

        IBoostCallback callback = delegateCallback[boostDelegate];
        if (address(callback) != address(0)) {
            callback.delegateCallback(
                claimant,
                receiver,
                boostDelegate,
                amount,
                adjustedAmount,
                fee,
                previousAmount,
                totalWeeklyEmissions
            );
        }

        callback = receiverCallback[receiver];
        if (address(callback) != address(0)) {
            callback.receiverCallback(claimant, receiver, adjustedAmount);
        }

        return true;
    }
}

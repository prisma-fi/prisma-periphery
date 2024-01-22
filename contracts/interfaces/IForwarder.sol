// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IBoostDelegate.sol";

interface IForwarder is IBoostDelegate {
    function initialize(address _delegate) external returns (bool);
}

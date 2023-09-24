// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
    @notice Common interface for Prisma's `CurveDepositToken` and `ConvexDepositToken`
 */
interface IDepositToken {
    function emissionId() external view returns (uint256);

    function lpToken() external view returns (address);

    function deposit(address receiver, uint256 amount) external returns (bool);

    function withdraw(address receiver, uint256 amount) external returns (bool);
}

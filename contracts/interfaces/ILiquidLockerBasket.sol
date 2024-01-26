// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiquidLockerBasket is IERC20 {
    function getNextLocker() external view returns (IERC20 token, address receiver);

    function mint(uint256 amount) external returns (bool);
}

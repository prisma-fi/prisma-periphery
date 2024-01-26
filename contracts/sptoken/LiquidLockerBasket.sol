//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../dependencies/PrismaOwnable.sol";

/**
    @title  Prisma Liquid Locker Basket
    @notice Token which wraps a basket of Prisma Liquid Lockers.
            The aim of this contract is to simplify liquid locker claims in the Prisma SP token and to
            have a fair and neutral management of such claims.
            This token supply is increased by transferring the required liquid locker amount and minting
            the same amount of the basket. This implies a 1:1 relationship between the basket and its constituents.
            Liquid locker selection is performed in a round-robin fashion among enabled liquid lockers.
            Only the Prisma SP Token contract is authorized for minting.
            Redemptions can be performed by any token holders and yield a proportional set of constituent liquid lockers.
 */
contract LiquidLockerBasket is ERC20, PrismaOwnable {
    using SafeERC20 for IERC20;

    address public immutable SPToken;

    LiquidLocker[] public liquidLockers;
    uint256 public lockerIndex;

    struct LiquidLocker {
        IERC20 token;
        uint96 balance;
        address receiver;
        bool mintActive;
        bool redeemActive;
    }

    struct NewLocker {
        IERC20 token;
        address receiver;
    }

    event LiquidLockersAdded(NewLocker[] newLockers);
    event LiquidLockerConfigured(uint256 index, address receiver, bool mintActive, bool redeemActive);

    constructor(
        address _prismaCore,
        address _SPToken,
        NewLocker[] memory initialLockers
    ) PrismaOwnable(_prismaCore) ERC20("PRISMA Liquid Locker Basket", "PLLB") {
        SPToken = _SPToken;
        addLiquidLockers(initialLockers);
    }

    /**
     * @notice              It adds liquid lockers for rewards
     * @param newLockers    Liquid locker token to add
     * @dev Assumption: Duplicate checks are done client side.
     */
    function addLiquidLockers(NewLocker[] memory newLockers) public onlyOwner {
        uint256 length = newLockers.length;
        for (uint i = 0; i < length; i++) {
            liquidLockers.push(LiquidLocker(newLockers[i].token, 0, newLockers[i].receiver, true, true));
        }
        emit LiquidLockersAdded(newLockers);
    }

    /**
        @notice             Configures a liquid locker parameters
        @dev                At least one liquid locker must be active at any time
        @param index        Index of the liquid locker to modify
        @param receiver     Receiver for the liquid locker to modify
        @param mintActive   If false, the locker will not be included in the round-robin
                            mint sequence. Any existing balance will continue to be distributed
                            during redemptions.
        @param redeemActive If false, transfers of this token will be skipped during redemptions.
                            Useful if a liquid locker has suffered a critical exploit and the
                            token is no longer transferrable.
     */
    function configureLiquidLocker(
        uint256 index,
        address receiver,
        bool mintActive,
        bool redeemActive
    ) external onlyOwner {
        LiquidLocker storage ll = liquidLockers[index];
        ll.receiver = receiver;
        ll.mintActive = mintActive;
        ll.redeemActive = redeemActive;
        uint256 length = liquidLockers.length;
        uint256 i;
        for (i; i < length; ) {
            if (liquidLockers[i].mintActive) break;
            unchecked {
                ++i;
            }
        }
        require(i < length, "Cannot disable all liquid lockers");
        emit LiquidLockerConfigured(index, receiver, mintActive, redeemActive);
    }

    /**
        @notice Returns liquid locker for the next mint operation
        @return token Address of the next liquid locker token
        @return receiver Receiver for the next liquid locker token
     */
    function getNextLocker() external view returns (IERC20 token, address receiver) {
        LiquidLocker memory locker = liquidLockers[lockerIndex];
        return (locker.token, locker.receiver);
    }

    /**
        @notice Returns the number of liquid locker included in the basket
        @dev    The count can include disabled liquid locker
        @return Number of liquid lockers in the basket
     */
    function liquidLockersCount() external view returns (uint256) {
        return liquidLockers.length;
    }

    /**
        @notice         Mints the specified amount of basket token to the sender
        @param amount   Amount to mint
     */
    function mint(uint256 amount) external returns (bool) {
        require(msg.sender == SPToken, "Only SPToken");
        _mint(SPToken, amount);

        uint256 index = lockerIndex;
        LiquidLocker storage ll = liquidLockers[index];
        uint96 expectedBalance = uint96(ll.balance + amount);
        uint256 currentBalance = ll.token.balanceOf(address(this));
        require(currentBalance >= expectedBalance, "Insufficient Amount");
        ll.balance = expectedBalance;
        uint256 lastIndex = liquidLockers.length - 1;
        while (true) {
            if (index == lastIndex) index = 0;
            else index++;
            if (liquidLockers[index].mintActive) break;
        }
        lockerIndex = index;
        return true;
    }

    /**
        @notice             Redeems the specified amount of basket token for a
                            proportional set of constituent liquid lockers
        @param receiver     Receiver of the tokens
        @param amount       Amount to redeem
     */
    function redeem(address receiver, uint256 amount) external returns (bool) {
        uint256 supply = totalSupply();
        _burn(msg.sender, amount);

        uint256 loopEnd = liquidLockers.length;
        for (uint256 i; i < loopEnd; ) {
            IERC20 token = liquidLockers[i].token;
            uint256 balance = liquidLockers[i].balance;

            if (balance > 0) {
                uint256 withdrawn = (amount * balance) / supply;

                // reduce the internal balance even when `redeemActive` is false
                // so that internal accounting remains 1:1
                liquidLockers[i].balance = uint96(balance - withdrawn);
                if (liquidLockers[i].redeemActive) token.safeTransfer(receiver, withdrawn);
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /**
        @notice             Sweeps liquid lockers not owned by this token
        @param index        Index of the token to sweep
        @param receiver     Receiver of the token
     */
    function sweep(uint256 index, address receiver) external onlyOwner {
        IERC20 token = liquidLockers[index].token;
        uint256 balance = liquidLockers[index].balance;
        uint256 amount = token.balanceOf(address(this)) - balance;
        require(amount > 0, "Nothing to sweep");
        token.safeTransfer(receiver, amount);
    }
}

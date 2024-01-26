// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;
import { IStabilityPool } from "../interfaces/IStabilityPool.sol";
import { IPriceFeed } from "../interfaces/IPriceFeed.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "../dependencies/PrismaOwnable.sol";
import "../interfaces/ITroveManager.sol";
import "../interfaces/ILiquidLockerBasket.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IVault.sol";
import "./LinearDiscountCalculator.sol";

/**
    @title Prisma Stability Pool Deposit Wrapper
    @notice Standard ERC4626 interface around a deposit into the Prisma Stability Pool.
            This wrapper aims to passively unwind collateral acquired during liquidations.
            Collateral is sold at a variable discount compared to market price, according to a
            configurable linear curve.
            Prisma rewards are distributed to token holders with handling of locked rewards using
            cvxPrisma. Rewards boosting is provided by CVX when favourable.
 */
contract SPToken is ERC4626, PrismaOwnable {
    using Math for uint256;

    struct DiscountCurveParams {
        uint16 fastDiscountCutoff; // level of gain where the variable discount starts
        uint16 terminalDiscountCutoff; // level of gain where the fixed discount starts
        uint96 fastDiscountMultiplier; // multiplier for the fast discount interval
        uint96 terminalDiscountMultiplier; // multiplier for the terminal discount interval
        bool externalCalculator; // True if there is an external calculator
    }

    uint256 public constant PLLB_INDEX = 0;
    uint256 public constant PRISMA_INDEX = 1;
    uint256 public constant MKUSD_INDEX = 2;
    uint256 public constant REWARD_DURATION = 1 weeks;
    uint256 public constant CARRY_FEES_IN_BPS = 2000; //20% of the gains is paid as fees;

    IStabilityPool public immutable sp;
    IFactory public immutable factory;
    IPrismaVault public immutable vault;
    IERC20 public immutable prisma;
    ILiquidLockerBasket public immutable pllb;

    address public assetRewardsAccount;
    uint256 public weeklyAssetRewards;
    mapping(uint256 index => address collateral) public collateralByIndex;
    mapping(address collateral => ITroveManager troveManager) public troveManagers;
    uint256 public deposits;
    address[] public boostDelegates;
    uint8 public numberOfLiquidLockers;
    uint32 public lastUpdate;
    uint32 public periodFinish;
    address[3] public liquidLockerReceivers;
    uint256[3] public rewardIntegral;
    uint128[3] public rewardRates;

    mapping(address => uint256[3]) public rewardIntegralFor;
    mapping(address => uint128[3]) public storedPendingReward;
    mapping(address claimant => mapping(address caller => bool)) public canClaimFor;
    IDiscountCalculator public discountCalculator;

    event DiscountCalculatorSet(IDiscountCalculator externalCalculator);
    event AssetRewardsConfig(address assetRewardsAccount, uint256 weeklyAssetRewards);
    event ApprovedClaimerSet(address indexed account, address indexed caller, bool status);
    event CollateralSold(uint256 cost, uint256 retainedGain, uint256 fees, uint256[] collateralIndexes);
    event CollateralsSynched(address[] collaterals);
    event RewardsClaimed(address claimant, address receiver, uint128[3] rewards);
    event BoostDelegatesSet(address[] delegates);
    event LiquidLockersAdded(address[] receivers, IERC20[] tokens);
    event LiquidLockerRemoved(uint256 index);
    event AssetRewardsDeposited(uint256 amount);
    event TreasuryAssetsDeposited(uint256 amount);
    event TreasuryAssetsWithdrawn(uint256 amount);
    event RewardFetched(IERC20 token, uint256 amount);

    constructor(
        IERC20 debtToken,
        IStabilityPool _sp,
        IFactory _factory,
        address _prismaCore,
        IPrismaVault _vault,
        IERC20 _prisma,
        ILiquidLockerBasket _pllb
    ) PrismaOwnable(_prismaCore) ERC4626(debtToken) ERC20("Prisma Stability Token", "smkUSD") {
        sp = _sp;
        factory = _factory;
        vault = _vault;
        prisma = _prisma;
        pllb = _pllb;
        discountCalculator = new LinearDiscountCalculator(_prismaCore);
        syncCollaterals();
    }

    /**
        @notice Sets a discount calculator
        @param _discountCalculator address of the calculator to use
     */
    function setDiscountCalculator(IDiscountCalculator _discountCalculator) public onlyOwner {
        discountCalculator = _discountCalculator;
        emit DiscountCalculatorSet(_discountCalculator);
    }

    /**
        @notice Configs asset rewards
        @param _assetRewardsAccount address of account
        @param _weeklyAssetRewards weekly amount of rewards
     */
    function configAssetRewards(address _assetRewardsAccount, uint256 _weeklyAssetRewards) public onlyOwner {
        assetRewardsAccount = _assetRewardsAccount;
        weeklyAssetRewards = _weeklyAssetRewards;
        emit AssetRewardsConfig(_assetRewardsAccount, _weeklyAssetRewards);
    }

    /**
        @notice Approve an account to claim rewards on behalf on another
        @param claimant address of the account to claim for
        @param caller address that can claim on behalf
        @param canClaim true if the caller is approved
     */
    function setClaimForApproval(address claimant, address caller, bool canClaim) external {
        require(claimant == msg.sender || msg.sender == owner(), "Unauthorized");
        canClaimFor[claimant][caller] = canClaim;
        emit ApprovedClaimerSet(claimant, caller, canClaim);
    }

    /**
     * @notice It adds optional boost delegates
     * @param _boostDelegates Addresses of the boost delegates
     */
    function setBoostDelegates(address[] calldata _boostDelegates) external onlyOwner {
        boostDelegates = _boostDelegates;
        emit BoostDelegatesSet(_boostDelegates);
    }

    /// @dev Cloned from the parent contract and added integrals updating
    function _transfer(address from, address to, uint256 amount) internal virtual override {
        uint256 supply = totalSupply();
        _updateIntegrals(from, supply);
        _updateIntegrals(to, supply);
        super._transfer(from, to, amount);
    }

    function totalAssets() public view virtual override returns (uint256) {
        // This is eventually consistent until collateral gains are sold
        // We do not allow balance changing operations until all collateral is sold
        // therefore there is no inconsistency when calculating shares
        return deposits;
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        _checkIfLocked();
        _updateIntegrals(receiver, totalSupply());
        if (block.timestamp / 1 weeks >= periodFinish / 1 weeks) _fetchRewards(address(0));
        super._deposit(caller, receiver, assets, shares);
        sp.provideToSP(assets);
        deposits += assets;
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        _checkIfLocked();
        _updateIntegrals(owner, totalSupply());
        if (block.timestamp / 1 weeks >= periodFinish / 1 weeks) _fetchRewards(address(0));
        sp.withdrawFromSP(assets);
        deposits -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @notice Burns shares and reduce cost basis for collateral
     * @dev This is used to allow unblocking of the token when the collateral
     *      accrued is trading below cost.
     *      Most likely to be used by the DAO.
     */
    function burn(uint256 shares) external {
        _updateIntegrals(msg.sender, totalSupply());
        uint256 _deposits = deposits;
        _deposits -= convertToAssets(shares);
        require(_deposits >= sp.getCompoundedDebtDeposit(address(this)), "Burning too much");
        deposits = _deposits;
        _burn(msg.sender, shares);
    }

    function _checkIfLocked() internal view {
        uint256 currentDeposits = sp.getCompoundedDebtDeposit(address(this));
        require(currentDeposits == deposits, "Locked until collateral sold");
    }

    /**
     * @notice Offers collateral for sale at a price determined by the discount curve.
     *         Sale price is never below original cost.
     */
    function buyAllCollaterals() external {
        (
            uint256 cost,
            uint256 retainedGain,
            uint256 currentDeposits,
            uint256[] memory claimIndexes
        ) = _priceCollateral();
        uint256 fees = (retainedGain * CARRY_FEES_IN_BPS) / 10000;
        IERC20(asset()).transferFrom(msg.sender, address(this), cost);
        if (fees > 0) _depositFees(fees, currentDeposits + cost - fees, PRISMA_CORE.feeReceiver());
        sp.provideToSP(cost);
        deposits = currentDeposits + cost;
        sp.claimCollateralGains(msg.sender, claimIndexes);
        emit CollateralSold(cost, retainedGain, fees, claimIndexes);
    }

    function _depositFees(
        uint256 assets,
        uint256 totalAssetsUpdated,
        address receiver
    ) internal returns (uint256 shares) {
        uint256 supply = totalSupply();
        _updateIntegrals(receiver, supply);
        // fee shares are calculated as if cost - fees were already accrued to current shareholders
        shares = assets.mulDiv(supply, totalAssetsUpdated, Math.Rounding.Down);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function _priceCollateral()
        internal
        returns (uint256 cost, uint256 retainedGain, uint256 currentDeposits, uint256[] memory claimIndexes)
    {
        uint256[] memory collateralGains = sp.getDepositorCollateralGain(address(this));
        uint256 loopEnd = collateralGains.length;
        claimIndexes = new uint256[](loopEnd);
        uint256 claims = 0;
        uint256 marketValue = 0;
        for (uint256 i; i < loopEnd; ) {
            uint256 gain = collateralGains[i];
            if (gain > 0) {
                address collateral = collateralByIndex[i];
                uint256 price = troveManagers[collateral].fetchPrice();
                marketValue += price * collateralGains[i];
                claimIndexes[claims++] = i;
            }
            unchecked {
                ++i;
            }
        }
        assembly {
            mstore(claimIndexes, claims)
        }
        currentDeposits = sp.getCompoundedDebtDeposit(address(this));
        uint256 deltaDeposit = deposits - currentDeposits;
        require(deltaDeposit > 0, "Collateral not available"); // Abort sale if no deposit was burned
        (cost, retainedGain) = discountCalculator.calculateDiscountedPrice(deltaDeposit, marketValue / 1e18);
    }

    /**
     * @notice Returns true if deposits and withdrawals are locked
     * @return Lock status
     */
    function isLocked() external view returns (bool) {
        return sp.getCompoundedDebtDeposit(address(this)) != deposits;
    }

    /**
     * @notice Synchs collaterals with the Stability Pool
     * @dev To be called when new collaterals or price feeds are added
     */
    function syncCollaterals() public {
        uint256 length = factory.troveManagerCount();
        address[2][] memory troveManagersAndCollaterals = new address[2][](length);
        address[] memory uniqueCollaterals = new address[](length);
        uint256 collateralCount;
        for (uint i = 0; i < length; i++) {
            address troveManager = factory.troveManagers(i);
            address collateral = ITroveManager(troveManager).collateralToken();
            troveManagersAndCollaterals[i] = [troveManager, collateral];
            for (uint x = 0; x < length; x++) {
                if (uniqueCollaterals[x] == collateral) break;
                if (uniqueCollaterals[x] == address(0)) {
                    uniqueCollaterals[x] = collateral;
                    collateralCount++;
                    break;
                }
            }
        }
        for (uint i = 0; i < collateralCount; i++) {
            address collateral = uniqueCollaterals[i];
            uint256 index = sp.indexByCollateral(collateral) - 1;
            collateralByIndex[index] = collateral;
            address troveManager;

            for (uint x = 0; x < length; x++) {
                if (troveManagersAndCollaterals[x][1] == uniqueCollaterals[i]) {
                    troveManager = troveManagersAndCollaterals[x][0];
                }
            }
            troveManagers[collateral] = ITroveManager(troveManager);
        }
        assembly {
            mstore(uniqueCollaterals, collateralCount)
        }
        emit CollateralsSynched(uniqueCollaterals);
    }

    /**
     * @notice Claims rewards for the account and sends them to the receiver
     * @dev This can only be called by an approved account, used for SC accounts (LPs, etc)
     * @param account Account to claim for
     * @param receiver Receiver of the rewards
     * @return rewards Rewards claimed
     */
    function claimRewardsFor(address account, address receiver) external returns (uint128[3] memory rewards) {
        require(canClaimFor[account][msg.sender], "Unauthorized");
        return _claimRewards(account, receiver);
    }

    /**
     * @notice Claims rewards for the sender and sends them to the receiver
     * @param receiver Receiver of the rewards
     * @return rewards Rewards claimed
     */
    function claimRewards(address receiver) external returns (uint128[3] memory rewards) {
        return _claimRewards(msg.sender, receiver);
    }

    function _claimRewards(address account, address receiver) internal returns (uint128[3] memory rewards) {
        _updateIntegrals(account, totalSupply());
        rewards = storedPendingReward[account];
        delete storedPendingReward[account];

        uint256 rewardAmount;
        rewardAmount = rewards[PLLB_INDEX];
        if (rewardAmount > 0) pllb.transfer(receiver, rewardAmount);
        rewardAmount = rewards[MKUSD_INDEX];
        if (rewardAmount > 0) IERC20(asset()).transfer(receiver, rewardAmount);
        if (vault.lockWeeks() == 0) {
            rewardAmount = rewards[PRISMA_INDEX];
            if (rewardAmount > 0) prisma.transfer(receiver, rewardAmount);
        }
        emit RewardsClaimed(account, receiver, rewards);
    }

    /**
     * @notice Queries claimable rewards for an account
     * @param account Account to query for
     * @return amounts Reward amounts claimable
     */
    function claimableRewards(address account) external view returns (uint256[3] memory amounts) {
        uint256 updated = periodFinish;
        if (updated > block.timestamp) updated = block.timestamp;
        uint256 duration = updated - lastUpdate;
        uint256 balance = balanceOf(account);
        uint256 supply = totalSupply();
        amounts[PLLB_INDEX] = _claimableReward(PLLB_INDEX, supply, duration, account, balance);
        amounts[MKUSD_INDEX] = _claimableReward(MKUSD_INDEX, supply, duration, account, balance);
        if (vault.lockWeeks() == 0) {
            amounts[PRISMA_INDEX] = _claimableReward(PRISMA_INDEX, supply, duration, account, balance);
        }
    }

    function _claimableReward(
        uint256 i,
        uint256 supply,
        uint256 duration,
        address account,
        uint256 balance
    ) internal view returns (uint256) {
        uint256 integral = rewardIntegral[i];
        if (supply > 0) {
            integral += (duration * rewardRates[i] * 1e18) / supply;
        }
        uint256 integralFor = rewardIntegralFor[account][i];
        return storedPendingReward[account][i] + ((balance * (integral - integralFor)) / 1e18);
    }

    function _updateIntegrals(address account, uint256 supply) internal {
        uint256 updated = periodFinish;
        if (updated > block.timestamp) updated = block.timestamp;
        uint256 duration = updated - lastUpdate;
        if (duration > 0) lastUpdate = uint32(updated);
        uint256 balance = balanceOf(account);
        _updateIntegral(PLLB_INDEX, supply, duration, account, balance);
        _updateIntegral(MKUSD_INDEX, supply, duration, account, balance);
        if (vault.lockWeeks() == 0) {
            _updateIntegral(PRISMA_INDEX, supply, duration, account, balance);
        }
    }

    function _updateIntegral(uint256 i, uint256 supply, uint256 duration, address account, uint256 balance) internal {
        uint256 integral = rewardIntegral[i];
        uint256 rewardRate = rewardRates[i];
        if (duration > 0 && supply > 0 && rewardRate > 0) {
            integral += (duration * rewardRate * 1e18) / supply;
            rewardIntegral[i] = integral;
        }
        if (account != address(0)) {
            uint256 integralFor = rewardIntegralFor[account][i];
            if (integral > integralFor) {
                storedPendingReward[account][i] += uint128((balance * (integral - integralFor)) / 1e18);
                rewardIntegralFor[account][i] = integral;
            }
        }
    }

    /**
     * @notice Fetches rewards accrued by depositing in the Stability Pool
     */
    function fetchRewards(address extraDelegate) external {
        require(block.timestamp / 1 weeks >= periodFinish / 1 weeks, "Can only fetch once per week");
        if (extraDelegate != address(0)) {
            (, , address callback) = vault.boostDelegation(extraDelegate);
            require(callback == address(0), "Delegate cannot have callback");
        }
        _updateIntegrals(address(0), totalSupply());
        _fetchRewards(extraDelegate);
    }

    function _fetchRewards(address extraDelegate) internal {
        bool locked = vault.lockWeeks() > 0;
        address delegate;
        IERC20 rewardToken;
        address receiver;
        if (locked) {
            (rewardToken, delegate) = pllb.getNextLocker();
            receiver = delegate;
        } else {
            receiver = address(this);
            delegate = _getBestBoostDelegate(extraDelegate);
            rewardToken = prisma;
        }

        uint256 rewardAmount;
        address[] memory claimlist = new address[](1);
        claimlist[0] = address(sp);
        uint256 balanceBefore = rewardToken.balanceOf(address(this));
        /**
         *
         * There is an explicit trust assumption on delegate callback for re-entrancy
         * - External delegates cannot have callbacks
         * - Approved delegates must be vetted before being added
         *
         * */
        try vault.batchClaimRewards(receiver, delegate, claimlist, 10000) returns (bool) {
            rewardAmount = rewardToken.balanceOf(address(this)) - balanceBefore;
            uint256 _periodFinish = periodFinish;
            uint256 remaining = block.timestamp < _periodFinish ? _periodFinish - block.timestamp : 0;
            uint256 _weeklyAssetRewards = weeklyAssetRewards;
            if (_weeklyAssetRewards > 0) {
                IERC20(asset()).transferFrom(assetRewardsAccount, address(this), _weeklyAssetRewards);
                emit RewardFetched(IERC20(asset()), _weeklyAssetRewards);
            }
            uint256 mkUSDAmount = _weeklyAssetRewards + remaining * rewardRates[MKUSD_INDEX];
            uint256 pllbAmount = remaining * rewardRates[PLLB_INDEX];
            uint256 prismaAmount = remaining * rewardRates[PRISMA_INDEX];
            if (locked) {
                rewardToken.transfer(address(pllb), rewardAmount);
                pllb.mint(rewardAmount);
                pllbAmount += rewardAmount;
            } else {
                prismaAmount += rewardAmount;
            }
            rewardRates[PLLB_INDEX] = uint128(pllbAmount / REWARD_DURATION);
            rewardRates[PRISMA_INDEX] = uint128(prismaAmount / REWARD_DURATION);
            rewardRates[MKUSD_INDEX] = uint128(mkUSDAmount / REWARD_DURATION);

            lastUpdate = uint32(block.timestamp);
            periodFinish = uint32(block.timestamp + REWARD_DURATION);
            emit RewardFetched(rewardToken, rewardAmount);
        } catch {}
    }

    function _getBestBoostDelegate(address extraDelegate) internal view returns (address bestDelegate) {
        uint256 highestClaimable = 0;
        address[] memory registeredDelegates = boostDelegates;
        uint256 length = registeredDelegates.length;
        uint256 loopEnd = length + 2;
        for (uint256 i; i < loopEnd; ) {
            address currentDelegate;
            if (i < length) {
                currentDelegate = registeredDelegates[i];
            } else if (i == loopEnd - 2) {
                currentDelegate = address(0);
            } else if (i == loopEnd - 1) {
                if (extraDelegate == address(0)) break; //avoid redundant iteration
                currentDelegate = extraDelegate;
            }
            (uint256 adjustedAmount, uint256 fee) = vault.claimableRewardAfterBoost(
                address(this),
                address(this),
                currentDelegate,
                address(sp)
            );
            uint256 claimableWithCurrentBoost = adjustedAmount - fee;

            if (claimableWithCurrentBoost > highestClaimable) {
                highestClaimable = claimableWithCurrentBoost;
                bestDelegate = currentDelegate;
            }
            unchecked {
                ++i;
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPOOL.sol";
import {WadRayMath} from "aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "aave-v3-core/contracts/protocol/libraries/math/PercentageMath.sol";
import {IPoolDataProvider} from "aave-v3-core/contracts/interfaces/IPoolDataPROVIDER.sol";
import {IPoolAddressesProvider} from "aave-v3-core/contracts/interfaces/IPoolAddressesPROVIDER.sol";
import {ICreditDelegationToken} from "aave-v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {DataTypes} from "aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {IVariableDebtToken} from "aave-v3-core/contracts/interfaces/IVariableDebtToken.sol";
import {IStableDebtToken} from "aave-v3-core/contracts/interfaces/IStableDebtToken.sol";
import {MathUtils} from "aave-v3-core/contracts/protocol/libraries/math/MathUtils.sol";

import "../interfaces/ILiquidityLayer.sol";


/// @title AaveLibrary
/// @notice Reusable helper library for Aave v3: supply, withdraw, borrow, repay, flash loans, and account stats
library AaveLibrary {
    using SafeERC20 for IERC20;


    using WadRayMath   for uint256;
    using PercentageMath for uint256;

    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint16  private constant MAX_BPS = 10_000;   // 100 %

    uint16 private constant REFERRAL_CODE = 0;
    IPoolDataProvider constant AAVE_PROTOCOL_DATA_PROVIDER = IPoolDataProvider(0x14496b405D62c24F91f04Cda1c69Dc526D56fDE5);
    IPool constant POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    function approveAll(address asset) internal {
        IERC20(asset).approve(address(POOL), type(uint256).max);
    }

    /// @notice Supply `amount` of `asset` into Aave
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) internal {
        POOL.supply(asset, amount, onBehalfOf, REFERRAL_CODE);
    }

    /// @notice Withdraw up to `amount` of `asset` from Aave
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) internal returns (uint256) {
        return POOL.withdraw(asset, amount, to);
    }

    /// @notice Borrow `amount` of `asset` from Aave
    /// @param interestRateMode 1 = stable, 2 = variable
    function borrow(
        address asset,
        uint256 amount,
        InterestRateMode interestRateMode,
        address onBehalfOf
    ) internal {
        POOL.borrow(asset, amount, interestRateMode==InterestRateMode.VARIABLE ? 2 : 1, REFERRAL_CODE, onBehalfOf);
    }

    /// @notice Repay `amount` of borrowed `asset` to Aave
    /// @param interestRateMode must match borrow rate mode
    function repay(
        address asset,
        uint256 amount,
        InterestRateMode interestRateMode,
        address onBehalfOf
    ) internal returns (uint256) {
        return POOL.repay(asset, amount, interestRateMode==InterestRateMode.VARIABLE ? 2 : 1, onBehalfOf);
    }

    /// @notice Fetch the aToken address for a given underlying `asset`
    function getATokenAddress(
        address asset
    ) internal view returns (address) {
        (address aToken,,) = AAVE_PROTOCOL_DATA_PROVIDER.getReserveTokensAddresses(asset);
        return aToken;
    }

    function getBebtTokenAddress(
        address asset
    ) internal view returns(address) {
        (,,address valiableDebtToken) = AAVE_PROTOCOL_DATA_PROVIDER.getReserveTokensAddresses(asset);
        return valiableDebtToken;
    }

    /// @notice Get the raw aToken balance of `account`
    function getATokenBalance(
        address asset,
        address account
    ) internal view returns (uint256) {
        return IERC20(getATokenAddress(asset)).balanceOf(account);
    }

    /// @notice Get the health factor for `user` (Ray-scaled)
    function getHealthFactor(
        address user
    ) internal view returns (uint256) {
        (, , , , , uint256 hf) = POOL.getUserAccountData(user);
        return hf;
    }

    /// @notice Get the total debt (base currency, Ray-scaled) for `user`
    function getTotalDebtBase(
        address asset,
        address user
    ) internal view returns (uint256) {
        return IERC20(getBebtTokenAddress(asset)).balanceOf(user);
    }

    function getLTV(address collateralTokenAddr) internal view returns (uint256) {
        (,uint256 ltv,,,,,,,,) = AAVE_PROTOCOL_DATA_PROVIDER.getReserveConfigurationData(collateralTokenAddr);
        return ltv;
    }

    /// @notice Get the current variable borrow rate for an asset
    function getCurrentVariableBorrowRate(address asset) internal view returns (uint256) {
        (,,,,uint256 variableBorrowRate,,,,,,,) = AAVE_PROTOCOL_DATA_PROVIDER.getReserveData(asset);
        return variableBorrowRate;
    }

    function getCurrentFixedBorrowRate(address asset) internal view returns (uint256) {
        (,,,,,uint256 stableBorrowRate,,,,,,) = AAVE_PROTOCOL_DATA_PROVIDER.getReserveData(asset);
        return stableBorrowRate;
    }
    
    /// @notice Get user's current debt balance including interest
    function getUserDebtBalance(address asset, address user, InterestRateMode rateMode) internal view returns (uint256) {
        (,uint256 currentStableDebt,uint256 variableDebt,,,,,,) = AAVE_PROTOCOL_DATA_PROVIDER.getUserReserveData(asset, user);
        if (rateMode == InterestRateMode.VARIABLE) {
            return variableDebt;
        } else {
            return currentStableDebt;
        }
    }
}



contract AaveModule is ILiquidityLayer {
    using AaveLibrary for *;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint16 private constant MAX_BPS = 10_000; // 100 %

    constructor(address[] memory assets) {
        for (uint256 i = 0; i < assets.length; i++) {
            init(assets[i]);
        }
    }

    function init(address asset) internal {
        DataTypes.ReserveData memory r = AaveLibrary.POOL.getReserveData(asset);
        address variableDebtToken = r.variableDebtTokenAddress;
        AaveLibrary.approveAll(asset);
    }

    function supply(address asset, uint256 amount, address onBehalfOf) external override returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        AaveLibrary.supply(asset, amount, onBehalfOf);
        DataTypes.ReserveData memory r = AaveLibrary.POOL.getReserveData(asset);
        return amount.rayDiv(r.liquidityIndex);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        return AaveLibrary.withdraw(asset, amount, to);
    }

    function borrow(address asset, uint256 amount, InterestRateMode interestRateMode, address onBehalfOf) external override returns (uint256 newScaledDebtAmount) {
        AaveLibrary.borrow(asset, amount, interestRateMode, onBehalfOf);
        IERC20(asset).transfer(onBehalfOf, amount);
        DataTypes.ReserveData memory r = AaveLibrary.POOL.getReserveData(asset);
        newScaledDebtAmount = amount.rayDiv(r.variableBorrowIndex);
    }

    function repay(address asset, uint256 amount, InterestRateMode interestRateMode, address onBehalfOf) external override returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        return AaveLibrary.repay(asset, amount, interestRateMode, onBehalfOf);
    }

    function getSupplyBalance(address asset, address user) external view override returns (uint256) {
        return AaveLibrary.getATokenBalance(asset, user);
    }

    function getDebtBalance(address asset, address user, InterestRateMode rateMode) external view override returns (uint256) {
        return AaveLibrary.getTotalDebtBase(asset, user);
    }

    function getHealthFactor(address user) external view override returns (uint256) {
        return AaveLibrary.getHealthFactor(user);
    }

    function getBorrowRate(address asset, InterestRateMode rateMode) external view override returns (uint256) {
        if (rateMode == InterestRateMode.VARIABLE) {
            return AaveLibrary.getCurrentVariableBorrowRate(asset);
        } else {
            return AaveLibrary.getCurrentFixedBorrowRate(asset);
        }
    }

    function getSupplyRate(address asset) external view override returns (uint256) {
        return 0;
    }

    function getTotalDebt(address asset,address user) external view override returns (uint256) {
        return AaveLibrary.getTotalDebtBase(asset,user);
    }

    function getLTV(address asset) external view override returns (uint256) {
        return AaveLibrary.getLTV(asset);
    }

    function _currentDebtWei(
        address asset,
        uint256 rateMode
    ) internal view returns (uint256 fullDebtWei) {

    DataTypes.ReserveData memory r = AaveLibrary.POOL.getReserveData(asset);

    if (rateMode == 2) {
        // ―― Variable debt ――
        uint256 scaledRay = IVariableDebtToken(r.variableDebtTokenAddress).scaledBalanceOf(address(this));

        uint256 dt = block.timestamp - r.lastUpdateTimestamp;
        uint256 lin = (uint256(r.currentVariableBorrowRate) * dt)/ SECONDS_PER_YEAR + WadRayMath.RAY;
        uint256 idxRay = uint256(r.variableBorrowIndex).rayMul(lin);
        fullDebtWei = scaledRay.rayMul(idxRay);

    } else if (rateMode == 1) {
        // ―― Stable debt ――
        IStableDebtToken sd = IStableDebtToken(r.stableDebtTokenAddress);

        uint256 principalWei = sd.principalBalanceOf(address(this));
        uint256 rateRay = sd.getUserStableRate(address(this));
        uint256 dt  = block.timestamp - sd.getUserLastUpdated(address(this));

        uint256 interestWei  = (principalWei * rateRay * dt) / SECONDS_PER_YEAR / WadRayMath.RAY;

        fullDebtWei = principalWei + interestWei;
    } 
    }

    function getRepayAmount(
        address asset,
        uint256 amount, //scaledBebt
        InterestRateMode rateMode
    ) external view override returns (uint256) {
        uint256 normalizedVariableDebt = AaveLibrary.POOL.getReserveNormalizedVariableDebt(asset);
        uint256 repayAmount = amount.rayMul(normalizedVariableDebt);
        return repayAmount;
    }

    function getWithdrawableAmount(
        address asset,
        uint256 amount, //scaledSupplyBalancePrincipal
        InterestRateMode rateMode
    ) external view override returns (uint256) {
         uint256 normalizedIncome = AaveLibrary.POOL.getReserveNormalizedIncome(asset);
        return amount.rayMul(normalizedIncome);
    }

    function simulateRepay(
        address asset,
        InterestRateMode rateMode,
        uint16 pctBps
    ) external override view returns (uint256 repayWei) {
        uint256 _rateMode = rateMode == InterestRateMode.FIXED ? 1 : 2;
        uint256 debtWei = _currentDebtWei(asset, _rateMode);
        repayWei = debtWei.percentMul(pctBps);
    }

    function repayPortionBps(
        address asset,
        InterestRateMode rateMode,
        uint16 pctBps
    ) external returns (uint256 repaid) {
        uint256 _rateMode = rateMode == InterestRateMode.FIXED ? 1 : 2;
        uint256 amount = this.simulateRepay(asset, rateMode, pctBps);
        repaid = AaveLibrary.POOL.repay(asset, amount, _rateMode, address(this));
    }
}
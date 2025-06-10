// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPOOL.sol";
import {WadRayMath} from "aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "aave-v3-core/contracts/protocol/libraries/math/PercentageMath.sol";
import {IPoolDataProvider} from "aave-v3-core/contracts/interfaces/IPoolDataPROVIDER.sol";
import {IPoolAddressesProvider} from "aave-v3-core/contracts/interfaces/IPoolAddressesPROVIDER.sol";
import {DataTypes} from "aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {IVariableDebtToken} from "aave-v3-core/contracts/interfaces/IVariableDebtToken.sol";
import {IStableDebtToken} from "aave-v3-core/contracts/interfaces/IStableDebtToken.sol";

import "../libraries/Storage.sol";
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

    /// @notice Fetch the aToken address for a given underlying `asset`
    function getATokenAddress(
        address asset
    ) internal view returns (address) {
        (address aToken,,) = AAVE_PROTOCOL_DATA_PROVIDER.getReserveTokensAddresses(asset);
        return aToken;
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
        address user
    ) internal view returns (uint256) {
        (, uint256 totalDebt, , , , ) = POOL.getUserAccountData(user);
        return totalDebt;
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
    function getUserDebtBalance(address asset, address user) internal view returns (uint256) {
        (,,uint256 variableDebt,,,,,,) = AAVE_PROTOCOL_DATA_PROVIDER.getUserReserveData(asset, user);
        return variableDebt;
    }
}



// adaptor
abstract contract AaveAdaptor is ILiquidityLayerAdapter {
    using AaveLibrary for *;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint16 private constant MAX_BPS = 10_000; // 100 %
    uint16 private constant REFERRAL_CODE = 0;

        
    function buildSupply(address asset, uint256 amount, address onBehalfOf) external pure override returns (bytes memory) {
        return abi.encodeWithSelector(IPool.supply.selector, asset, amount, onBehalfOf, REFERRAL_CODE);
    }

    function buildWithdraw(address asset, uint256 amount, address to) external pure override returns (bytes memory) {
        return abi.encodeWithSelector(IPool.withdraw.selector, asset, amount, to);
    }

    function buildBorrow(address asset, uint256 amount, InterestRateMode interestRateMode, address onBehalfOf) external pure override returns (bytes memory) {
        uint256 rateMode = interestRateMode == InterestRateMode.VARIABLE ? 2 : 1;
        return abi.encodeWithSelector(IPool.borrow.selector, asset, amount, rateMode, REFERRAL_CODE,onBehalfOf);
    }

    function buildRepay(address asset, uint256 amount, InterestRateMode interestRateMode, address onBehalfOf) external pure override returns (bytes memory) {
        uint256 rateMode = interestRateMode == InterestRateMode.VARIABLE ? 2 : 1;
        return abi.encodeWithSelector(IPool.repay.selector, asset, amount, rateMode, onBehalfOf);
    }

    function getSupplyBalance(address asset, address user) external view override returns (uint256) {
        return AaveLibrary.getATokenBalance(asset, user);
    }

    function getDebtBalance(address asset, address user) external view override returns (uint256) {
        return AaveLibrary.getUserDebtBalance(asset, user);
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

    function getTotalDebt(address user) external view override returns (uint256) {
        return AaveLibrary.getTotalDebtBase(user);
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
    } else {
        revert("AaveModule: bad rateMode");
    }
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
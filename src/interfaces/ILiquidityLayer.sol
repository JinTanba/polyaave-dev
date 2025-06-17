// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "../libraries/DataStruct.sol";


interface ILiquidityLayer {

    function supply(address asset, uint256 amount, address onBehalfOf) external returns (uint256);


    function withdraw(address asset, uint256 amount, address to) external returns (uint256);


    function borrow(address asset, uint256 amount, InterestRateMode interestRateMode, address onBehalfOf) external returns (uint256 newScaledDebtAmount);

    function repay(address asset, uint256 amount, InterestRateMode interestRateMode, address onBehalfOf) external returns (uint256);

    function getSupplyBalance(address asset, address user) external view returns (uint256);

    function getDebtBalance(address asset, address user, InterestRateMode rateMode) external view returns (uint256);

    function getHealthFactor(address user) external view returns (uint256);

    function getBorrowRate(address asset, InterestRateMode rateMode) external view returns (uint256);

    function getLTV(address asset) external view returns (uint256);

    function getTotalDebt(address asset, address user) external view returns (uint256);
    
    function getRepayAmount(address asset, uint256 amount, InterestRateMode rateMode) external view returns (uint256);

    function simulateRepay(address borrowAsset, InterestRateMode rateMode, uint16 pctBps) external view returns (uint256 repayWei);
    
    function getSupplyRate(address asset) external view returns (uint256);
    
    function getWithdrawableAmount(address asset, uint256 scaledSupplyBalancePrincipal, InterestRateMode rateMode) external view returns (uint256);
}

interface ILiquidityLayerAdapter {

    function buildSupply(address asset, uint256 amount, address onBehalfOf) external view returns (bytes memory);

    function buildWithdraw(address asset, uint256 amount, address to) external view returns (bytes memory);

    function buildBorrow(address asset, uint256 amount, InterestRateMode interestRateMode, address onBehalfOf) external view returns (bytes memory);

    function buildRepay(address asset, uint256 amount, InterestRateMode interestRateMode, address onBehalfOf) external view returns (bytes memory);

    function getSupplyBalance(address asset, address user) external view returns (uint256);

    function getDebtBalance(address asset, address user) external view returns (uint256);

    function getHealthFactor(address user) external view returns (uint256);

    function getBorrowRate(address asset, InterestRateMode rateMode) external view returns (uint256);

    function getLTV(address asset) external view returns (uint256);

    function getTotalDebt(address user) external view returns (uint256);

    // function getRepayAmount(address asset, uint256 amount, InterestRateMode rateMode) external view returns (uint256);

    function simulateRepay(address borrowAsset, InterestRateMode rateMode, uint16 pctBps) external view returns (uint256 repayWei);

    function getSupplyRate(address asset) external view returns (uint256);

    function getWithdrawableAmount(address asset, uint256 scaledSupplyBalancePrincipal, InterestRateMode rateMode) external view returns (uint256);
}

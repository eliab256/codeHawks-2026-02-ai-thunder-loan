// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IThunderLoanFixed {
    function initialize(address tswapAddress) external;
    function deposit(address token, uint256 amount) external;
    function redeem(address token, uint256 amountOfAssetToken) external;
    function flashloan(
        address receiverAddress,
        address token,
        uint256 amount,
        bytes calldata params
    ) external;
    function repay(IERC20 token, uint256 amount) external;
    function setAllowedToken(
        address token,
        bool allowed
    ) external returns (address);
    function getCalculatedFee(
        address token,
        uint256 amount
    ) external view returns (uint256);
    function updateFlashLoanFee(uint256 newFee) external;
    function isAllowedToken(address token) external view returns (bool);
    function getAssetFromToken(address token) external view returns (address);
    function isCurrentlyFlashLoaning(
        address token
    ) external view returns (bool);
    function getFee() external view returns (uint256);
    function getFeePrecision() external view returns (uint256);
}

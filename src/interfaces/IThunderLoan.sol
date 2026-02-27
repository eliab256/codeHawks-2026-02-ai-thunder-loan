// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
// @audit-ok : import address instead of IERC20
interface IThunderLoan {
    function repay( address token, uint256 amount) external;
    // @audit-ok : lack of functions


}

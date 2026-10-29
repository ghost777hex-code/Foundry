// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev lib/v3-periphery's IWETH9 pins `pragma solidity =0.8.15`, so this copy is used instead.
interface IWETH9 is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}

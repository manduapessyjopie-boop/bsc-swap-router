// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface Symbol is IERC20 {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

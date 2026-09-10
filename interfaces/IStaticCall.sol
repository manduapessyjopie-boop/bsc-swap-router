// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IStaticCall {
    struct Call {
        address target;
        bytes callData;
    }

    function aggStaticCall(Call[] calldata calls) external view returns (bytes[] memory);

    function getBlockHash(uint256 blockNumber) external view returns (bytes32);

    function getBlockNumber() external view returns (uint256);

    function getCurrentBlockTimestamp() external view returns (uint256);

    function getEthBalance(address addr) external view returns (uint256);

    function getLastBlockHash() external view returns (bytes32);

    function getChainId() external view returns (uint256);

    function GetDecimal(address coin) external view returns (uint8);

    function GetT0T1(address pair) external view returns (address, address);

    function GetBalance(address coin, address account) external view returns (uint256);

    function getPairAddress(address arb, address main, address factory) external view returns (address);

    function BuildPair(address arb, address main, address factory) external view returns (address, uint112, uint112);

    function UpdatePair(address pair) external view returns (uint112 r0, uint112 r1);

    function GetPoolAddress(address arb, address main, uint24 fee, address factory) external view returns (address);

    function GetPoolLiquidity(address pool) external view returns (uint128);

    function GetSqrtPriceX96(address pool) external view returns (uint160);

    function GetPoolGlobalStateSqrtPriceX96AndFee(address pool) external view returns (uint160, uint24);

    function GetPoolFee(address pool) external view returns (uint24);

    function GetPoolTickSpacing(address pool) external view returns (int24);

    function FromPoolTickGetLiquidityNet(address pool, int24 tick) external view returns (int128);

    function BuildPool(address arb, address main, uint24 fee, address factory) external view returns (address, uint128, uint160);

    function UpdatePool(address pool, int24[] calldata ticks) external view returns (uint128,uint160,uint24,int24,int128[] memory);

    function GetPairTokens(address pair) external view returns (address, uint8, address, uint8);

    // singleton（Infinity CL / Uniswap V4）：reader=Infinity CLPoolManager 或 V4 StateView
    function GetSingletonSlot0(address reader, bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick);
}

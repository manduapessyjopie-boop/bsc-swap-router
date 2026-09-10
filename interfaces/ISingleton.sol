// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// Uniswap V4 / PancakeSwap Infinity（singleton 架构）执行所需的接口与类型。
// 详见 Infinity_V4统一接入方案.md §6。
//
// 约定：Currency / IHooks 在 ABI 上都是 address，原生币用 address(0)。

// ---- PoolKey（两 venue 字段不同）----

// Uniswap V4：5 字段
struct PoolKeyV4 {
    address currency0;
    address currency1;
    uint24  fee;
    int24   tickSpacing;
    address hooks;
}

// PancakeSwap Infinity CL：6 字段
struct PoolKeyInfinity {
    address currency0;
    address currency1;
    address hooks;
    address poolManager;
    uint24  fee;
    bytes32 parameters;
}

// swap 入参（两 venue 相同）。amountSpecified 负数 = exactInput。
struct SwapParams {
    bool    zeroForOne;
    int256  amountSpecified;
    uint160 sqrtPriceLimitX96;
}

// ---- Uniswap V4 PoolManager（自带结算，无独立 Vault）----
interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    // 返回 BalanceDelta（int256 打包的 int128 amount0 | int128 amount1）
    function swap(PoolKeyV4 calldata key, SwapParams calldata params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

// V4 回调接口（PoolManager.unlock 回调本合约）
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// ---- PancakeSwap Infinity：CLPoolManager（swap）+ Vault（结算）----
interface ICLPoolManager {
    function swap(PoolKeyInfinity calldata key, SwapParams calldata params, bytes calldata hookData) external returns (int256);
}

interface IVault {
    function lock(bytes calldata data) external returns (bytes memory);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

// Infinity 回调接口：Vault.lock 回调本合约的 lockAcquired（Pancake Infinity Vault 实际调用名）
interface ILockCallback {
    function lockAcquired(bytes calldata data) external returns (bytes memory);
}

// ---- BalanceDelta 提取（int256 高 128 位 = amount0，低 128 位 = amount1，均为有符号 int128）----
// 约定：从调用方视角，负 = 欠（需付/settle），正 = 收（可 take）。
library BalanceDeltaLib {
    function amount0(int256 delta) internal pure returns (int128 a0) {
        assembly { a0 := sar(128, delta) } // 算术右移，保留高 128 位符号
    }
    function amount1(int256 delta) internal pure returns (int128 a1) {
        assembly { a1 := signextend(15, delta) } // 从第 15 字节符号扩展，取低 128 位
    }
}

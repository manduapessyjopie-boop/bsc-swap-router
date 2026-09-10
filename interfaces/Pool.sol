// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface Pool {
       function swap(address recipient,
                             bool zeroForOne,
                             int256 amountSpecified,
                             uint160 sqrtPriceLimitX96,
                            bytes calldata data) 
                            external  returns (int256 amount0, int256 amount1) ;
           function slot0() external view returns (
                            uint160 sqrtPriceX96,
                            int24 tick,
                            uint16 observationIndex,
                            uint16 observationCardinality,
                            uint16 observationCardinalityNext,
                            uint32 feeProtocol,
                            bool unlocked
                            );
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
pragma abicoder v2;

import 'interfaces/Symbol.sol';
import 'libraries/Path.sol';
import './OnlyOwner.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SwapCallback is OnlyOwner{
    using SafeERC20 for Symbol;
    using Path for bytes;
    mapping(address => bytes32) public deployerAndCode;

    // 添加受信任的deployer地址（仅有创建者可以添加）
    function setDeployerAndCode(address deployer,bytes32 code) onlyOwner public  {
        deployerAndCode[deployer] = code;
    }

    // 集体添加构建者和code
    function setMultipleDeployerAndCode(address[] memory deployers, bytes32[] memory codes) public onlyOwner {
        require(deployers.length == codes.length, "Mismatched input lengths");
        for (uint256 i = 0; i < deployers.length; i++) {
            deployerAndCode[deployers[i]] = codes[i];
        }
    }

    struct SwapCallbackData {
        address payer;
        address deployer;
        bytes32 code;
        bytes path;
    }

    // 验证callback提供参数的合法性(防止发起人为非法对象)
    function verifyCallback(address token0,address token1,uint24 fee, address deployer, bytes32 code, bool verifyUnNeedFee)internal view {
        // 提供的deployer必须得是得到认可的deployer和相应的code
        require(deployerAndCode[deployer]==code && code !=0,"Not The RightDeployer");
        if (token0 > token1) (token0, token1) = (token1, token0);
        bytes memory encodedData = verifyUnNeedFee? abi.encode(token0, token1): abi.encode(token0, token1, fee);
        address pool = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff",deployer,keccak256(encodedData),code)))));
        require(msg.sender == address(pool),"sender is not poolAddress");
    }

    // 通用swapcallback函数，用于deployer调用来将合约中的代币发送给deployer
    function commonSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata _data, bool verifyUnNeedFee)  internal  {
        require(amount0Delta > 0 || amount1Delta > 0,"TZO"); // amount0Delta or amount1Delta  must be one greater than zero
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool(); // 解析swapcalldata
        verifyCallback(tokenIn, tokenOut, fee, data.deployer, data.code, verifyUnNeedFee); // 验证接收者必须为pool池(仅限bsc_pancake使用)
        (bool isExactInput, uint256 amountToPay) = amount0Delta > 0? (tokenIn < tokenOut, uint256(amount0Delta)): (tokenOut < tokenIn, uint256(amount1Delta));
        address tokenToTransfer = isExactInput ? tokenIn : tokenOut;
        Symbol(tokenToTransfer).safeTransfer(msg.sender, amountToPay);
    }

    // ----------------------------------以下内容为各dex相对应的callback函数名--------------------------------
    function pancakeV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data,false);
    }

    function uniswapV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data,false);
    }

    function cadinuV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data,false);
    }

    function mongswapV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data,false);
    }

    function smbV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data,false);
    }

    function squadV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data,false);
    }

    function swapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data,false);
    }

    // 0xa60a504d92a1C95bda729C3F745B361cA822d6dd（THENA不需要fee）
    function algebraSwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data, true);
    }
    /*
    function dexV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data, false);
    }

    function MSRV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data, false);
    }

    function elkDexV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data, false);
    }

    function LovelySwapV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data, false);
    }

     function julswapV2SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata _data) external  {
        commonSwapCallback(amount0Delta, amount1Delta, _data, false);
    }
    */
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import 'interfaces/Symbol.sol';
import 'interfaces/Pair.sol';
import 'interfaces/Pool.sol';
import 'interfaces/IStaticCall.sol';
import 'interfaces/ISingleton.sol';
import 'sub/BscSwapCallback.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Swap is SwapCallback {
    using SafeERC20 for Symbol; // 对于不标准的ERC20，因此transfer会失败，只能使用safeTransfer
    using BalanceDeltaLib for int256;
    address payable thisPayable;
    uint160 internal constant MIN_SQR = 4295128740;
    uint160 internal constant MAX_SQR = 1461446703485210103287273052203988822378723970341;
    // 原生币(V4/Infinity 池 currency=address(0))与库存 WBNB 互转用；BSC 主网 WBNB。
    address internal constant WETH = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IStaticCall private staticCall;
    receive() external payable {} // 此行才能接收eth9
    
    function setStaticAddress(address addr) onlyOwner public  {
        staticCall = IStaticCall(addr);
    }

    // singleton 回调可信来源（真实的 V4 PoolManager / Infinity Vault）。
    // 回调只校验 msg.sender 在此表内——绝不信 params 里传入的 manager/vault，
    // 否则攻击者可伪造 manager 返回任意 delta 掏空合约。
    mapping(address => bool) public trustedSingletonCaller;
    function setTrustedSingletonCaller(address addr, bool ok) onlyOwner public {
        trustedSingletonCaller[addr] = ok;
    }

    // 部署后一笔交易配齐：static 地址 + V3 callback deployer/code + singleton 可信回调 + owners。
    // 任一数组为空 / staticAddr==0 自动跳过该项（支持增量更新）。
    function setupAll(
        address staticAddr,
        address[] calldata deployers,
        bytes32[] calldata codes,
        address[] calldata singletonCallers,
        bool[] calldata singletonOks,
        address[] calldata owners
    ) onlyOwner external {
        if (staticAddr != address(0)) staticCall = IStaticCall(staticAddr);
        if (deployers.length > 0) setMultipleDeployerAndCode(deployers, codes);
        for (uint256 i = 0; i < singletonCallers.length; i++) {
            trustedSingletonCaller[singletonCallers[i]] = singletonOks[i];
        }
        if (owners.length > 0) addOwners(owners);
    }

    // 计算V2输出数量的数学函数（reserveIn增加amountInReally，reserveOut减少amountOutReally）
    function amount_Output_Func(uint amountIn, uint reserveIn, uint reserveOut, uint256 swapFee, uint256 tokenInTransferFee) private pure returns (uint amountOutExpect) 
    {
        uint amountInReally = amountIn * (10000 - tokenInTransferFee) / 10000;
        uint amountInWithFee = amountInReally * (10000 - swapFee) / 10000; // 输入实际数量
        uint denominator = reserveIn + amountInWithFee;
        amountOutExpect = (amountInWithFee * reserveOut) / denominator;
    }

    struct Params {
        address addr; // 币对地址
        bool v2; // 是否v2
        bool zeroForOne;
        bool ethIn; // 是否ethIn
        bool ethOut; // 是否ethOut
        address tokenIn; // 输入coin地址
        address tokenOut; // 输出coin地址
        address recipient; // 接受地址
        uint256 swapFee; // v2或者v3的fee
        uint256 tokenInTransferFee; // 转账fee
        uint256 tokenOutTransferFee; // 转账fee
        uint160 minSqrt; // v3的最小sqrt
        uint256 amountIn; // 输入数量
        uint256 amountOutMin; // 最小输出数量
        uint256 bundleAmount; // 捆绑金额
        address bundleAddr; // 捆绑受贿地址
        bytes data; // v3的cal
        // —— singleton（Infinity CL / Uniswap V4）字段 ——
        uint8   venue;       // 0=V2/V3  1=InfinityCL  2=UniV4
        address manager;     // Infinity=CLPoolManager  V4=PoolManager（swap 目标）
        address vault;       // Infinity 结算 Vault；V4=address(0)
        address hooks;       // 通常 address(0)
        int24   tickSpacing; // V4 用（PoolKey 字段）
        bytes32 parameters;  // Infinity 用（packed tickSpacing）
        uint256 orderId;     // 订单号（仅用于 emit 对账，不参与链上逻辑）
        address reader;      // 预检查读 getSlot0 的目标：V4=StateView  Infinity=CLPoolManager
        bytes32 poolId;      // 池 id（Go 已算好，预检查读 slot0 用；复用现有 minSqrt 作价格界）
        uint256 minFill;     // 最小成交量（输入侧 wei，由 Go 最低交易价值换算）：缩量成交后 actualIn < minFill 则 revert
        // 复用：swapFee 当 PoolKey.fee；tokenIn/tokenOut + zeroForOne 推导 currency0/1；amountIn/amountOutMin/recipient 同上
    }

   // 内部 wrap/unwrap（用内置 WETH 常量、无事件；供 _executeOrder 的 V2/V3 原生桥接用，避免与外层 SwapDone 重复）
   function _ethToWeth(uint256 Amount, address recipient) internal {
        Symbol(WETH).deposit{ value: Amount}();
        if (recipient != address(this)) Symbol(WETH).safeTransfer(recipient, Amount);
   }
   function _wethToEth(uint256 Amount, address recipient) internal {
        Symbol(WETH).withdraw(Amount);
        (bool ok, ) = recipient.call{value: Amount}(new bytes(0));
        require(ok, 'FTSE');
   }

   // 外部入口（Go 直调的纯 ETH↔WETH 转换）：省去 wethAddr（用内置 WETH 常量）、emit SwapDone 统一对账
   function ethToWeth(uint256 Amount, address recipient, uint256 orderId) onlyOwner external payable {
        _ethToWeth(Amount, recipient);
        emit SwapDone(orderId, address(0), WETH, Amount, Amount, recipient);
   }
   function wethToEth(uint256 Amount, address recipient, uint256 orderId) onlyOwner external payable {
        _wethToEth(Amount, recipient);
        emit SwapDone(orderId, WETH, address(0), Amount, Amount, recipient);
   }

    // 对账事件：Go 读 tx receipt 的 log 即可拿到订单号与实际输入/输出
    event SwapDone(uint256 indexed orderId, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient);
    event SwapFailed(uint256 indexed orderId);

    // 按"实际成交输入比例"行贿：effective = bundleAmount * actualIn / amountIn（部分成交不付满额，避免血亏）
    function _bribeScaled(address bundleAddr, uint256 bundleAmount, uint256 actualIn, uint256 amountIn) internal {
        if (bundleAddr == address(0) || bundleAmount == 0 || actualIn == 0) return;
        uint256 b = bundleAmount * actualIn / amountIn;
        if (b == 0) return;
        (bool ok, ) = bundleAddr.call{value: b}(new bytes(0));
        require(ok, 'FTSE');
    }

    // 执行单个订单（不含行贿），返回实际输出与实际输入，emit 对账事件（用真实成交量）。
    // fullFill=true：满量校验路径（swapCheck/transferCheck），不缩量；false：真实执行，缩量成交。
    function _executeOrder(Params calldata p, bool fullFill) internal returns (uint amountOut, uint amountIn) {
        if (p.venue == 2 || p.venue == 1) { (amountOut, amountIn) = _swapSingleton(p, fullFill); } // V4 / Infinity（含原生币桥接）
        else {
            if (p.ethIn) { _ethToWeth(p.amountIn, address(this)); }
            (amountOut, amountIn) = p.v2 ? swapV2(p, fullFill) : swapV3(p, fullFill);
            if (p.ethOut) { _wethToEth(amountOut, p.recipient); }
        }
        emit SwapDone(p.orderId, p.tokenIn, p.tokenOut, amountIn, amountOut, p.recipient); // 用实际成交 in/out
    }

    // singleton(V4/Infinity) 执行 + 原生币桥接：池子用原生 BNB(currency=address(0))，
    // 而合约库存是 WBNB —— 原生输入侧先把 WBNB 解包成 BNB 供 settle{value}；原生输出侧
    // take 收到的原生 BNB 再包回 WBNB。BNB:WBNB 恒 1:1，无换算误差。tokenIn/tokenOut==0 即原生侧。
    function _swapSingleton(Params calldata p, bool fullFill) internal returns (uint amountOut, uint amountIn) {
        // 原生输入不再预 withdraw 满量：改由 settleCurrency 按实际结算量 lazy withdraw（支持部分成交）
        (amountOut, amountIn) = (p.venue == 2) ? swapV4(p, fullFill) : swapInfinity(p, fullFill);
        // 原生输出（take 的原生 BNB 已在本合约）：
        //   ethOut=true  → 真原生交付（如买 BNB 补 gas），直接转原生、不包成 WBNB；
        //   ethOut=false → W-token 库存模型，deposit 成 WBNB 交付。
        if (p.tokenOut == address(0)) {
            if (p.ethOut) {
                if (p.recipient != address(this)) {
                    (bool ok, ) = p.recipient.call{value: amountOut}(new bytes(0));
                    require(ok, 'FTSE');
                }
            } else {
                Symbol(WETH).deposit{value: amountOut}();
                if (p.recipient != address(this)) Symbol(WETH).safeTransfer(p.recipient, amountOut);
            }
        }
    }

    // NBV:no bundle value FTSE:failed to send eth9
    // 使用此函数的pair和pool均必须是经过前期筛选，正常fee,可以交易的正经合约
    function swap(Params calldata params) onlyOwner public payable {
        (, uint amountIn) = _executeOrder(params, false);                       // 先执行（缩量）拿实际输入
        _bribeScaled(params.bundleAddr, params.bundleAmount, amountIn, params.amountIn); // 再按比例行贿
    }

    // 仅供 swapBatch 的 try/catch 自调用（外部不可直接调，攻击者 msg.sender != 本合约）；返回实际输入供 bribe 缩放
    function executeOrderSelf(Params calldata p) external returns (uint amountIn) {
        require(msg.sender == address(this), "only self");
        (, amountIn) = _executeOrder(p, false);
    }

    // 批量执行多个独立订单：单个失败不影响其他（try/catch 逐单回滚）；
    // 整批至少一单成功才行贿一次（取 list[0] 的 bundle 参数；不行贿则置 0）。
    // allowPartial=true ：独立模式，单个失败不影响其他（try/catch 逐单回滚），逐单 emit 成败；
    // allowPartial=false：原子模式，任一单失败则整批 revert（无 log）。
    function swapBatch(Params[] calldata list, bool allowPartial) onlyOwner external payable {
        // 只累计「成功腿」的 bribe（每腿带自己的 bundleAmount）——失败腿的 bribe 绝不支付，
        // 避免「大额 bribe 腿失败、薄利腿成功」时仍付全额 bribe 导致血亏。bribe 收款地址取 list[0].bundleAddr（builder）。
        uint256 bribeSum;
        uint256 okCount; // 成功腿数。allowPartial 下若「全败」则整批 revert → builder 丢弃、不落块不付 gas（MEV 铁律：没赢不上链）。
        for (uint i = 0; i < list.length; i++) {
            if (allowPartial) {
                try this.executeOrderSelf(list[i]) returns (uint amountIn) {
                    bribeSum += list[i].bundleAmount * amountIn / list[i].amountIn; // 按实际成交比例
                    okCount++;
                } catch {
                    emit SwapFailed(list[i].orderId);
                }
            } else {
                (, uint amountIn) = _executeOrder(list[i], false); // 原子：失败直接 revert 整批
                bribeSum += list[i].bundleAmount * amountIn / list[i].amountIn;
                okCount++;
            }
        }
        require(okCount > 0, 'ALLF'); // 全败则 revert，避免「成交0 却落块付 gas」白亏（部分成功仍照常落块）
        if (bribeSum > 0 && list.length > 0 && list[0].bundleAddr != address(0)) {
            (bool ok, ) = list[0].bundleAddr.call{value: bribeSum}(new bytes(0));
            require(ok, 'FTSE');
        }
    }

    function transfer(address coin, address recipient, uint amount, uint256 orderId)onlyOwner external payable {
        if (coin == address(0)){ // eth9
            (bool ok, ) =recipient.call{value:amount}(new bytes(0));
            require(ok, 'FTSE');
          } else {
            Symbol symbol =Symbol(coin);
            symbol.safeTransfer(recipient, amount);
          }
        emit SwapDone(orderId, coin, coin, amount, amount, recipient); // 纯转移也 emit，统一收据按 orderId 对账
    }

    // 将coins（退还给recipient）
    function transferCoinsBack(address[] calldata coins, address recipient) onlyOwner external payable {
        for (uint i = 0; i < coins.length; i++) {
          address coinAddr =coins[i];
          if (coinAddr == address(0)){ // eth9
            uint balance = address(this).balance;
            (bool ok, ) =recipient.call{value:balance}(new bytes(0));
            require(ok, 'FTSE');
          } else {
            Symbol symbol =Symbol(coinAddr);
            uint balance = symbol.balanceOf(address(this));
            symbol.safeTransfer(recipient, balance);
          }
        }
    }
    
    // 检验transfer是否能成功
    function transferCheck(Params calldata params, uint fee) onlyOwner external payable {
        uint amountOut; // 输出coin数量
        Symbol symbol =Symbol(params.tokenOut);
        address recipient = 0x26eB17CBcB2726DD62Ba2d62B5cAc3C40BE16be9;
        if (params.v2) {
            (amountOut, ) = swapV2(params, true); // 满量校验，不缩量
        } else {
            (amountOut, ) = swapV3(params, true); // 满量校验，不缩量
        }
        uint balanceStart = symbol.balanceOf(recipient);
        symbol.safeTransfer(recipient, amountOut);
        uint balanceEnd = symbol.balanceOf(recipient);
        uint actualAmount = balanceEnd - balanceStart;
        require(actualAmount>=amountOut*(10000-fee)/10000, 'BIOA');
    }

    // 检验swap是否能成功（两腿连续执行，验证池可交易）
    // swapCheck 校验"本地数学==链上实际"，必须满量成交（fullFill=true），绝不缩量——否则部分成交会假成功、掩盖偏差。
    function swapCheck(Params calldata params1, Params calldata params2) onlyOwner external payable {
        if (params1.venue == 2 || params1.venue == 1) { _swapSingleton(params1, true); _swapSingleton(params2, true); return; } // V4 / Infinity（含原生桥接）
        if (params1.v2) {
            swapV2(params1, true) ;
            swapV2(params2, true) ;
        } else {
            swapV3(params1, true);
            swapV3(params2, true);
        }
    }

    // V2 比例校验：received(dx)·amountIn ≥ amountOutMin·dx（received 含 tokenOutTransferFee）。
    function _v2RatioOk(Params calldata p, uint rIn, uint rOut, uint dx) internal pure returns (bool) {
        if (dx == 0) return false;
        uint outExpect = amount_Output_Func(dx, rIn, rOut, p.swapFee, p.tokenInTransferFee);
        uint received = outExpect * (10000 - p.tokenOutTransferFee) / 10000;
        return received * p.amountIn >= p.amountOutMin * dx; // 均价 received/dx ≥ amountOutMin/amountIn
    }

    // V2 无原生限价 → 二分搜索满足比例 floor 的最大 dx∈[0,amountIn]（抗同区块抢跑的缩量；复用 amount_Output_Func，转账税自动正确）。
    function _v2ShrinkAmountIn(Params calldata p, uint rIn, uint rOut) internal pure returns (uint) {
        if (_v2RatioOk(p, rIn, rOut, p.amountIn)) return p.amountIn; // 无抢跑：满量即可
        uint lo = 0;
        uint hi = p.amountIn;
        for (uint i = 0; i < 40; i++) { // 40 次足够收敛
            uint mid = (lo + hi) / 2;
            if (mid == lo) break;
            if (_v2RatioOk(p, rIn, rOut, mid)) lo = mid; else hi = mid;
        }
        return lo; // 最大可行 dx（不可行则 0 → 由 minFill 护栏 revert）
    }

    // fullFill=true：满量校验（swapCheck/transferCheck），满量或 revert；false：真实执行，二分缩量成交。
    function swapV2(Params calldata params, bool fullFill) internal returns (uint amountOut, uint amountIn) {
        Pair pair = Pair(params.addr);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint rIn = params.zeroForOne ? reserve0 : reserve1;
        uint rOut = params.zeroForOne ? reserve1 : reserve0;
        amountIn = params.amountIn;
        if (!fullFill) {
            amountIn = _v2ShrinkAmountIn(params, rIn, rOut); // 抢跑后缩量到比例 floor 的最大值
            require(amountIn >= params.minFill, 'DUST');     // 最小成交量护栏
        }
        // 计算预期输出数量（未扣除tokenOutTransferFee）
        uint amountOutExpect = amount_Output_Func(amountIn, rIn, rOut, params.swapFee, params.tokenInTransferFee);
        if (fullFill) {
            require(amountOutExpect * (10000 - params.tokenOutTransferFee) / 10000 >= params.amountOutMin, 'IOA'); // 满量预检查
        }
        Symbol(params.tokenIn).safeTransfer(params.addr, amountIn);
        address recipient = params.ethOut ? address(this) : params.recipient;
        uint balanceStart = Symbol(params.tokenOut).balanceOf(recipient);
        params.zeroForOne ?
        pair.swap(0, amountOutExpect, recipient, new bytes(0))
        : pair.swap(amountOutExpect, 0, recipient, new bytes(0));
        uint balanceEnd = Symbol(params.tokenOut).balanceOf(recipient);
        amountOut = balanceEnd - balanceStart;
        if (fullFill) {
            require(amountOut >= params.amountOutMin, 'BIOA');
        } else {
            require(amountOut * params.amountIn >= params.amountOutMin * amountIn, 'BIOA'); // 比例强确认兜底
        }
    }

    // fullFill=true：满量校验（swapCheck/transferCheck），MIN/MAX 不限价 + 事前预检查 + amountOutMin 满量硬卡。
    // fullFill=false：真实执行，minSqrt 当限价 → 抢跑后自动缩量成交（部分成交）；比例强确认 + minFill 护栏。
    function swapV3(Params calldata params, bool fullFill) internal returns (uint amountOut, uint amountIn) {
        Pool pool = Pool(params.addr);
        uint160 limit;
        if (fullFill) {
            uint160 nowSqrt = staticCall.GetSqrtPriceX96(params.addr);
            if (params.zeroForOne) require(nowSqrt >= params.minSqrt, 'IOA');
            else require(nowSqrt <= params.minSqrt, 'IOA');
            limit = params.zeroForOne ? MIN_SQR : MAX_SQR;
        } else {
            limit = params.minSqrt; // 缩量：成交到保本价即停
        }
        address recipient = params.ethOut ? address(this) : params.recipient;
        uint outStart = Symbol(params.tokenOut).balanceOf(recipient);
        uint inStart = Symbol(params.tokenIn).balanceOf(address(this)); // 输入侧合约余额（callback 付出 tokenIn）
        pool.swap(recipient, params.zeroForOne, int256(params.amountIn), limit, params.data);
        amountOut = Symbol(params.tokenOut).balanceOf(recipient) - outStart;
        amountIn = inStart - Symbol(params.tokenIn).balanceOf(address(this));
        if (fullFill) {
            require(amountOut >= params.amountOutMin, 'BIOA');
        } else {
            require(amountOut * params.amountIn >= params.amountOutMin * amountIn, 'BIOA'); // 比例强确认：均价≥amountOutMin/amountIn
            require(amountIn >= params.minFill, 'DUST');                                    // 最小成交量护栏
        }
    }

    // ============ Singleton（Uniswap V4 / PancakeSwap Infinity CL）执行 ============
    // amountSpecified 用负数（exactInput）；amountOutMin 在回调内用精确 BalanceDelta 校验。
    // 原生币（address(0)）由 settle{value}/take 处理，不 wrap。

    // singleton 共用：按 fullFill 算限价 + 测实际 in/out + 校验。recipient/inTok：原生侧映射到本合约/WETH 度量。
    function _singletonAfter(Params calldata p, bool fullFill, address recipient, address inTok, uint outStart, uint inStart)
        internal view returns (uint amountOut, uint amountIn)
    {
        amountOut = _balanceOf(p.tokenOut, recipient) - outStart;
        amountIn = inStart - _balanceOf(inTok, address(this));
        if (fullFill) {
            require(amountOut >= p.amountOutMin, 'BIOA');
        } else {
            require(amountOut * p.amountIn >= p.amountOutMin * amountIn, 'BIOA');
            require(amountIn >= p.minFill, 'DUST');
        }
    }

    function _singletonLimit(Params calldata p, bool fullFill) internal view returns (uint160 limit) {
        if (fullFill) {
            (uint160 nowSqrt, ) = staticCall.GetSingletonSlot0(p.reader, p.poolId); // 满量路径保留事前预检查
            if (p.zeroForOne) require(nowSqrt >= p.minSqrt, 'IOA'); else require(nowSqrt <= p.minSqrt, 'IOA');
            limit = p.zeroForOne ? MIN_SQR : MAX_SQR;
        } else {
            limit = p.minSqrt; // 缩量：成交到保本价即停
        }
    }

    // ---- Uniswap V4：PoolManager.unlock → unlockCallback ----
    function swapV4(Params calldata p, bool fullFill) internal returns (uint amountOut, uint amountIn) {
        uint160 limit = _singletonLimit(p, fullFill);
        address recipient = p.tokenOut == address(0) ? address(this) : p.recipient; // 原生输出 take 给本合约，再由 _swapSingleton 处理
        address inTok = p.tokenIn == address(0) ? WETH : p.tokenIn;                  // 原生输入用 WETH 库存度量（settle 内 lazy withdraw）
        uint outStart = _balanceOf(p.tokenOut, recipient);
        uint inStart = _balanceOf(inTok, address(this));
        IV4PoolManager(p.manager).unlock(abi.encode(p, recipient, limit));
        (amountOut, amountIn) = _singletonAfter(p, fullFill, recipient, inTok, outStart, inStart);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Params memory p, address recipient, uint160 limit) = abi.decode(data, (Params, address, uint160));
        require(trustedSingletonCaller[msg.sender], "untrusted caller"); // ★ 安全：只信预设的真实 PoolManager（不信 params）
        (address c0, address c1) = p.zeroForOne ? (p.tokenIn, p.tokenOut) : (p.tokenOut, p.tokenIn);
        PoolKeyV4 memory key = PoolKeyV4(c0, c1, uint24(p.swapFee), p.tickSpacing, p.hooks);
        int256 delta = IV4PoolManager(p.manager).swap(
            key,
            SwapParams(p.zeroForOne, -int256(p.amountIn), limit),
            ""
        );
        settleAndTake(p.manager, c0, c1, delta, recipient); // V4 结算目标 = manager；in/out 由 swapV4 用实际余额校验
        return "";
    }

    // ---- PancakeSwap Infinity CL：Vault.lock → lockAcquired ----
    function swapInfinity(Params calldata p, bool fullFill) internal returns (uint amountOut, uint amountIn) {
        uint160 limit = _singletonLimit(p, fullFill);
        address recipient = p.tokenOut == address(0) ? address(this) : p.recipient;
        address inTok = p.tokenIn == address(0) ? WETH : p.tokenIn;
        uint outStart = _balanceOf(p.tokenOut, recipient);
        uint inStart = _balanceOf(inTok, address(this));
        IVault(p.vault).lock(abi.encode(p, recipient, limit));
        (amountOut, amountIn) = _singletonAfter(p, fullFill, recipient, inTok, outStart, inStart);
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (Params memory p, address recipient, uint160 limit) = abi.decode(data, (Params, address, uint160));
        require(trustedSingletonCaller[msg.sender], "untrusted caller"); // ★ 安全：只信预设的真实 Vault（不信 params）
        (address c0, address c1) = p.zeroForOne ? (p.tokenIn, p.tokenOut) : (p.tokenOut, p.tokenIn);
        PoolKeyInfinity memory key = PoolKeyInfinity(c0, c1, p.hooks, p.manager, uint24(p.swapFee), p.parameters);
        int256 delta = ICLPoolManager(p.manager).swap(
            key,
            SwapParams(p.zeroForOne, -int256(p.amountIn), limit),
            ""
        );
        settleAndTake(p.vault, c0, c1, delta, recipient); // Infinity 结算目标 = Vault；in/out 由 swapInfinity 用实际余额校验
        return "";
    }

    // 对 BalanceDelta：负的一侧 settle（付 tokenIn），正的一侧 take 到 recipient（收 tokenOut）。
    // settleTarget：V4=PoolManager  Infinity=Vault。
    function settleAndTake(address settleTarget, address c0, address c1, int256 delta, address recipient) internal {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) settleCurrency(settleTarget, c0, uint256(uint128(-a0)));
        else if (a0 > 0) IVault(settleTarget).take(c0, recipient, uint256(uint128(a0)));
        if (a1 < 0) settleCurrency(settleTarget, c1, uint256(uint128(-a1)));
        else if (a1 > 0) IVault(settleTarget).take(c1, recipient, uint256(uint128(a1)));
    }

    // 结算欠款：原生币按实际结算量 lazy 解包 WBNB→BNB 再 settle{value}（支持部分成交）；ERC20 走 sync → transfer → settle。
    function settleCurrency(address target, address currency, uint256 amount) internal {
        if (currency == address(0)) {
            Symbol(WETH).withdraw(amount); // 原生输入：按实际 amount 解包，库存 WBNB 减少恰为 actualIn（供 swapV4/Infinity 度量）
            IVault(target).settle{value: amount}();
        } else {
            IVault(target).sync(currency);
            Symbol(currency).safeTransfer(target, amount);
            IVault(target).settle();
        }
    }

    // 余额查询：原生币用 account.balance，ERC20 用 balanceOf。
    function _balanceOf(address token, address account) internal view returns (uint) {
        if (token == address(0)) return account.balance;
        return Symbol(token).balanceOf(account);
    }
}

// contract(Swap 动态):0x3D1D3212464c754A1850f21253FD038BA3ef2a3B  旧:0xBe4fe22974B7A6e60DF9708A5a135aF3a7517620
// StaticCall(静态):0xF20c15934C2291B29D46f9e7D629F21d730d1CaF
// owner:0x0a8Fb3135ABC9A98f49D840a545E81ED44167ee7
// 注：链上实际地址以 dex/BSC/delegateCall/<addr>.abi、dex/BSC/staticCall/<addr>.abi 文件名为准（与 CLAUDE.md 同步）。

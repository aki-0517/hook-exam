// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {TokenFixture} from "../utils/TokenFixture.sol"; 
import {IPoolManager} from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {IHooks} from "../../lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "../../lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../lib/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "../../lib/v4-core/src/types/Currency.sol";
import {AaveLiquidityHook} from "../../src/hooks/AaveLiquidityHook.sol";
import {MockLendingPool} from "../mocks/MockLendingPool.sol";
import {ILendingPool} from "../../src/hooks/interfaces/ILendingPool.sol"; 

contract AaveLiquidityHookTest is Test, TokenFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    AaveLiquidityHook hook;
    MockLendingPool mockLendingPool;
    MockPoolManager manager;
    PoolKey poolKey;
    PoolId poolId;
    
    int24 lowerTick = -60;
    int24 upperTick = 60;
    uint160 initialSqrtPrice = 1 << 96; // 1:1 ratio
    
    function setUp() public override(TokenFixture, Test) {
        // TokenFixture で token0, token1 をセットアップ
        TokenFixture.setUp();
        
        // MockPoolManager（slot0 の更新用関数を含む）をデプロイ
        manager = new MockPoolManager();
        
        // MockLendingPool をデプロイ
        mockLendingPool = new MockLendingPool();
        
        // AaveLiquidityHook をデプロイ（コンストラクタ引数に manager と mockLendingPool のアドレスを渡す）
        hook = new AaveLiquidityHook(manager, ILendingPool(address(mockLendingPool)));
        
        // プールキーを作成（hooks に hook のアドレスを指定）
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        // プールを初期化（初期価格 1:1、tick = 0）
        manager.initialize(poolKey, initialSqrtPrice, "");
        poolId = poolKey.toId();
        
        // PoolManager にトークンの転送ができるよう、トークンを承認
        token0.approve(address(manager), 100 ether);
        token1.approve(address(manager), 100 ether);
    }
    
    function test_outOfRangeLiquidityFlow() public {
        // まず、レンジ内（tick が [lowerTick, upperTick] 内）で流動性を追加
        manager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lowerTick,
                tickUpper: upperTick,
                liquidityDelta: 1 ether
            }),
            ""
        );
        
        // 初期状態はレンジ内なので、hook.isOutOfRange は false のはず
        bool inRange = !hook.isOutOfRange(poolId, address(this));
        assertTrue(inRange, "In the initial state, liquidity is in range");
        
        // 次に、価格がレンジ外（例：tick を -100 に更新）になるよう slot0 を更新
        manager.setSlot0ForTest(poolId, initialSqrtPrice, -100);
        
        // 状態更新関数を呼び出して、レンジ外にしたことを通知
        hook.checkAndUpdateLiquidityStatus(address(this), poolKey, lowerTick, upperTick);
        
        // レンジ外と判断され、Aave への預入が行われたはず
        bool outOfRange = hook.isOutOfRange(poolId, address(this));
        assertTrue(outOfRange, "Liquidity is determined to be out-of-range");
        
        // _estimateAvailableAmount() が 1 ether を返すので、token0 の預入額が 1 ether、token1 は 0 であるはず
        uint256 depositToken0 = hook.depositedAmount(poolId, address(this), poolKey.currency0);
        uint256 depositToken1 = hook.depositedAmount(poolId, address(this), poolKey.currency1);
        assertEq(depositToken0, 1 ether, "Token0 deposit amount should be 1 ether");
        assertEq(depositToken1, 0, "Token1 deposit amount should be 0");
        
        // 価格がレンジ内に戻るように、tick を 0 に更新して状態更新を実行
        manager.setSlot0ForTest(poolId, initialSqrtPrice, 0);
        hook.checkAndUpdateLiquidityStatus(address(this), poolKey, lowerTick, upperTick);
        
        // レンジ内に戻ったので、Aave からの引き出しが行われたはず
        inRange = !hook.isOutOfRange(poolId, address(this));
        assertTrue(inRange, "Price has returned in-range");
        
        depositToken0 = hook.depositedAmount(poolId, address(this), poolKey.currency0);
        depositToken1 = hook.depositedAmount(poolId, address(this), poolKey.currency1);
        assertEq(depositToken0, 0, "Token0 deposit amount should be withdrawn");
        assertEq(depositToken1, 0, "Token1 deposit amount should be withdrawn");
    }
}

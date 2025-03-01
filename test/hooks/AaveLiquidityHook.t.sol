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
    
    // override は TokenFixture のみ指定
    function setUp() public override(TokenFixture) {
        TokenFixture.setUp();
        
        manager = new MockPoolManager();
        mockLendingPool = new MockLendingPool();
        
        hook = new AaveLiquidityHook(manager, ILendingPool(address(mockLendingPool)));
        
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        manager.initialize(poolKey, initialSqrtPrice);
        poolId = poolKey.toId();
        
        token0.approve(address(manager), 100 ether);
        token1.approve(address(manager), 100 ether);
    }
    
    function test_outOfRangeLiquidityFlow() public {
        // 修正後の呼び出し：ModifyLiquidityParams に data フィールドを追加し、不要なアドレス引数を削除、さらに最後の bytes 引数を追加
        manager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lowerTick,
                tickUpper: upperTick,
                liquidityDelta: 1 ether,
                salt: ""
            }),
            ""
        );
        
        bool inRange = !hook.isOutOfRange(poolId, address(this));
        assertTrue(inRange, "In the initial state, liquidity is in range");
        
        manager.setSlot0ForTest(poolId, initialSqrtPrice, -100);
        hook.checkAndUpdateLiquidityStatus(address(this), poolKey, lowerTick, upperTick);
        
        bool outOfRange = hook.isOutOfRange(poolId, address(this));
        assertTrue(outOfRange, "Liquidity is determined to be out-of-range");
        
        uint256 depositToken0 = hook.depositedAmount(poolId, address(this), poolKey.currency0);
        uint256 depositToken1 = hook.depositedAmount(poolId, address(this), poolKey.currency1);
        assertEq(depositToken0, 1 ether, "Token0 deposit amount should be 1 ether");
        assertEq(depositToken1, 0, "Token1 deposit amount should be 0");
        
        manager.setSlot0ForTest(poolId, initialSqrtPrice, 0);
        hook.checkAndUpdateLiquidityStatus(address(this), poolKey, lowerTick, upperTick);
        
        inRange = !hook.isOutOfRange(poolId, address(this));
        assertTrue(inRange, "Price has returned in-range");
        
        depositToken0 = hook.depositedAmount(poolId, address(this), poolKey.currency0);
        depositToken1 = hook.depositedAmount(poolId, address(this), poolKey.currency1);
        assertEq(depositToken0, 0, "Token0 deposit amount should be withdrawn");
        assertEq(depositToken1, 0, "Token1 deposit amount should be withdrawn");
    }
}

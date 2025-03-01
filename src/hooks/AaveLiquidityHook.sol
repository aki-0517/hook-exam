// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "../../lib/v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "../../lib/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../../lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../lib/v4-core/src/types/PoolId.sol";
import {Currency} from "../../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../../lib/v4-core/src/types/BalanceDelta.sol";
import {ILendingPool, IERC20} from "./interfaces/ILendingPool.sol";
import {MockPoolManager} from "../../test/mocks/MockPoolManager.sol";

/**
 * @title AaveLiquidityHook
 * @notice Uniswap V4 フックを使用し、アウトオブレンジになった流動性の idle な側のトークンを Aave に預け、利回りを得る
 */
contract AaveLiquidityHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    ILendingPool public immutable lendingPool;
    
    mapping(PoolId => mapping(address => bool)) public isOutOfRange;
    mapping(PoolId => mapping(address => mapping(Currency => uint256))) public depositedAmount;

    constructor(IPoolManager _poolManager, ILendingPool _lendingPool) BaseHook(_poolManager) {
        lendingPool = _lendingPool;
    }

    // BaseHook が要求する抽象関数の実装（必要な権限フラグを返す）
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = false;
        permissions.afterInitialize = false;
        permissions.beforeAddLiquidity = true;
        permissions.afterAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
        permissions.afterRemoveLiquidity = true;
        permissions.beforeSwap = false;
        permissions.afterSwap = false;
        permissions.beforeDonate = false;
        permissions.afterDonate = false;
        permissions.beforeSwapReturnDelta = false;
        permissions.afterSwapReturnDelta = false;
        permissions.afterAddLiquidityReturnDelta = false;
        permissions.afterRemoveLiquidityReturnDelta = false;
    }

    // override キーワードを追加
    function getHooksCalls() public pure returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }
    
    // override キーワードを追加
    function beforeAddLiquidity(
        address, /* sender */
        PoolKey calldata, /* key */
        IPoolManager.ModifyLiquidityParams calldata, /* params */
        bytes calldata /* data */
    ) external override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta /*delta*/,
        bytes calldata /*data*/
    ) external returns (bytes4) {
        PoolId poolIdLocal = key.toId();
        (, int24 currentTick, , , , , ) =
            (MockPoolManager(address(poolManager))).getSlot0(poolIdLocal);

        bool outOfRange = (currentTick < params.tickLower || currentTick > params.tickUpper);
        isOutOfRange[poolIdLocal][sender] = outOfRange;

        if (outOfRange) {
            Currency idleCurrency;
            if (currentTick < params.tickLower) {
                idleCurrency = key.currency0;
            } else if (currentTick > params.tickUpper) {
                idleCurrency = key.currency1;
            }
            uint256 availableAmount = _estimateAvailableAmount(sender, poolIdLocal, idleCurrency);
            if (availableAmount > 0) {
                _depositToAave(sender, poolIdLocal, idleCurrency, availableAmount);
            }
        }
        return BaseHook.afterAddLiquidity.selector;
    }

    // override キーワードを追加
    function beforeRemoveLiquidity(
        address, /* sender */
        PoolKey calldata, /* key */
        IPoolManager.ModifyLiquidityParams calldata, /* params */
        bytes calldata /* data */
    ) external override returns (bytes4) {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta /*delta*/,
        bytes calldata /*data*/
    ) external returns (bytes4) {
        PoolId poolIdLocal = key.toId();
        (, int24 currentTick, , , , , ) =
            (MockPoolManager(address(poolManager))).getSlot0(poolIdLocal);
        bool stillOutOfRange = (currentTick < params.tickLower || currentTick > params.tickUpper);
        isOutOfRange[poolIdLocal][sender] = stillOutOfRange;
        
        if (!stillOutOfRange) {
            uint256 deposit0 = depositedAmount[poolIdLocal][sender][key.currency0];
            if (deposit0 > 0) {
                _withdrawFromAave(sender, poolIdLocal, key.currency0, deposit0);
            }
            uint256 deposit1 = depositedAmount[poolIdLocal][sender][key.currency1];
            if (deposit1 > 0) {
                _withdrawFromAave(sender, poolIdLocal, key.currency1, deposit1);
            }
        }
        return BaseHook.afterRemoveLiquidity.selector;
    }
    
    function checkAndUpdateLiquidityStatus(
        address liquidityProvider,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper
    ) external {
        PoolId poolIdLocal = key.toId();
        (, int24 currentTick, , , , , ) =
            (MockPoolManager(address(poolManager))).getSlot0(poolIdLocal);
        bool wasOutOfRange = isOutOfRange[poolIdLocal][liquidityProvider];
        bool isNowOutOfRange = (currentTick < tickLower || currentTick > tickUpper);

        if (wasOutOfRange != isNowOutOfRange) {
            isOutOfRange[poolIdLocal][liquidityProvider] = isNowOutOfRange;
            if (isNowOutOfRange) {
                Currency idleCurrency;
                if (currentTick < tickLower) {
                    idleCurrency = key.currency0;
                } else if (currentTick > tickUpper) {
                    idleCurrency = key.currency1;
                }
                uint256 availableAmount = _estimateAvailableAmount(liquidityProvider, poolIdLocal, idleCurrency);
                if (availableAmount > 0) {
                    _depositToAave(liquidityProvider, poolIdLocal, idleCurrency, availableAmount);
                }
            } else {
                uint256 deposit0 = depositedAmount[poolIdLocal][liquidityProvider][key.currency0];
                if (deposit0 > 0) {
                    _withdrawFromAave(liquidityProvider, poolIdLocal, key.currency0, deposit0);
                }
                uint256 deposit1 = depositedAmount[poolIdLocal][liquidityProvider][key.currency1];
                if (deposit1 > 0) {
                    _withdrawFromAave(liquidityProvider, poolIdLocal, key.currency1, deposit1);
                }
            }
        }
    }

    function _depositToAave(
        address sender,
        PoolId poolIdLocal,
        Currency currency,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        poolManager.take(currency, address(this), amount);
        IERC20(token).approve(address(lendingPool), amount);
        lendingPool.deposit(token, amount, sender, 0);
        depositedAmount[poolIdLocal][sender][currency] += amount;
    }

    function _withdrawFromAave(
        address sender,
        PoolId poolIdLocal,
        Currency currency,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        uint256 withdrawn = lendingPool.withdraw(token, amount, address(this));
        IERC20(token).approve(address(poolManager), withdrawn);
        // settle() は引数なしに変更
        poolManager.settle();
        depositedAmount[poolIdLocal][sender][currency] = 0;
    }

    function _estimateAvailableAmount(
        address, /* liquidityProvider */
        PoolId,   /* poolId */
        Currency  /* currency */
    ) internal view returns (uint256) {
        return 1 ether;
    }
}

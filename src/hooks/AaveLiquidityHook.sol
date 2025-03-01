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

/**
 * @title AaveLiquidityHook
 * @notice Uniswap V4 フックを使用し、アウトオブレンジになった流動性の idle な側のトークンを Aave に預け、利回りを得る
 */
contract AaveLiquidityHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    ILendingPool public immutable lendingPool;
    
    // プールIDと流動性提供者ごとに、アウトオブレンジ状態を記録
    mapping(PoolId => mapping(address => bool)) public isOutOfRange;
    
    // プールID → LP → 通貨ごとの預入額
    mapping(PoolId => mapping(address => mapping(Currency => uint256))) public depositedAmount;

    constructor(IPoolManager _poolManager, ILendingPool _lendingPool) BaseHook(_poolManager) {
        lendingPool = _lendingPool;
    }

    function getHooksCalls() public pure virtual override returns (Hooks.Calls memory) {
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
    
    /// @notice 流動性追加前フック（追加ロジックがなければそのままリターン）
    function beforeAddLiquidity(
        address /*sender*/,
        PoolKey calldata /*key*/,
        IPoolManager.ModifyLiquidityParams calldata /*params*/,
        bytes calldata /*data*/
    ) external override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @notice 流動性追加後フック
     *         プール内の現在価格（tick）が指定レンジ外の場合、idleな側のトークンを Aave に預ける
     */
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta /*delta*/,
        bytes calldata /*data*/
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        // 現在のプール状態を取得（slot0: (sqrtPriceX96, tick, ...））
        (, int24 currentTick, , , , , ) = poolManager.getSlot0(poolId);

        // 範囲外かどうかを判定（下限または上限を外れている場合）
        bool outOfRange = (currentTick < params.tickLower || currentTick > params.tickUpper);
        isOutOfRange[poolId][sender] = outOfRange;

        if (outOfRange) {
            // どちらのトークンが idle 状態かを決定
            Currency idleCurrency;
            if (currentTick < params.tickLower) {
                idleCurrency = key.currency0;
            } else if (currentTick > params.tickUpper) {
                idleCurrency = key.currency1;
            }
            // 実際の実装では流動性提供者の残高等から計算するが、ここではヘルパー関数で仮の値を返す
            uint256 availableAmount = _estimateAvailableAmount(sender, poolId, idleCurrency);
            if (availableAmount > 0) {
                _depositToAave(sender, poolId, idleCurrency, availableAmount);
            }
        }
        return BaseHook.afterAddLiquidity.selector;
    }

    /// @notice 流動性削除前フック（ここでは特に前処理はなし）
    function beforeRemoveLiquidity(
        address /*sender*/,
        PoolKey calldata /*key*/,
        IPoolManager.ModifyLiquidityParams calldata /*params*/,
        bytes calldata /*data*/
    ) external override returns (bytes4) {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice 流動性削除後フック
     *         レンジ内に戻った場合、Aave に預けた資金をプールに戻すため引き出す
     */
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta /*delta*/,
        bytes calldata /*data*/
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        (, int24 currentTick, , , , , ) = poolManager.getSlot0(poolId);
        bool stillOutOfRange = (currentTick < params.tickLower || currentTick > params.tickUpper);
        isOutOfRange[poolId][sender] = stillOutOfRange;
        
        // レンジ内に戻っていれば、両通貨の Aave 預入金を引き出す
        if (!stillOutOfRange) {
            uint256 deposit0 = depositedAmount[poolId][sender][key.currency0];
            if (deposit0 > 0) {
                _withdrawFromAave(sender, poolId, key.currency0, deposit0);
            }
            uint256 deposit1 = depositedAmount[poolId][sender][key.currency1];
            if (deposit1 > 0) {
                _withdrawFromAave(sender, poolId, key.currency1, deposit1);
            }
        }
        return BaseHook.afterRemoveLiquidity.selector;
    }
    
    /**
     * @notice 外部から定期的に呼び出し、価格変動に応じて流動性状態を更新する
     * @param liquidityProvider 流動性提供者のアドレス
     * @param key プールキー
     * @param tickLower レンジ下限
     * @param tickUpper レンジ上限
     */
    function checkAndUpdateLiquidityStatus(
        address liquidityProvider,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper
    ) external {
        PoolId poolId = key.toId();
        (, int24 currentTick, , , , , ) = poolManager.getSlot0(poolId);
        bool wasOutOfRange = isOutOfRange[poolId][liquidityProvider];
        bool isNowOutOfRange = (currentTick < tickLower || currentTick > tickUpper);

        if (wasOutOfRange != isNowOutOfRange) {
            isOutOfRange[poolId][liquidityProvider] = isNowOutOfRange;
            if (isNowOutOfRange) {
                // idle トークンを決定
                Currency idleCurrency;
                if (currentTick < tickLower) {
                    idleCurrency = key.currency0;
                } else if (currentTick > tickUpper) {
                    idleCurrency = key.currency1;
                }
                uint256 availableAmount = _estimateAvailableAmount(liquidityProvider, poolId, idleCurrency);
                if (availableAmount > 0) {
                    _depositToAave(liquidityProvider, poolId, idleCurrency, availableAmount);
                }
            } else {
                // レンジ内に戻ったので、両通貨の Aave 預入金を引き出す
                uint256 deposit0 = depositedAmount[poolId][liquidityProvider][key.currency0];
                if (deposit0 > 0) {
                    _withdrawFromAave(liquidityProvider, poolId, key.currency0, deposit0);
                }
                uint256 deposit1 = depositedAmount[poolId][liquidityProvider][key.currency1];
                if (deposit1 > 0) {
                    _withdrawFromAave(liquidityProvider, poolId, key.currency1, deposit1);
                }
            }
        }
    }

    /// @dev Aave への預け入れ処理
    function _depositToAave(
        address sender,
        PoolId poolId,
        Currency currency,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        // プールマネージャーから資金を引き出し、このコントラクトに移す
        poolManager.take(currency, address(this), amount);
        // Aave 預け入れ前に承認
        IERC20(token).approve(address(lendingPool), amount);
        lendingPool.deposit(token, amount, sender, 0);
        // 預入額を記録
        depositedAmount[poolId][sender][currency] += amount;
    }

    /// @dev Aave からの引き出し処理
    function _withdrawFromAave(
        address sender,
        PoolId poolId,
        Currency currency,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        uint256 withdrawn = lendingPool.withdraw(token, amount, address(this));
        // 引き出した資金をプールマネージャーへ返すために承認
        IERC20(token).approve(address(poolManager), withdrawn);
        poolManager.settle(currency);
        // 記録のクリア
        depositedAmount[poolId][sender][currency] = 0;
    }

    /**
     * @dev 流動性提供者の idle トークン量を見積もる
     *      ※実運用では LP バランスやプール状態から正確な計算が必要となる
     */
    function _estimateAvailableAmount(
        address /*liquidityProvider*/,
        PoolId /*poolId*/,
        Currency /*currency*/
    ) internal view returns (uint256) {
        // デモ用：常に 1 ether を返す（実装時は正確な計算に置き換えること）
        return 1 ether;
    }
}

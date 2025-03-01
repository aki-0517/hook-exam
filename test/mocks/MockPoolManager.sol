// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../lib/v4-core/src/PoolManager.sol";
import {PoolId} from "../../lib/v4-core/src/types/PoolId.sol";

contract MockPoolManager is PoolManager {
    // slot0 の値を管理する構造体を定義（必要なフィールドは実装に合わせて変更してください）
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint8 feeProtocol;
        bool unlocked;
    }
    // PoolId ごとに slot0 を保持する mapping を宣言
    mapping(PoolId => Slot0) public slot0s;

    /**
     * @notice テスト用に slot0 の値を設定する関数
     * @param poolId 対象プールID
     * @param sqrtPriceX96 新しい sqrtPriceX96
     * @param tick 新しい tick 値
     */
    function setSlot0ForTest(PoolId poolId, uint160 sqrtPriceX96, int24 tick) external {
        slot0s[poolId] = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: 0,
            observationCardinalityNext: 0,
            feeProtocol: 0,
            unlocked: false
        });
    }
}

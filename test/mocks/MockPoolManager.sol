// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../lib/v4-core/src/PoolManager.sol";
import {PoolId} from "../../lib/v4-core/src/types/PoolId.sol";

contract MockPoolManager is PoolManager {
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint8 feeProtocol;
        bool unlocked;
    }
    mapping(PoolId => Slot0) public slot0s;

    // コンストラクタで msg.sender を初期オーナーとして渡す
    constructor() PoolManager(msg.sender) {}

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

    function getSlot0(PoolId poolId) public view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    ) {
        Slot0 memory s0 = slot0s[poolId];
        return (
            s0.sqrtPriceX96,
            s0.tick,
            s0.observationIndex,
            s0.observationCardinality,
            s0.observationCardinalityNext,
            s0.feeProtocol,
            s0.unlocked
        );
    }
}

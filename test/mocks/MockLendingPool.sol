// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "../../src/hooks/interfaces/ILendingPool.sol";

/**
 * @title MockLendingPool
 * @notice テスト用に Aave の deposit/withdraw 処理を模倣したモック
 */
contract MockLendingPool {
    // 預入金を追跡：利用者 => (資産アドレス => 金額)
    mapping(address => mapping(address => uint256)) public deposits;
    
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /*referralCode*/
    ) external {
        // 実際は ERC20 の transferFrom を行う（ここでは成功するものとする）
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        deposits[onBehalfOf][asset] += amount;
    }
    
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        uint256 availableAmount = deposits[msg.sender][asset];
        uint256 amountToWithdraw = amount > availableAmount ? availableAmount : amount;
        deposits[msg.sender][asset] -= amountToWithdraw;
        IERC20(asset).transfer(to, amountToWithdraw);
        return amountToWithdraw;
    }
}

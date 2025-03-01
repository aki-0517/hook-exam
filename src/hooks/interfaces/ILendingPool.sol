// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ILendingPool {
    /**
     * @notice 預け入れ： underlying 資産を預け、aToken を受け取る
     */
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /**
     * @notice 引き出し：aToken を燃焼させ underlying 資産を受け取る
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

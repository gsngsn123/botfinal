// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@aave/protocol-v2/contracts/flashloan/base/FlashLoanReceiverBase.sol";
import "@aave/protocol-v2/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import "@aave/protocol-v2/contracts/interfaces/ILendingPool.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract MEVExecutor is FlashLoanReceiverBase, Ownable {
    // Whitelisted tokens
    mapping(address => bool) public isTokenWhitelisted;

    // DEX routers
    address[] public dexRouters;

    event ProfitSent(address token, uint256 amount);
    event ArbitrageExecuted(address tokenIn, address tokenOut, uint256 amountIn, uint256 profit);

    constructor(address _addressProvider, address[] memory _dexRouters)
        FlashLoanReceiverBase(ILendingPoolAddressesProvider(_addressProvider))
    {
        dexRouters = _dexRouters;
    }

    // Flashloan entry point (called by Aave)
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(LENDING_POOL), "Only Lending Pool");
        require(initiator == address(this), "Invalid initiator");

        // Decode parameters
        (address tokenIn, address tokenOut, uint256 minProfit, uint256 routerIndex) = abi.decode(
            params,
            (address, address, uint256, uint256)
        );

        uint256 amountIn = amounts[0];
        address dex = dexRouters[routerIndex];

        IERC20(tokenIn).approve(dex, amountIn);
        address ;
        path[0] = tokenIn;
        path[1] = tokenOut;

        // First swap: tokenIn -> tokenOut
        uint256[] memory out1 = IUniswapV2Router02(dex).swapExactTokensForTokens(
            amountIn, 1, path, address(this), block.timestamp
        );

        // Second swap: tokenOut -> tokenIn (reverse)
        IERC20(tokenOut).approve(dex, out1[1]);
        path[0] = tokenOut;
        path[1] = tokenIn;

        uint256[] memory out2 = IUniswapV2Router02(dex).swapExactTokensForTokens(
            out1[1], 1, path, address(this), block.timestamp
        );

        uint256 finalAmount = out2[1];
        uint256 totalDebt = amountIn + premiums[0];

        require(finalAmount > totalDebt + minProfit, "No profit");
        emit ArbitrageExecuted(tokenIn, tokenOut, amountIn, finalAmount - totalDebt);

        // Repay Aave
        IERC20(tokenIn).approve(address(LENDING_POOL), totalDebt);

        // Send profit to owner
        uint256 profit = finalAmount - totalDebt;
        IERC20(tokenIn).transfer(owner(), profit);
        emit ProfitSent(tokenIn, profit);

        return true;
    }

    // Trigger flashloan from off-chain bot
    function startFlashloan(
        address token,
        uint256 amount,
        address tokenOut,
        uint256 minProfit,
        uint256 routerIndex
    ) external onlyOwner {
        require(isTokenWhitelisted[token] && isTokenWhitelisted[tokenOut], "Token not allowed");

        address ;
        assets[0] = token;

        uint256 ;
        amounts[0] = amount;

        uint256 ;
        modes[0] = 0; // full repayment

        bytes memory params = abi.encode(token, tokenOut, minProfit, routerIndex);

        LENDING_POOL.flashLoan(
            address(this), assets, amounts, modes, address(this), params, 0
        );
    }

    // Admin functions
    function addDEX(address router) external onlyOwner {
        dexRouters.push(router);
    }

    function whitelistToken(address token, bool status) external onlyOwner {
        isTokenWhitelisted[token] = status;
    }

    function getRouters() external view returns (address[] memory) {
        return dexRouters;
    }

    receive() external payable {}
}

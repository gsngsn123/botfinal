// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./uniswap/IUniswapV2Router02.sol";
import "./uniswap/v3/ISwapRouter.sol";

import "./dodo/IDODO.sol";
import "./dodo/IDODOProxy.sol";
import "./aave/IAaveLendingPool.sol";
import "./aave/IAaveProtocolDataProvider.sol";

import "./interfaces/IFlashloan.sol";
import "./base/FlashloanValidation.sol";
import "./base/DodoBase.sol";
import "./libraries/BytesLib.sol";

contract FlashloanMEVPolygon is IFlashloan, FlashloanValidation, DodoBase, Ownable {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    event SentProfit(address indexed recipient, uint256 amount);
    event SwapExecuted(address indexed token, uint256 amount);
    event LiquidationExecuted(address indexed collateralAsset, address indexed debtAsset, address target);
    event Failure(string reason);

    address public immutable AAVE_LENDING_POOL;
    address public immutable AAVE_DATA_PROVIDER;

    address[] public knownTokens;
    address[] public knownSpenders;

    constructor(address _lendingPool, address _dataProvider, address[] memory _tokens, address[] memory _spenders) Ownable(msg.sender) {
        AAVE_LENDING_POOL = _lendingPool;
        AAVE_DATA_PROVIDER = _dataProvider;
        knownTokens = _tokens;
        knownSpenders = _spenders;
        approveAllTokens();
    }

    function dodoFlashLoan(FlashParams memory params) external checkParams(params) {
        try this._executeFlashLoan(params) {} catch Error(string memory reason) {
            emit Failure(reason);
            revert(reason);
        } catch {
            emit Failure("Unknown error during dodoFlashLoan");
            revert("Unknown error during dodoFlashLoan");
        }
    }

    function _executeFlashLoan(FlashParams memory params) external {
        require(msg.sender == address(this), "Only callable internally");

        bytes memory data = abi.encode(
            FlashCallbackData({
                me: tx.origin,
                flashLoanPool: params.flashLoanPool,
                loanAmount: params.loanAmount,
                firstRoutes: params.firstRoutes,
                secondRoutes: params.secondRoutes
            })
        );

        address loanToken = params.firstRoutes[0].path[0];
        if (IDODO(params.flashLoanPool)._BASE_TOKEN_() == loanToken) {
            IDODO(params.flashLoanPool).flashLoan(params.loanAmount, 0, address(this), data);
        } else {
            IDODO(params.flashLoanPool).flashLoan(0, params.loanAmount, address(this), data);
        }
    }

    function _flashLoanCallBack(address, uint256, uint256, bytes calldata data) internal override {
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        address loanToken = decoded.firstRoutes[0].path[0];

        require(IERC20(loanToken).balanceOf(address(this)) >= decoded.loanAmount, "Loan not received");

        for (uint256 i = 0; i < decoded.firstRoutes.length; i++) {
            try this.pickProtocol(decoded.firstRoutes[i]) {} catch Error(string memory reason) {
                emit Failure(reason);
                revert(reason);
            } catch {
                emit Failure("Unknown error during first route");
                revert("Unknown error during first route");
            }
        }

        for (uint256 i = 0; i < decoded.secondRoutes.length; i++) {
            try this.pickProtocol(decoded.secondRoutes[i]) {} catch Error(string memory reason) {
                emit Failure(reason);
                revert(reason);
            } catch {
                emit Failure("Unknown error during second route");
                revert("Unknown error during second route");
            }
        }

        emit SwapExecuted(loanToken, IERC20(loanToken).balanceOf(address(this)));

        require(IERC20(loanToken).balanceOf(address(this)) >= decoded.loanAmount, "Insufficient balance to repay loan");
        IERC20(loanToken).safeTransfer(decoded.flashLoanPool, decoded.loanAmount);

        uint256 profit = IERC20(loanToken).balanceOf(address(this));
        if (profit > 0) {
            IERC20(loanToken).safeTransfer(decoded.me, profit);
            emit SentProfit(decoded.me, profit);
        }
    }

    function pickProtocol(Route memory route) external checkRouteProtocol(route) {
        if (route.protocol == 0) dodoSwap(route);
        else if (route.protocol == 1) uniswapV2(route);
        else if (route.protocol == 2) uniswapV3(route);
        else revert("Unknown protocol");
    }

    function uniswapV2(Route memory route) internal returns (uint256[] memory) {
        uint256 amountIn = IERC20(route.path[0]).balanceOf(address(this));
        approveToken(route.path[0], route.pool, amountIn);
        return IUniswapV2Router02(route.pool).swapExactTokensForTokens(amountIn, 1, route.path, address(this), block.timestamp);
    }

    function uniswapV3(Route memory route) internal returns (uint256 amountOut) {
        address inputToken = route.path[0];
        uint256 amountIn = IERC20(inputToken).balanceOf(address(this));
        ISwapRouter swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
        approveToken(inputToken, address(swapRouter), amountIn);

        if (route.path.length == 2) {
            amountOut = swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: inputToken,
                    tokenOut: route.path[1],
                    fee: route.fee[0],
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        } else {
            bytes memory tokenFee;
            for (uint8 i = 0; i < route.path.length - 1; i++) {
                tokenFee = tokenFee.merge(abi.encodePacked(route.path[i], route.fee[i]));
            }
            amountOut = swapRouter.exactInput(
                ISwapRouter.ExactInputParams({
                    path: tokenFee.merge(abi.encodePacked(route.path[route.path.length - 1])),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0
                })
            );
        }
    }

    function dodoSwap(Route memory route) internal {
        address fromToken = route.path[0];
        address toToken = route.path[1];
        uint256 amountIn = IERC20(fromToken).balanceOf(address(this));
        approveToken(fromToken, 0x6D310348d5c12009854DFCf72e0DF9027e8cb4f4, amountIn);
        address[] memory dodoPairs = new address[](1);
        dodoPairs[0] = route.pool;

        uint256 direction = IDODO(route.pool)._BASE_TOKEN_() == fromToken ? 0 : 1;
        address dodoProxy = 0xa222e6a71D1A1Dd5F279805fbe38d5329C1d0e70;

        IDODOProxy(dodoProxy).dodoSwapV2TokenToToken(fromToken, toToken, amountIn, 1, dodoPairs, direction, false, block.timestamp);
    }

    function approveToken(address token, address spender, uint256 amount) internal {
        IERC20 tokenInterface = IERC20(token);
        tokenInterface.forceApprove(spender, 0);
        tokenInterface.forceApprove(spender, amount);
    }

    /**
     * @dev Add new tokens to the knownTokens list
     * @param tokens Array of token addresses to add
     */
    function addKnownTokens(address[] memory tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            bool exists = false;
            for (uint j = 0; j < knownTokens.length; j++) {
                if (knownTokens[j] == tokens[i]) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                knownTokens.push(tokens[i]);
            }
        }
    }

    /**
     * @dev Add new spenders to the knownSpenders list
     * @param spenders Array of spender addresses to add
     */
    function addKnownSpenders(address[] memory spenders) external onlyOwner {
        for (uint i = 0; i < spenders.length; i++) {
            bool exists = false;
            for (uint j = 0; j < knownSpenders.length; j++) {
                if (knownSpenders[j] == spenders[i]) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                knownSpenders.push(spenders[i]);
            }
        }
    }

    function approveAllTokens() public onlyOwner {
        for (uint i = 0; i < knownTokens.length; i++) {
            for (uint j = 0; j < knownSpenders.length; j++) {
                approveToken(knownTokens[i], knownSpenders[j], type(uint256).max);
            }
        }
    }

    function liquidate(address user, address collateralAsset, address debtAsset) external onlyOwner {
        (
            ,  // currentATokenBalance
            ,  // currentStableDebt
            uint256 debtToCover, // currentVariableDebt
            ,  // principalStableDebt
            ,  // scaledVariableDebt
            ,  // stableBorrowRate
            ,  // liquidityRate
            ,  // stableRateLastUpdated
            // usageAsCollateralEnabled
        ) = IAaveProtocolDataProvider(AAVE_DATA_PROVIDER).getUserReserveData(debtAsset, user);
        
        IERC20 debtToken = IERC20(debtAsset);
        debtToken.forceApprove(AAVE_LENDING_POOL, 0);
        debtToken.forceApprove(AAVE_LENDING_POOL, debtToCover);
        IAaveLendingPool(AAVE_LENDING_POOL).liquidationCall(collateralAsset, debtAsset, user, debtToCover, false);

        emit LiquidationExecuted(collateralAsset, debtAsset, user);
    }
    
    /**
     * @dev Test function to simulate sending profits to a user
     * This is for testing purposes only and would not be included in production
     * @param recipient Address to receive the tokens
     * @param token Token to send
     * @param amount Amount to send
     */
    function testSendProfit(address recipient, address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(recipient, amount);
        emit SentProfit(recipient, amount);
    }
}

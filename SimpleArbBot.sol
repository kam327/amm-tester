// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.2 <=0.8.19;

import "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";

interface ITestExchange {
    function swapForEth(uint _amountERC20Token) external returns (uint);
    function estimateSwapForEth(uint _amountERC20Token) external view returns (uint);
    function swapForERC20Token() external payable returns (uint);
    function estimateSwapForERC20Token(uint _amountEth) external view returns (uint);
}

/*
 * SimpleArbBot
 *
 * Strategy (single token, many pools):
 *   1. Ask every pool "how many tokens would I get for X ETH?" (buy side)
 *   2. Ask every OTHER pool "how much ETH would I get for those tokens?" (sell side)
 *   3. If sell ETH > X, buy in the first pool and sell in the second.
 *
 * Safety: the whole trade is atomic. If the final ETH balance is not higher than
 * the starting balance, the transaction reverts, so a lying estimator or a pool
 * that changed under us costs only gas.
 *
 * Fund it by sending ETH to the contract address.
 * A contract cannot trigger itself: run bot.js (or any script) to call run() in a loop.
 */
contract SimpleArbBot {
    address public owner;
    mapping(address => address[]) internal _pools; // token => exchanges

    event Arbitraged(address indexed token, address buyPool, address sellPool, uint ethIn, uint profit);

    modifier onlyOwner() {
        require(msg.sender == owner, "owner only");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    // ------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------

    function setPools(address token, address[] calldata list) external onlyOwner {
        _pools[token] = list;
    }

    function getPools(address token) external view returns (address[] memory) {
        return _pools[token];
    }

    // ------------------------------------------------------------
    // Opportunity search (view: free to call every few seconds)
    // ------------------------------------------------------------

    function _estBuy(address ex, uint eth) internal view returns (uint) {
        try ITestExchange(ex).estimateSwapForERC20Token(eth) returns (uint v) { return v; }
        catch { return 0; }
    }

    function _estSell(address ex, uint tokens) internal view returns (uint) {
        try ITestExchange(ex).estimateSwapForEth(tokens) returns (uint v) { return v; }
        catch { return 0; }
    }

    function _bestForSize(address[] memory list, uint size)
        internal view returns (address bestB, address bestS, uint bestP)
    {
        for (uint i = 0; i < list.length; i++) {
            uint tokensOut = _estBuy(list[i], size);
            if (tokensOut == 0) continue;
            for (uint j = 0; j < list.length; j++) {
                if (j == i) continue;
                uint ethOut = _estSell(list[j], tokensOut);
                if (ethOut > size && ethOut - size > bestP) {
                    bestB = list[i];
                    bestS = list[j];
                    bestP = ethOut - size;
                }
            }
        }
    }

    /* Tries trade sizes maxEth, maxEth/2, ... maxEth/32 and returns the most profitable. */
    function findBest(address token, uint maxEth)
        public view returns (address buyPool, address sellPool, uint ethIn, uint expectedProfit)
    {
        address[] memory list = _pools[token];
        for (uint i = 0; i < 6; i++) {
            uint size = maxEth >> i;
            if (size == 0) break;
            (address b, address s, uint p) = _bestForSize(list, size);
            if (p > expectedProfit) {
                buyPool = b;
                sellPool = s;
                ethIn = size;
                expectedProfit = p;
            }
        }
    }

    // ------------------------------------------------------------
    // Execution
    // ------------------------------------------------------------

    function _arb(address token, address buyPool, address sellPool, uint ethIn, uint minProfit)
        internal returns (uint profit)
    {
        uint startBal = address(this).balance;
        require(startBal >= ethIn, "Not enough ETH");

        uint t0 = IERC20(token).balanceOf(address(this));
        ITestExchange(buyPool).swapForERC20Token{value: ethIn}();
        uint got = IERC20(token).balanceOf(address(this)) - t0;

        require(IERC20(token).approve(sellPool, got), "approve failed");
        ITestExchange(sellPool).swapForEth(got);

        uint endBal = address(this).balance;
        require(endBal > startBal + minProfit, "No profit");
        profit = endBal - startBal;
        emit Arbitraged(token, buyPool, sellPool, ethIn, profit);
    }

    /* Anyone can call: it uses the bot's ETH but reverts unless it ends up richer. */
    function run(address token, uint maxEth) external returns (uint profit) {
        uint cap = maxEth > address(this).balance ? address(this).balance : maxEth;
        (address b, address s, uint ethIn, uint expected) = findBest(token, cap);
        require(expected > 0, "No arbitrage");
        profit = _arb(token, b, s, ethIn, 0);
    }

    /* Manual version if you pick the pools yourself. */
    function arbitrage(address token, address buyPool, address sellPool, uint ethIn, uint minProfit)
        external onlyOwner returns (uint)
    {
        return _arb(token, buyPool, sellPool, ethIn, minProfit);
    }

    // ------------------------------------------------------------
    // Cash out
    // ------------------------------------------------------------

    function withdrawEth(uint amount) external onlyOwner {
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function withdrawToken(address token) external onlyOwner {
        uint bal = IERC20(token).balanceOf(address(this));
        require(IERC20(token).transfer(owner, bal), "transfer failed");
    }
}

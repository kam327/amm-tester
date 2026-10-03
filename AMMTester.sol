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
 * AMMTester v2
 *
 * Measures other students' AMMs. For every test it reports:
 *   - generous math : constant product, reserve rounded DOWN (trader-favourable)
 *   - strict math   : constant product, reserve rounded UP   (pool-favourable, the "correct" way)
 *   - estimator     : what the exchange's own estimateSwap* says
 *   - actual        : what the swap really paid
 *
 * Usage notes:
 *   - Token tests need approve(AMMTester, amount) on the ERC20 first.
 *   - Set the assignment's fee with setFeeBps (30 = 0.3% taken from the input). Default 0.
 *   - Leftover ETH / tokens are swept back to msg.sender at the end of each test.
 */
contract AMMTester {
    uint public feeBps;

    event SwapCompare(string label, uint generousMath, uint strictMath, uint estimator, uint actual);
    event InvariantCheck(string label, uint kBefore, uint kAfter, bool kNotDecreased);
    event RoundTrip(string label, uint startAmount, uint endAmount, bool profitable);
    event RepeatedTest(string label, uint totalInput, uint rounds, uint singleTrade, uint estimator, uint repeated);
    event EdgeCase(string label, uint amountIn, bool succeeded, uint received);

    receive() external payable {}

    function setFeeBps(uint _feeBps) external {
        require(_feeBps < 10000, "fee too high");
        feeBps = _feeBps;
    }

    // ------------------------------------------------------------
    // Math + reserve helpers
    // ------------------------------------------------------------

    function _reserves(address ex, address tok) internal view returns (uint t, uint e) {
        t = IERC20(tok).balanceOf(ex);
        e = ex.balance;
        require(t > 0 && e > 0, "Empty pool");
    }

    function _k(address ex, address tok) internal view returns (uint) {
        (uint t, uint e) = _reserves(ex, tok);
        return t * e;
    }

    function _out(uint rIn, uint rOut, uint amtIn, bool poolFavourable) internal view returns (uint) {
        uint inAfterFee = (amtIn * (10000 - feeBps)) / 10000;
        uint k = rIn * rOut;
        uint newIn = rIn + inAfterFee;
        uint newOut = poolFavourable ? (k + newIn - 1) / newIn : k / newIn;
        return rOut > newOut ? rOut - newOut : 0;
    }

    function calcTokenToEth(address ex, address tok, uint amt)
        public view returns (uint generous, uint strict)
    {
        (uint t, uint e) = _reserves(ex, tok);
        generous = _out(t, e, amt, false);
        strict = _out(t, e, amt, true);
    }

    function calcEthToToken(address ex, address tok, uint amt)
        public view returns (uint generous, uint strict)
    {
        (uint t, uint e) = _reserves(ex, tok);
        generous = _out(e, t, amt, false);
        strict = _out(e, t, amt, true);
    }

    function _estTE(address ex, uint amt) internal view returns (uint) {
        try ITestExchange(ex).estimateSwapForEth(amt) returns (uint v) { return v; }
        catch { return 0; }
    }

    function _estET(address ex, uint amt) internal view returns (uint) {
        try ITestExchange(ex).estimateSwapForERC20Token(amt) returns (uint v) { return v; }
        catch { return 0; }
    }

    function _pullAndApprove(address ex, address tok, uint amt) internal {
        require(IERC20(tok).transferFrom(msg.sender, address(this), amt), "transferFrom failed");
        require(IERC20(tok).approve(ex, amt), "approve failed");
    }

    function _sendEth(address to, uint amt) internal {
        if (amt == 0) return;
        (bool ok, ) = payable(to).call{value: amt}("");
        require(ok, "ETH return failed");
    }

    function _refundTokens(address tok) internal {
        uint bal = IERC20(tok).balanceOf(address(this));
        if (bal > 0) require(IERC20(tok).transfer(msg.sender, bal), "Token return failed");
    }

    // ------------------------------------------------------------
    // Read-only scanning (no gas, no state change)
    // ------------------------------------------------------------

    /* ETH-per-token spot price, scaled by 1e18. 0 = empty or broken pool. */
    function spotPrice(address ex, address tok) public view returns (uint) {
        uint t = IERC20(tok).balanceOf(ex);
        uint e = ex.balance;
        if (t == 0 || e == 0) return 0;
        return (e * 1e18) / t;
    }

    function scanPools(address tok, address[] calldata exs)
        external view returns (uint[] memory prices, uint[] memory ethReserves, uint[] memory tokenReserves)
    {
        prices = new uint[](exs.length);
        ethReserves = new uint[](exs.length);
        tokenReserves = new uint[](exs.length);
        for (uint i = 0; i < exs.length; i++) {
            prices[i] = spotPrice(exs[i], tok);
            ethReserves[i] = exs[i].balance;
            tokenReserves[i] = IERC20(tok).balanceOf(exs[i]);
        }
    }

    function compareTokenToEth(address ex, address tok, uint amt)
        external view returns (uint generous, uint strict, uint estimator)
    {
        (generous, strict) = calcTokenToEth(ex, tok, amt);
        estimator = _estTE(ex, amt);
    }

    function compareEthToToken(address ex, address tok, uint amt)
        external view returns (uint generous, uint strict, uint estimator)
    {
        (generous, strict) = calcEthToToken(ex, tok, amt);
        estimator = _estET(ex, amt);
    }

    // ------------------------------------------------------------
    // Real swaps: math vs estimator vs actual, plus k-invariant check
    // ------------------------------------------------------------

    function testTokenToEth(address ex, address tok, uint amt) external returns (uint actual) {
        uint kBefore = _k(ex, tok);
        (uint gen, uint strict) = calcTokenToEth(ex, tok, amt);
        uint est = _estTE(ex, amt);

        _pullAndApprove(ex, tok, amt);
        uint ethBefore = address(this).balance;
        ITestExchange(ex).swapForEth(amt);
        actual = address(this).balance - ethBefore;

        emit SwapCompare("token->eth", gen, strict, est, actual);
        uint kAfter = _k(ex, tok);
        emit InvariantCheck("token->eth", kBefore, kAfter, kAfter >= kBefore);

        _sendEth(msg.sender, actual);
        _refundTokens(tok);
    }

    function testEthToToken(address ex, address tok) external payable returns (uint actual) {
        require(msg.value > 0, "Send ETH");
        uint kBefore = _k(ex, tok);
        (uint gen, uint strict) = calcEthToToken(ex, tok, msg.value);
        uint est = _estET(ex, msg.value);

        uint tokBefore = IERC20(tok).balanceOf(address(this));
        ITestExchange(ex).swapForERC20Token{value: msg.value}();
        actual = IERC20(tok).balanceOf(address(this)) - tokBefore;

        emit SwapCompare("eth->token", gen, strict, est, actual);
        uint kAfter = _k(ex, tok);
        emit InvariantCheck("eth->token", kBefore, kAfter, kAfter >= kBefore);

        require(IERC20(tok).transfer(msg.sender, actual), "Token return failed");
    }

    // ------------------------------------------------------------
    // Round trips: do we end with MORE than we started with?
    // ------------------------------------------------------------

    /* tokens -> ETH -> tokens */
    function testRoundTripTokenFirst(address ex, address tok, uint tokenAmt)
        external returns (uint endTokens)
    {
        require(tokenAmt > 0, "Amount is zero");
        _pullAndApprove(ex, tok, tokenAmt);

        uint ethBefore = address(this).balance;
        ITestExchange(ex).swapForEth(tokenAmt);
        uint ethGot = address(this).balance - ethBefore;
        require(ethGot > 0, "First leg returned 0");

        uint tokBefore = IERC20(tok).balanceOf(address(this));
        ITestExchange(ex).swapForERC20Token{value: ethGot}();
        endTokens = IERC20(tok).balanceOf(address(this)) - tokBefore;

        emit RoundTrip("token->eth->token", tokenAmt, endTokens, endTokens > tokenAmt);
        _refundTokens(tok);
    }

    /* ETH -> tokens -> ETH */
    function testRoundTripEthFirst(address ex, address tok)
        external payable returns (uint endEth)
    {
        require(msg.value > 0, "Send ETH");
        uint preBal = address(this).balance - msg.value;

        uint tokBefore = IERC20(tok).balanceOf(address(this));
        ITestExchange(ex).swapForERC20Token{value: msg.value}();
        uint tokGot = IERC20(tok).balanceOf(address(this)) - tokBefore;
        require(tokGot > 0, "First leg returned 0");

        require(IERC20(tok).approve(ex, tokGot), "approve failed");
        ITestExchange(ex).swapForEth(tokGot);
        endEth = address(this).balance - preBal;

        emit RoundTrip("eth->token->eth", msg.value, endEth, endEth > msg.value);
        _sendEth(msg.sender, endEth);
    }

    // ------------------------------------------------------------
    // Rounding tests: one big trade vs many tiny trades
    // ------------------------------------------------------------

    function testRepeatedTokenToEth(address ex, address tok, uint amountPerTrade, uint rounds)
        external returns (uint singleTrade, uint repeated)
    {
        require(rounds > 1 && rounds <= 100, "rounds 2..100");
        require(amountPerTrade > 0, "Amount is zero");
        uint total = amountPerTrade * rounds;

        (singleTrade, ) = calcTokenToEth(ex, tok, total);
        uint est = _estTE(ex, total);

        _pullAndApprove(ex, tok, total);
        uint ethBefore = address(this).balance;
        for (uint i = 0; i < rounds; i++) {
            ITestExchange(ex).swapForEth(amountPerTrade);
        }
        repeated = address(this).balance - ethBefore;

        emit RepeatedTest("token->eth", total, rounds, singleTrade, est, repeated);
        _sendEth(msg.sender, repeated);
        _refundTokens(tok);
    }

    function testRepeatedEthToToken(address ex, address tok, uint amountPerTrade, uint rounds)
        external payable returns (uint singleTrade, uint repeated)
    {
        require(rounds > 1 && rounds <= 100, "rounds 2..100");
        require(amountPerTrade > 0, "Amount is zero");
        uint total = amountPerTrade * rounds;
        require(msg.value == total, "msg.value must equal amountPerTrade*rounds");

        (singleTrade, ) = calcEthToToken(ex, tok, total);
        uint est = _estET(ex, total);

        uint tokBefore = IERC20(tok).balanceOf(address(this));
        for (uint i = 0; i < rounds; i++) {
            ITestExchange(ex).swapForERC20Token{value: amountPerTrade}();
        }
        repeated = IERC20(tok).balanceOf(address(this)) - tokBefore;

        emit RepeatedTest("eth->token", total, rounds, singleTrade, est, repeated);
        require(IERC20(tok).transfer(msg.sender, repeated), "Token return failed");
    }

    // ------------------------------------------------------------
    // Edge cases: failures are caught and reported, not reverted.
    // Try amt = 0, 1, reserve-1, reserve, reserve*2, ...
    // ------------------------------------------------------------

    function testEdgeTokenToEth(address ex, address tok, uint amt) external returns (bool ok) {
        _pullAndApprove(ex, tok, amt);
        uint ethBefore = address(this).balance;
        try ITestExchange(ex).swapForEth(amt) returns (uint) { ok = true; }
        catch { ok = false; }
        uint got = address(this).balance - ethBefore;

        emit EdgeCase("token->eth", amt, ok, got);
        _sendEth(msg.sender, got);
        _refundTokens(tok);
    }

    function testEdgeEthToToken(address ex, address tok) external payable returns (bool ok) {
        uint preBal = address(this).balance - msg.value;
        uint tokBefore = IERC20(tok).balanceOf(address(this));
        try ITestExchange(ex).swapForERC20Token{value: msg.value}() returns (uint) { ok = true; }
        catch { ok = false; }
        uint got = IERC20(tok).balanceOf(address(this)) - tokBefore;

        emit EdgeCase("eth->token", msg.value, ok, got);
        _sendEth(msg.sender, address(this).balance - preBal); // refund ETH if swap failed
        _refundTokens(tok);
    }
}

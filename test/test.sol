pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Gateway} from "../src/Gateway.sol";
import {GatewayProxy} from "../src/GatewayProxy.sol";
import {AgentExecutor} from "../src/AgentExecutor.sol";
import {Initializer} from "../src/Initializer.sol";
import {IGatewayV1} from "../src/v1/IGateway.sol";
import {MultiAddress, Kind} from "../src/v1/MultiAddress.sol";
import {ParaID} from "../src/v1/Types.sol";
import {OperatingMode} from "../src/types/Common.sol";
import {UD60x18} from "prb/math/src/UD60x18.sol";

contract Dummy {}

contract MultiAddressLenVulnTest is Test {
    IGatewayV1 public gateway;
    GatewayProxy public proxy;
    AgentExecutor public executor;

    bytes32 constant EVT_OUTBOUND =
        keccak256("OutboundMessageAccepted(bytes32,uint64,bytes32,bytes)");

    function setUp() public {
        executor = new AgentExecutor();
        Dummy beefy = new Dummy();

        Gateway logic = new Gateway(address(beefy), address(executor));

        Initializer.Config memory cfg = Initializer.Config({
            mode: OperatingMode.Normal,
            deliveryCost: 0,
            exchangeRate: UD60x18.wrap(0),
            assetHubCreateAssetFee: 0,
            assetHubReserveTransferFee: 0,
            registerTokenFee: 0,
            multiplier: UD60x18.wrap(0),
            foreignTokenDecimals: 10,
            maxDestinationFee: type(uint128).max
        });

        proxy = new GatewayProxy(address(logic), abi.encode(cfg));

        gateway = IGatewayV1(address(proxy));
    }

    /// exploit 1: kind=Address32 but data.length=20 -> right padding to 32 bytes (wrong AccountId32)
    function test_Address32_RightPadding_Misdelivery() public {
        // malformed MultiAddress: Address32 with only 20 bytes
        bytes20 raw20 = bytes20(keccak256("bob-substrate-account-20B"));
        MultiAddress memory bad;
        bad.kind = Kind.Address32;
        bad.data = abi.encodePacked(raw20); // len = 20, NOT 32

        // destination = AssetHub (ParaID 1000) → Address32 branch in CallsV1._sendNativeTokenOrEther
        ParaID assetHub = ParaID.wrap(1000);

        uint128 amount = 1e15; // 0.001 ETH
        vm.recordLogs();

        gateway.sendToken{value: amount}(
            address(0),       
            assetHub,        
            bad,              
            0,                
            amount
        );

        (uint64 nonce, bytes memory payload) = _findOutboundAndDecode();
        assertEq(nonce, 1, "first outbound nonce should be 1");

        // substrateTypes.SendTokenToAssetHubAddress32 layout (see library)
        // [0]=0x00, [1..8]=u64 chainID, [9]=0x01, [10..29]=H160 token, [30]=0x00, [31..62]=recipient (32B)
        bytes32 recipient = _readBytes32(payload, 31);

         // right‑padding: 20B user input || 12 zero bytes
        bytes32 expectedPadded = bytes32(bytes.concat(raw20, bytes12(0)));
        assertEq(recipient, expectedPadded, "recipient must be right-padded 32B (silent mutation)");

        // nd in solidity, bytes32(bytes20) produces the same right‑padded value:
        assertEq(recipient, bytes32(raw20), "recipient equals bytes32(raw20) (right-padded)");
    }

    /// exploit 2: kind=Address20 but data.length=32 -> truncate to first 20 bytes (wrong H160)
    function test_Address20_Truncation_Misdelivery() public {
        // malformed MultiAddress: Address20 with 32 bytes → will be truncated
        bytes32 raw32 = keccak256("alice-evm-h160-truncation-case");
        MultiAddress memory bad20;
        bad20.kind = Kind.Address20;
        bad20.data = abi.encodePacked(raw32); // *** len = 32, NOT 20 ***

        // destination ≠ AssetHub -> Address20 branch in CallsV1._sendNativeTokenOrEther
        ParaID destPara = ParaID.wrap(2000);
        uint128 destXcmFee = 1;

        uint128 amount = 5e14; // 0.0005 ETH
        vm.recordLogs();

        gateway.sendToken{value: amount}(
            address(0),
            destPara,
            bad20,
            destXcmFee,
            amount
        );

        (uint64 nonce, bytes memory payload) = _findOutboundAndDecode();
        assertEq(nonce, 1, "first outbound nonce should be 1");

        // substrateTypes.SendTokenToAddress20 layout
        // [0]=0x00, [1..8]=u64 chainID, [9]=0x01, [10..29]=H160 token, [30]=0x02, [31..34]=u32 paraID, [35..54]=recipient (20B)
        bytes20 recipient = _readBytes20(payload, 35);

        // expected: truncated to the first 20B of raw32
        bytes20 expectedTruncated = bytes20(raw32);
        assertEq(recipient, expectedTruncated, "recipient must be truncated to 20B (silent mutation)");
    }

    // ---------- helpers ----------

    function _findOutboundAndDecode() internal returns (uint64 nonce, bytes memory payload) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            // event emitted by the proxy (delegatecall)
            if (entries[i].emitter == address(proxy) && entries[i].topics.length > 0
                && entries[i].topics[0] == EVT_OUTBOUND
            ) {
                // data = abi.encode(nonce, payload); both indexed topics are channelID & messageID
                (nonce, payload) = abi.decode(entries[i].data, (uint64, bytes));
                return (nonce, payload);
            }
        }
        fail("OutboundMessageAccepted not found");
    }

    function _readBytes32(bytes memory data, uint256 index) internal pure returns (bytes32 r) {
        require(data.length >= index + 32, "oob32");
        assembly {
            r := mload(add(add(data, 32), index))
        }
    }

    function _readBytes20(bytes memory data, uint256 index) internal pure returns (bytes20 r) {
        require(data.length >= index + 20, "oob20");
        assembly {
            r := mload(add(add(data, 32), index))
        }
    }
}







root@Gandhi:/home/gajnithehero/Desktop/snowbridge/contracts# forge test -vvvv  --match-path test/test.sol
[⠊] Compiling...
No files changed, compilation skipped

Ran 2 tests for test/test.sol:MultiAddressLenVulnTest
[PASS] test_Address20_Truncation_Misdelivery() (gas: 109944)
Traces:
  [109944] MultiAddressLenVulnTest::test_Address20_Truncation_Misdelivery()
    ├─ [0] VM::recordLogs()
    │   └─ ← [Return]
    ├─ [86753] GatewayProxy::fallback{value: 500000000000000}(0x0000000000000000000000000000000000000000, 2000, MultiAddress({ kind: 2, data: 0x3e7232c0af3ebe487067a429bb7188faa84427d5a441c17d8cd381712c4df110 }), 1, 500000000000000 [5e14])
    │   ├─ [81836] Gateway::sendToken{value: 500000000000000}(0x0000000000000000000000000000000000000000, 2000, MultiAddress({ kind: 2, data: 0x3e7232c0af3ebe487067a429bb7188faa84427d5a441c17d8cd381712c4df110 }), 1, 500000000000000 [5e14]) [delegatecall]
    │   │   ├─ [77358] CallsV1::99056fcc{value: 500000000000000}(00000000000000000000000000000000000000000000000000000000000000000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000007d000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000001c6bf526340000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000203e7232c0af3ebe487067a429bb7188faa84427d5a441c17d8cd381712c4df110) [delegatecall]
    │   │   │   ├─ emit TokenSent(token: 0x0000000000000000000000000000000000000000, sender: MultiAddressLenVulnTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], destinationChain: 2000, destinationAddress: MultiAddress({ kind: 2, data: 0x3e7232c0af3ebe487067a429bb7188faa84427d5a441c17d8cd381712c4df110 }), amount: 500000000000000 [5e14])
    │   │   │   ├─ [55] Agent::receive{value: 500000000000000}()
    │   │   │   │   └─ ← [Stop]
    │   │   │   ├─ emit OutboundMessageAccepted(channelID: 0xc173fac324158e77fb5840738a1a541f633cbec8884c6a601c567d2b376a0539, nonce: 1, messageID: 0x5f7060e971b0dc81e63f0aa41831091847d97c1a4693ac450cc128c7214e65e0, payload: 0x00697a00000000000001000000000000000000000000000000000000000002d00700003e7232c0af3ebe487067a429bb7188faa84427d50100000000000000000000000000000000406352bfc60100000000000000000000000000000000000000000000000000)
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Stop]
    │   └─ ← [Return]
    ├─ [0] VM::getRecordedLogs()
    │   └─ ← [Return] [([0x24c5d2de620c6e25186ae16f6919eba93b6e2c1a33857cc419d9f3a00d6967e9, 0x0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e1496, 0x00000000000000000000000000000000000000000000000000000000000007d0], 0x00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000001c6bf526340000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000203e7232c0af3ebe487067a429bb7188faa84427d5a441c17d8cd381712c4df110, 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9), ([0x7153f9357c8ea496bba60bf82e67143e27b64462b49041f8e689e1b05728f84f, 0xc173fac324158e77fb5840738a1a541f633cbec8884c6a601c567d2b376a0539, 0x5f7060e971b0dc81e63f0aa41831091847d97c1a4693ac450cc128c7214e65e0], 0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000006700697a00000000000001000000000000000000000000000000000000000002d00700003e7232c0af3ebe487067a429bb7188faa84427d50100000000000000000000000000000000406352bfc6010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000, 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9)]
    └─ ← [Stop]

[PASS] test_Address32_RightPadding_Misdelivery() (gas: 109067)
Traces:
  [109067] MultiAddressLenVulnTest::test_Address32_RightPadding_Misdelivery()
    ├─ [0] VM::recordLogs()
    │   └─ ← [Return]
    ├─ [85616] GatewayProxy::fallback{value: 1000000000000000}(0x0000000000000000000000000000000000000000, 1000, MultiAddress({ kind: 1, data: 0xc1e4aaf916519d3caaf564bcc4e050caa07f2036 }), 0, 1000000000000000 [1e15])
    │   ├─ [80699] Gateway::sendToken{value: 1000000000000000}(0x0000000000000000000000000000000000000000, 1000, MultiAddress({ kind: 1, data: 0xc1e4aaf916519d3caaf564bcc4e050caa07f2036 }), 0, 1000000000000000 [1e15]) [delegatecall]
    │   │   ├─ [76224] CallsV1::99056fcc{value: 1000000000000000}(00000000000000000000000000000000000000000000000000000000000000000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000003e800000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000038d7ea4c68000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000014c1e4aaf916519d3caaf564bcc4e050caa07f2036000000000000000000000000) [delegatecall]
    │   │   │   ├─ emit TokenSent(token: 0x0000000000000000000000000000000000000000, sender: MultiAddressLenVulnTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], destinationChain: 1000, destinationAddress: MultiAddress({ kind: 1, data: 0xc1e4aaf916519d3caaf564bcc4e050caa07f2036 }), amount: 1000000000000000 [1e15])
    │   │   │   ├─ [55] Agent::receive{value: 1000000000000000}()
    │   │   │   │   └─ ← [Stop]
    │   │   │   ├─ emit OutboundMessageAccepted(channelID: 0xc173fac324158e77fb5840738a1a541f633cbec8884c6a601c567d2b376a0539, nonce: 1, messageID: 0x5f7060e971b0dc81e63f0aa41831091847d97c1a4693ac450cc128c7214e65e0, payload: 0x00697a00000000000001000000000000000000000000000000000000000000c1e4aaf916519d3caaf564bcc4e050caa07f20360000000000000000000000000080c6a47e8d0300000000000000000000000000000000000000000000000000)
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Stop]
    │   └─ ← [Return]
    ├─ [0] VM::getRecordedLogs()
    │   └─ ← [Return] [([0x24c5d2de620c6e25186ae16f6919eba93b6e2c1a33857cc419d9f3a00d6967e9, 0x0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e1496, 0x00000000000000000000000000000000000000000000000000000000000003e8], 0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000038d7ea4c68000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000014c1e4aaf916519d3caaf564bcc4e050caa07f2036000000000000000000000000, 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9), ([0x7153f9357c8ea496bba60bf82e67143e27b64462b49041f8e689e1b05728f84f, 0xc173fac324158e77fb5840738a1a541f633cbec8884c6a601c567d2b376a0539, 0x5f7060e971b0dc81e63f0aa41831091847d97c1a4693ac450cc128c7214e65e0], 0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000005f00697a00000000000001000000000000000000000000000000000000000000c1e4aaf916519d3caaf564bcc4e050caa07f20360000000000000000000000000080c6a47e8d030000000000000000000000000000000000000000000000000000, 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9)]
    └─ ← [Stop]

Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 15.20ms (2.73ms CPU time)

Ran 1 test suite in 1.37s (15.20ms CPU time): 2 tests passed, 0 failed, 0 skipped (2 total tests)

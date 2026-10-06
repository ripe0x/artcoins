// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsAirdropV2} from "../../src/v2/extensions/ArtCoinsAirdropV2.sol";
import {ArtCoinsVaultV2} from "../../src/v2/extensions/ArtCoinsVaultV2.sol";
import {IArtCoinsAirdropV2} from "../../src/v2/extensions/interfaces/IArtCoinsAirdropV2.sol";
import {IArtCoinsVaultV2} from "../../src/v2/extensions/interfaces/IArtCoinsVaultV2.sol";
import {IArtCoinsExtensionV2} from "../../src/v2/interfaces/IArtCoinsExtensionV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract ExtMockCoin is ERC20 {
    constructor() ERC20("Coin", "COIN") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @dev Plays the factory: holds the coin, approves exactly the share, calls
///      `receiveTokens` with a config whose `extensions[idx]` is `entry`.
contract StubFactory {
    receive() external payable {}

    function launch(
        address ext,
        address token,
        IArtCoinsFactoryV2.ExtensionConfigV2[] memory entries,
        PoolKey memory key,
        address hook,
        uint256 share,
        uint256 idx
    ) external payable {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.extensions = entries;
        c.pool.hook = hook;
        if (share != 0) ERC20(token).approve(ext, share);
        IArtCoinsExtensionV2(ext).receiveTokens{value: msg.value}(c, key, token, share, idx);
        if (ERC20(token).allowance(address(this), ext) != 0) ERC20(token).approve(ext, 0);
    }
}

abstract contract ExtBase is Test {
    ExtMockCoin internal coin;
    StubFactory internal stub;
    PoolKey internal emptyKey;

    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant SUPPLY = 1000e18;

    function _baseSetUp() internal {
        vm.warp(T0);
        coin = new ExtMockCoin();
        stub = new StubFactory();
        coin.transfer(address(stub), 100_000_000e18);
    }

    function _entry(address ext, uint256 value, uint16 bps, bytes memory data)
        internal
        pure
        returns (IArtCoinsFactoryV2.ExtensionConfigV2 memory e)
    {
        e = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: ext, msgValue: value, extensionBps: bps, extensionData: data
        });
    }

    function _one(IArtCoinsFactoryV2.ExtensionConfigV2 memory e)
        internal
        pure
        returns (IArtCoinsFactoryV2.ExtensionConfigV2[] memory a)
    {
        a = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        a[0] = e;
    }

    function _two(
        IArtCoinsFactoryV2.ExtensionConfigV2 memory e0,
        IArtCoinsFactoryV2.ExtensionConfigV2 memory e1
    ) internal pure returns (IArtCoinsFactoryV2.ExtensionConfigV2[] memory a) {
        a = new IArtCoinsFactoryV2.ExtensionConfigV2[](2);
        a[0] = e0;
        a[1] = e1;
    }
}

contract AirdropV2Test is ExtBase {
    ArtCoinsAirdropV2 internal air;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal sweeper = makeAddr("sweeper");

    uint256 internal constant A_AMT = 100e18;
    uint256 internal constant B_AMT = 300e18;
    uint256 internal constant LOCK = 1 days;
    uint256 internal constant VEST = 10 days;

    bytes32 internal root;
    bytes32 internal leafA;
    bytes32 internal leafB;

    function setUp() public {
        _baseSetUp();
        air = new ArtCoinsAirdropV2(address(stub));
        (root, leafA, leafB) = _tree(alice, A_AMT, bob, B_AMT);
    }

    // OpenZeppelin StandardMerkleTree over ["address","uint256"], two leaves:
    // leaf = keccak(keccak(abi.encode(a, amt))), root = keccak(sorted pair).
    function _tree(address a, uint256 amtA, address b, uint256 amtB)
        internal
        pure
        returns (bytes32 r, bytes32 la, bytes32 lb)
    {
        la = keccak256(bytes.concat(keccak256(abi.encode(a, amtA))));
        lb = keccak256(bytes.concat(keccak256(abi.encode(b, amtB))));
        r = la < lb ? keccak256(abi.encodePacked(la, lb)) : keccak256(abi.encodePacked(lb, la));
    }

    function _data(address sweepTo, bytes32 r, uint256 lock, uint256 vest)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(sweepTo, r, lock, vest);
    }

    function _launch(bytes memory data, uint256 idx, uint256 value) internal {
        stub.launch{value: value}(
            address(air),
            address(coin),
            _one(_entry(address(air), 0, 1000, data)),
            emptyKey,
            address(0),
            SUPPLY,
            0
        );
        idx; // single entry launches always use index 0
    }

    function _launchOk() internal {
        _launch(_data(sweeper, root, LOCK, VEST), 0, 0);
    }

    function _proofA() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = leafB;
    }

    function _proofB() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = leafA;
    }

    // ── launch ────────────────────────────────────────────────────────────

    function test_launch_escrowsSupplyAndFreezesTranche() public {
        _launchOk();
        IArtCoinsAirdropV2.Tranche memory t = air.tranche(address(coin), 0);
        assertEq(coin.balanceOf(address(air)), SUPPLY);
        assertEq(t.supply, SUPPLY);
        assertEq(t.merkleRoot, root);
        assertEq(t.sweepRecipient, sweeper);
        assertEq(t.lockupEnd, T0 + LOCK);
        assertEq(t.vestingEnd, T0 + LOCK + VEST);
        assertEq(t.sweepTime, T0 + LOCK + VEST + 14 days);
        assertFalse(t.swept);
    }

    function test_launch_emptyRootReverts() public {
        vm.expectRevert(IArtCoinsAirdropV2.InvalidMerkleRoot.selector);
        _launch(_data(sweeper, bytes32(0), LOCK, VEST), 0, 0);
    }

    function test_launch_zeroSweepRecipientReverts() public {
        vm.expectRevert(IArtCoinsAirdropV2.ZeroSweepRecipient.selector);
        _launch(_data(address(0), root, LOCK, VEST), 0, 0);
    }

    function test_launch_sweepRecipientCannotBeTokenOrSelf() public {
        vm.expectRevert(IArtCoinsAirdropV2.ZeroSweepRecipient.selector);
        _launch(_data(address(coin), root, LOCK, VEST), 0, 0);
        vm.expectRevert(IArtCoinsAirdropV2.ZeroSweepRecipient.selector);
        _launch(_data(address(air), root, LOCK, VEST), 0, 0);
    }

    function test_launch_nonzeroMsgValueReverts() public {
        vm.deal(address(this), 1 ether);
        // entry says msgValue 0 but eth is forwarded
        IArtCoinsFactoryV2.ExtensionConfigV2[] memory e =
            _one(_entry(address(air), 0, 1000, _data(sweeper, root, LOCK, VEST)));
        vm.expectRevert(IArtCoinsExtensionV2.InvalidMsgValue.selector);
        stub.launch{value: 1}(address(air), address(coin), e, emptyKey, address(0), SUPPLY, 0);
        // entry says msgValue 1
        e = _one(_entry(address(air), 1, 1000, _data(sweeper, root, LOCK, VEST)));
        vm.expectRevert(IArtCoinsExtensionV2.InvalidMsgValue.selector);
        stub.launch{value: 1}(address(air), address(coin), e, emptyKey, address(0), SUPPLY, 0);
    }

    function test_launch_zeroBpsReverts() public {
        IArtCoinsFactoryV2.ExtensionConfigV2[] memory e =
            _one(_entry(address(air), 0, 0, _data(sweeper, root, LOCK, VEST)));
        vm.expectRevert(IArtCoinsAirdropV2.InvalidAirdropBps.selector);
        stub.launch(address(air), address(coin), e, emptyKey, address(0), SUPPLY, 0);
    }

    function test_launch_badDataLengthReverts() public {
        vm.expectRevert(IArtCoinsAirdropV2.InvalidExtensionData.selector);
        _launch(abi.encode(sweeper, root, LOCK), 0, 0);
    }

    function test_launch_durationTooLongReverts() public {
        uint256 big = air.MAX_DURATION() + 1;
        vm.expectRevert(IArtCoinsAirdropV2.DurationTooLong.selector);
        _launch(_data(sweeper, root, big, VEST), 0, 0);
        vm.expectRevert(IArtCoinsAirdropV2.DurationTooLong.selector);
        _launch(_data(sweeper, root, LOCK, big), 0, 0);
    }

    function test_launch_wrongExtensionEntryReverts() public {
        IArtCoinsFactoryV2.ExtensionConfigV2[] memory e =
            _one(_entry(address(0xdead), 0, 1000, _data(sweeper, root, LOCK, VEST)));
        vm.expectRevert(IArtCoinsAirdropV2.WrongExtensionEntry.selector);
        stub.launch(address(air), address(coin), e, emptyKey, address(0), SUPPLY, 0);
    }

    function test_launch_sameIndexTwiceReverts() public {
        _launchOk();
        vm.expectRevert(IArtCoinsAirdropV2.AirdropAlreadyExists.selector);
        _launchOk();
    }

    function test_nonFactoryCallerReverts() public {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.extensions = _one(_entry(address(air), 0, 1000, _data(sweeper, root, LOCK, VEST)));
        vm.expectRevert(IArtCoinsAirdropV2.Unauthorized.selector);
        air.receiveTokens(c, emptyKey, address(coin), SUPPLY, 0);
    }

    function test_constructor_zeroFactoryReverts() public {
        vm.expectRevert(IArtCoinsAirdropV2.ZeroAddress.selector);
        new ArtCoinsAirdropV2(address(0));
    }

    // ── A1: two tranches in one launch ────────────────────────────────────

    function test_A1_twoTranchesInOneLaunchAreIndependent() public {
        (bytes32 root2, bytes32 la2, bytes32 lb2) = _tree(alice, 7e18, bob, 9e18);
        IArtCoinsFactoryV2.ExtensionConfigV2[] memory e =
            new IArtCoinsFactoryV2.ExtensionConfigV2[](2);
        e[0] = _entry(address(air), 0, 1000, _data(sweeper, root, LOCK, VEST));
        e[1] = _entry(address(air), 0, 500, _data(makeAddr("sweeper2"), root2, 0, 0));
        stub.launch(address(air), address(coin), e, emptyKey, address(0), 600e18, 0);
        stub.launch(address(air), address(coin), e, emptyKey, address(0), 400e18, 1);

        assertEq(air.tranche(address(coin), 0).supply, 600e18);
        assertEq(air.tranche(address(coin), 1).supply, 400e18);
        assertEq(air.tranche(address(coin), 0).merkleRoot, root);
        assertEq(air.tranche(address(coin), 1).merkleRoot, root2);
        assertEq(coin.balanceOf(address(air)), 1000e18);

        // tranche 1 has no lockup and no vesting: alice claims her leaf at once
        bytes32[] memory p = new bytes32[](1);
        p[0] = lb2;
        air.claim(address(coin), 1, alice, 7e18, p);
        assertEq(coin.balanceOf(alice), 7e18);
        // the same proof against tranche 0 fails (different root)
        vm.warp(T0 + LOCK + VEST);
        vm.expectRevert(IArtCoinsAirdropV2.InvalidProof.selector);
        air.claim(address(coin), 0, alice, 7e18, p);
        la2;
    }

    // ── claims ────────────────────────────────────────────────────────────

    function test_claim_beforeLockupReverts() public {
        _launchOk();
        vm.expectRevert(IArtCoinsAirdropV2.AirdropNotUnlocked.selector);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());
    }

    function test_claim_happyPath_vestsLinearlyThenFull() public {
        _launchOk();
        // at lockup end nothing is vested yet
        vm.warp(T0 + LOCK);
        vm.expectRevert(IArtCoinsAirdropV2.ZeroToClaim.selector);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());

        // half way: half of each leaf
        vm.warp(T0 + LOCK + VEST / 2);
        assertEq(air.amountAvailableToClaim(address(coin), 0, alice, A_AMT), A_AMT / 2);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());
        assertEq(coin.balanceOf(alice), A_AMT / 2);
        assertEq(air.leafClaimed(address(coin), 0, alice, A_AMT), A_AMT / 2);

        // after vesting: the rest, anyone can trigger, funds go to the leaf address
        vm.warp(T0 + LOCK + VEST);
        vm.prank(makeAddr("stranger"));
        air.claim(address(coin), 0, alice, A_AMT, _proofA());
        assertEq(coin.balanceOf(alice), A_AMT);

        air.claim(address(coin), 0, bob, B_AMT, _proofB());
        assertEq(coin.balanceOf(bob), B_AMT);
        assertEq(air.tranche(address(coin), 0).totalClaimed, A_AMT + B_AMT);
    }

    function test_claim_doubleClaimReverts() public {
        _launchOk();
        vm.warp(T0 + LOCK + VEST);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());
        vm.expectRevert(IArtCoinsAirdropV2.UserMaxClaimed.selector);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());
    }

    function test_claim_sameInstantTwiceRevertsZero() public {
        _launchOk();
        vm.warp(T0 + LOCK + VEST / 2);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());
        vm.expectRevert(IArtCoinsAirdropV2.ZeroToClaim.selector);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());
    }

    function test_claim_wrongProofReverts() public {
        _launchOk();
        vm.warp(T0 + LOCK + VEST);
        // bob's proof for alice's leaf
        vm.expectRevert(IArtCoinsAirdropV2.InvalidProof.selector);
        air.claim(address(coin), 0, alice, A_AMT, _proofB());
        // right proof, inflated amount
        vm.expectRevert(IArtCoinsAirdropV2.InvalidProof.selector);
        air.claim(address(coin), 0, alice, A_AMT + 1, _proofA());
        // right proof, wrong recipient
        vm.expectRevert(IArtCoinsAirdropV2.InvalidProof.selector);
        air.claim(address(coin), 0, makeAddr("mallory"), A_AMT, _proofA());
        // empty proof
        vm.expectRevert(IArtCoinsAirdropV2.InvalidProof.selector);
        air.claim(address(coin), 0, alice, A_AMT, new bytes32[](0));
    }

    function test_claim_zeroAmountAndMissingTranche() public {
        _launchOk();
        vm.warp(T0 + LOCK + VEST);
        vm.expectRevert(IArtCoinsAirdropV2.ZeroClaim.selector);
        air.claim(address(coin), 0, alice, 0, _proofA());
        vm.expectRevert(IArtCoinsAirdropV2.AirdropNotCreated.selector);
        air.claim(address(coin), 5, alice, A_AMT, _proofA());
    }

    function test_leafHashMatchesStandardMerkleTreeEncoding() public view {
        assertEq(air.leafHash(alice, A_AMT), leafA);
        assertEq(
            air.leafHash(alice, A_AMT), keccak256(bytes.concat(keccak256(abi.encode(alice, A_AMT))))
        );
        // a single hashed leaf is NOT accepted: the second preimage / inner node attack
        assertTrue(air.leafHash(alice, A_AMT) != keccak256(abi.encode(alice, A_AMT)));
    }

    function test_claim_innerNodeCannotBeUsedAsLeaf() public {
        _launchOk();
        vm.warp(T0 + LOCK + VEST);
        // try to claim "leafA || leafB" as a 64 byte leaf: abi.encode(address, uint256) is 64 bytes
        // so an attacker would need an (address, amount) pair whose single hash is the root.
        // The double hash makes that infeasible; assert the root itself cannot be proven with no proof
        vm.expectRevert(IArtCoinsAirdropV2.InvalidProof.selector);
        air.claim(
            address(coin), 0, address(uint160(uint256(root))), uint256(root), new bytes32[](0)
        );
    }

    // ── A4: two leaves for one address ────────────────────────────────────

    function test_A4_twoLeavesForOneAddressBothPaid() public {
        bytes32 l1 = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(100e18)))));
        bytes32 l2 = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(50e18)))));
        bytes32 r =
            l1 < l2 ? keccak256(abi.encodePacked(l1, l2)) : keccak256(abi.encodePacked(l2, l1));
        _launch(_data(sweeper, r, 0, 0), 0, 0);
        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = l2;
        bytes32[] memory p2 = new bytes32[](1);
        p2[0] = l1;
        air.claim(address(coin), 0, alice, 100e18, p1);
        air.claim(address(coin), 0, alice, 50e18, p2);
        assertEq(coin.balanceOf(alice), 150e18);
    }

    function test_overAllocatedTreeIsCappedAtSupply() public {
        // leaves sum to 1300 but the tranche holds 1000
        (bytes32 r, bytes32 la, bytes32 lb) = _tree(alice, 700e18, bob, 600e18);
        _launch(_data(sweeper, r, 0, 0), 0, 0);
        bytes32[] memory pa = new bytes32[](1);
        pa[0] = lb;
        bytes32[] memory pb = new bytes32[](1);
        pb[0] = la;
        air.claim(address(coin), 0, alice, 700e18, pa);
        air.claim(address(coin), 0, bob, 600e18, pb);
        assertEq(coin.balanceOf(bob), 300e18); // capped
        vm.expectRevert(IArtCoinsAirdropV2.UserMaxClaimed.selector);
        air.claim(address(coin), 0, bob, 600e18, pb);
        assertEq(air.tranche(address(coin), 0).totalClaimed, SUPPLY);
    }

    // ── A2: nothing can replace the root ──────────────────────────────────

    function test_A2_noRootReplacementOrAdminFunctionExists() public {
        _launchOk();
        bytes32 newRoot = keccak256("attacker root");
        bytes[8] memory calls = [
            abi.encodeWithSignature("updateMerkleRoot(address,bytes32)", address(coin), newRoot),
            abi.encodeWithSignature("setMerkleRoot(address,bytes32)", address(coin), newRoot),
            abi.encodeWithSignature("updateAdmin(address,address)", address(coin), address(this)),
            abi.encodeWithSignature("adminClaim(address,address)", address(coin), address(this)),
            abi.encodeWithSignature(
                "setSweepRecipient(address,address)", address(coin), address(this)
            ),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature(
                "rescue(address,address,uint256)", address(coin), address(this), 1
            )
        ];
        // an attacker that is also the sweep recipient, a day after the lockup, with zero claims
        vm.warp(T0 + LOCK + 2 days);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(sweeper);
            (bool ok, bytes memory ret) = address(air).call(calls[i]);
            assertFalse(ok, "selector must not exist");
            assertEq(ret.length, 0, "no fallback, empty revert");
        }
        assertEq(air.tranche(address(coin), 0).merkleRoot, root);
        assertFalse(air.supportsInterface(bytes4(keccak256("updateMerkleRoot(address,bytes32)"))));
    }

    function test_A2_originalRootStillClaimsAfterOneDay() public {
        _launchOk();
        vm.warp(T0 + LOCK + 2 days);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());
        assertEq(coin.balanceOf(alice), A_AMT * 2 / 10);
    }

    // ── sweep ─────────────────────────────────────────────────────────────

    function test_sweep_beforeWindowEndsReverts() public {
        _launchOk();
        vm.warp(T0 + LOCK + VEST + 14 days - 1);
        vm.expectRevert(IArtCoinsAirdropV2.SweepNotReady.selector);
        air.sweep(address(coin), 0);
    }

    function test_sweep_afterWindowPaysFixedRecipientOnly() public {
        _launchOk();
        vm.warp(T0 + LOCK + VEST);
        air.claim(address(coin), 0, alice, A_AMT, _proofA());

        vm.warp(T0 + LOCK + VEST + 14 days);
        address caller = makeAddr("anyone");
        vm.prank(caller);
        air.sweep(address(coin), 0);
        assertEq(coin.balanceOf(sweeper), SUPPLY - A_AMT);
        assertEq(coin.balanceOf(caller), 0);
        assertEq(coin.balanceOf(address(air)), 0);

        vm.expectRevert(IArtCoinsAirdropV2.AlreadySwept.selector);
        air.sweep(address(coin), 0);
    }

    function test_sweep_closesClaims() public {
        _launchOk();
        vm.warp(T0 + LOCK + VEST + 14 days);
        vm.expectRevert(IArtCoinsAirdropV2.ClaimWindowClosed.selector);
        air.claim(address(coin), 0, bob, B_AMT, _proofB());
        assertEq(air.amountAvailableToClaim(address(coin), 0, bob, B_AMT), 0);
    }

    function test_sweep_missingTrancheReverts() public {
        vm.expectRevert(IArtCoinsAirdropV2.AirdropNotCreated.selector);
        air.sweep(address(coin), 3);
    }

    function test_sweep_onlyOwnTrancheFunds() public {
        // two tranches share the token balance; sweeping one leaves the other whole
        IArtCoinsFactoryV2.ExtensionConfigV2[] memory e =
            new IArtCoinsFactoryV2.ExtensionConfigV2[](2);
        e[0] = _entry(address(air), 0, 1000, _data(sweeper, root, 0, 0));
        e[1] = _entry(address(air), 0, 500, _data(makeAddr("s2"), root, 5 days, 0));
        stub.launch(address(air), address(coin), e, emptyKey, address(0), 600e18, 0);
        stub.launch(address(air), address(coin), e, emptyKey, address(0), 400e18, 1);
        vm.warp(T0 + 14 days);
        air.sweep(address(coin), 0);
        assertEq(coin.balanceOf(sweeper), 600e18);
        assertEq(coin.balanceOf(address(air)), 400e18);
        vm.expectRevert(IArtCoinsAirdropV2.SweepNotReady.selector);
        air.sweep(address(coin), 1);
    }

    // ── misc ──────────────────────────────────────────────────────────────

    function test_erc165AndConstants() public view {
        assertTrue(air.supportsInterface(type(IArtCoinsExtensionV2).interfaceId));
        assertTrue(air.supportsInterface(type(IConstantsBound).interfaceId));
        assertTrue(air.supportsInterface(type(IERC165).interfaceId));
        assertFalse(air.supportsInterface(0xffffffff));
        assertEq(air.constantsHash(), Constants.hash());
        assertEq(air.factory(), address(stub));
    }

    function testFuzz_claimNeverExceedsAllocationOrSupply(uint256 elapsed, uint96 amtA, uint96 amtB)
        public
    {
        amtA = uint96(bound(amtA, 1, SUPPLY));
        amtB = uint96(bound(amtB, 1, SUPPLY));
        (bytes32 r, bytes32 la, bytes32 lb) = _tree(alice, amtA, bob, amtB);
        _launch(_data(sweeper, r, LOCK, VEST), 0, 0);
        elapsed = bound(elapsed, LOCK, LOCK + VEST + 14 days - 1);
        vm.warp(T0 + elapsed);
        bytes32[] memory pa = new bytes32[](1);
        pa[0] = lb;
        bytes32[] memory pb = new bytes32[](1);
        pb[0] = la;
        try air.claim(address(coin), 0, alice, amtA, pa) {} catch {}
        try air.claim(address(coin), 0, bob, amtB, pb) {} catch {}
        assertLe(coin.balanceOf(alice), amtA);
        assertLe(coin.balanceOf(bob), amtB);
        assertLe(coin.balanceOf(alice) + coin.balanceOf(bob), SUPPLY);
        assertEq(
            air.tranche(address(coin), 0).totalClaimed, coin.balanceOf(alice) + coin.balanceOf(bob)
        );
    }
}

contract VaultV2Test is ExtBase {
    ArtCoinsVaultV2 internal vault;

    address internal ben = makeAddr("beneficiary");

    uint256 internal constant LOCK = 30 days;
    uint256 internal constant VEST = 100 days;

    function setUp() public {
        _baseSetUp();
        vault = new ArtCoinsVaultV2(address(stub));
    }

    function _data(address b, uint256 lock, uint256 vest) internal pure returns (bytes memory) {
        return abi.encode(b, lock, vest);
    }

    function _launch(bytes memory data) internal {
        stub.launch(
            address(vault),
            address(coin),
            _one(_entry(address(vault), 0, 2000, data)),
            emptyKey,
            address(0),
            SUPPLY,
            0
        );
    }

    function test_launch_escrowsAndFreezes() public {
        _launch(_data(ben, LOCK, VEST));
        IArtCoinsVaultV2.Allocation memory a = vault.allocation(address(coin), 0);
        assertEq(coin.balanceOf(address(vault)), SUPPLY);
        assertEq(a.beneficiary, ben);
        assertEq(a.amountTotal, SUPPLY);
        assertEq(a.amountClaimed, 0);
        assertEq(a.lockupEndTime, T0 + LOCK);
        assertEq(a.vestingEndTime, T0 + LOCK + VEST);
    }

    function test_vesting_cliffHalfFull() public {
        _launch(_data(ben, LOCK, VEST));

        // before the cliff
        vm.warp(T0 + LOCK - 1);
        assertEq(vault.amountAvailableToClaim(address(coin), 0), 0);
        vm.expectRevert(IArtCoinsVaultV2.AllocationNotUnlocked.selector);
        vault.claim(address(coin), 0);

        // at the cliff: linear vesting starts, nothing vested yet
        vm.warp(T0 + LOCK);
        assertEq(vault.amountAvailableToClaim(address(coin), 0), 0);
        vm.expectRevert(IArtCoinsVaultV2.NoBalanceToClaim.selector);
        vault.claim(address(coin), 0);

        // half way
        vm.warp(T0 + LOCK + VEST / 2);
        assertEq(vault.amountAvailableToClaim(address(coin), 0), SUPPLY / 2);
        vault.claim(address(coin), 0);
        assertEq(coin.balanceOf(ben), SUPPLY / 2);

        // full
        vm.warp(T0 + LOCK + VEST);
        assertEq(vault.amountAvailableToClaim(address(coin), 0), SUPPLY / 2);
        vm.prank(makeAddr("stranger"));
        vault.claim(address(coin), 0);
        assertEq(coin.balanceOf(ben), SUPPLY);
        assertEq(coin.balanceOf(address(vault)), 0);

        // long after: nothing left
        vm.warp(T0 + 5 * LOCK + 5 * VEST);
        vm.expectRevert(IArtCoinsVaultV2.NoBalanceToClaim.selector);
        vault.claim(address(coin), 0);
    }

    function test_claim_eventRemainingAmountIsTotalMinusClaimed() public {
        _launch(_data(ben, LOCK, VEST));
        vm.warp(T0 + LOCK + VEST / 4);
        vault.claim(address(coin), 0);
        vm.warp(T0 + LOCK + VEST / 2);
        vm.expectEmit(true, true, true, true);
        emit IArtCoinsVaultV2.AllocationClaimed(address(coin), 0, ben, SUPPLY / 4, SUPPLY / 2);
        vault.claim(address(coin), 0);
    }

    function test_V1_zeroBeneficiaryReverts() public {
        vm.expectRevert(IArtCoinsVaultV2.InvalidBeneficiary.selector);
        _launch(_data(address(0), LOCK, VEST));
    }

    function test_beneficiaryCannotBeTokenOrVault() public {
        vm.expectRevert(IArtCoinsVaultV2.InvalidBeneficiary.selector);
        _launch(_data(address(coin), LOCK, VEST));
        vm.expectRevert(IArtCoinsVaultV2.InvalidBeneficiary.selector);
        _launch(_data(address(vault), LOCK, VEST));
    }

    function test_durationBoundsRevert() public {
        vm.expectRevert(IArtCoinsVaultV2.VaultLockupDurationTooShort.selector);
        _launch(_data(ben, 7 days - 1, VEST));
        vm.expectRevert(IArtCoinsVaultV2.VaultVestingDurationTooShort.selector);
        _launch(_data(ben, LOCK, 90 days - 1));
        vm.expectRevert(IArtCoinsVaultV2.DurationTooLong.selector);
        _launch(_data(ben, vault.MAX_DURATION() + 1, VEST));
        // minimums are accepted
        _launch(_data(ben, 7 days, 90 days));
    }

    function test_launch_zeroBpsAndMsgValueAndDataRevert() public {
        vm.expectRevert(IArtCoinsVaultV2.InvalidVaultBps.selector);
        stub.launch(
            address(vault),
            address(coin),
            _one(_entry(address(vault), 0, 0, _data(ben, LOCK, VEST))),
            emptyKey,
            address(0),
            SUPPLY,
            0
        );
        vm.expectRevert(IArtCoinsExtensionV2.InvalidMsgValue.selector);
        stub.launch{value: 1}(
            address(vault),
            address(coin),
            _one(_entry(address(vault), 0, 2000, _data(ben, LOCK, VEST))),
            emptyKey,
            address(0),
            SUPPLY,
            0
        );
        vm.expectRevert(IArtCoinsVaultV2.InvalidExtensionData.selector);
        _launch(abi.encode(ben, LOCK));
    }

    function test_nonFactoryCallerReverts() public {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.extensions = _one(_entry(address(vault), 0, 2000, _data(ben, LOCK, VEST)));
        vm.expectRevert(IArtCoinsVaultV2.Unauthorized.selector);
        vault.receiveTokens(c, emptyKey, address(coin), SUPPLY, 0);
    }

    function test_wrongEntryAndDuplicateIndexRevert() public {
        vm.expectRevert(IArtCoinsVaultV2.WrongExtensionEntry.selector);
        stub.launch(
            address(vault),
            address(coin),
            _one(_entry(address(0xbeef), 0, 2000, _data(ben, LOCK, VEST))),
            emptyKey,
            address(0),
            SUPPLY,
            0
        );
        _launch(_data(ben, LOCK, VEST));
        vm.expectRevert(IArtCoinsVaultV2.AllocationAlreadyExists.selector);
        _launch(_data(ben, LOCK, VEST));
    }

    function test_twoVaultsOneLaunchAreIndependent() public {
        address ben2 = makeAddr("ben2");
        IArtCoinsFactoryV2.ExtensionConfigV2[] memory e = _two(
            _entry(address(vault), 0, 1000, _data(ben, LOCK, VEST)),
            _entry(address(vault), 0, 1000, _data(ben2, 8 days, 91 days))
        );
        stub.launch(address(vault), address(coin), e, emptyKey, address(0), 100e18, 0);
        stub.launch(address(vault), address(coin), e, emptyKey, address(0), 50e18, 1);
        vm.warp(T0 + 8 days + 91 days);
        vault.claim(address(coin), 1);
        assertEq(coin.balanceOf(ben2), 50e18);
        assertEq(coin.balanceOf(ben), 0);
        assertEq(vault.allocation(address(coin), 0).amountClaimed, 0);
    }

    function test_noAdminOrEarlyUnlockFunctionExists() public {
        _launch(_data(ben, LOCK, VEST));
        bytes[6] memory calls = [
            abi.encodeWithSignature(
                "editAllocationAdmin(address,address)", address(coin), address(this)
            ),
            abi.encodeWithSignature(
                "setBeneficiary(address,address)", address(coin), address(this)
            ),
            abi.encodeWithSignature("unlock(address)", address(coin)),
            abi.encodeWithSignature("emergencyWithdraw(address)", address(coin)),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("owner()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(ben);
            (bool ok, bytes memory ret) = address(vault).call(calls[i]);
            assertFalse(ok);
            assertEq(ret.length, 0);
        }
    }

    function test_erc165AndConstants() public view {
        assertTrue(vault.supportsInterface(type(IArtCoinsExtensionV2).interfaceId));
        assertTrue(vault.supportsInterface(type(IConstantsBound).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertFalse(vault.supportsInterface(0xffffffff));
        assertEq(vault.constantsHash(), Constants.hash());
        assertEq(vault.factory(), address(stub));
    }

    function testFuzz_vestingMonotoneAndComplete(uint256 t1, uint256 t2) public {
        _launch(_data(ben, LOCK, VEST));
        t1 = bound(t1, 0, LOCK + VEST + 1 days);
        t2 = bound(t2, t1, LOCK + VEST + 2 days);
        vm.warp(T0 + t1);
        uint256 a1 = vault.amountAvailableToClaim(address(coin), 0);
        vm.warp(T0 + t2);
        uint256 a2 = vault.amountAvailableToClaim(address(coin), 0);
        assertLe(a1, a2);
        assertLe(a2, SUPPLY);
        if (t2 >= LOCK + VEST) assertEq(a2, SUPPLY);
    }
}

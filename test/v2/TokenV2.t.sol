// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package t1 unit tests: ArtCoinsTokenV2 (restriction model) and ArtCoinsDeployerV2.
// The test contract is the bound factory (launcher) and the canonical hook, so
// it can grant the transient PoolManager transfer allowance. forge runs a whole
// test function as one tx, so the transient allowance persists across calls
// inside one test.

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "../../src/v2/interfaces/IArtCoinsTokenV2.sol";
import {ArtCoinsDeployerV2} from "../../src/v2/utils/ArtCoinsDeployerV2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract TV2Renderer {
    function contractURI(address) external pure returns (string memory) {
        return "custom";
    }
}

abstract contract TokenV2Base is Test {
    using PoolIdLibrary for PoolKey;

    // the test contract is the launcher and the admin; HOOK and PM are distinct
    // (an allowlist entry for the hook or the PoolManager is rejected).
    address internal constant PM = address(0xBEEF);
    address internal constant HOOK = address(0x400C);
    int24 internal constant TS = 60;

    ArtCoinsDeployerV2 internal deployer;

    function setUp() public virtual {
        deployer = new ArtCoinsDeployerV2(address(this));
    }

    function _canon() internal pure returns (ArtCoinsTokenV2.CanonicalPool memory) {
        return ArtCoinsTokenV2.CanonicalPool({hook: HOOK, poolManager: PM, tickSpacing: TS});
    }

    function _tokenConfig() internal view returns (IArtCoinsFactoryV2.TokenConfigV2 memory t) {
        t.tokenAdmin = address(this);
        t.name = "Token V2";
        t.symbol = "TV2";
    }

    function _restriction(bool restricted, address[] memory allowed)
        internal
        pure
        returns (IArtCoinsFactoryV2.RestrictionConfigV2 memory r)
    {
        r.restricted = restricted;
        r.allowed = allowed;
    }

    function _newToken(bool restricted, address[] memory allowed)
        internal
        returns (ArtCoinsTokenV2 token)
    {
        return _newToken(restricted, allowed, new address[](0));
    }

    function _newToken(bool restricted, address[] memory allowed, address[] memory pinned)
        internal
        returns (ArtCoinsTokenV2 token)
    {
        token = new ArtCoinsTokenV2(
            _tokenConfig(),
            Constants.DEFAULT_TOKEN_SUPPLY,
            _restriction(restricted, allowed),
            pinned,
            _canon(),
            address(this)
        );
    }

    function _plain() internal returns (ArtCoinsTokenV2) {
        return _newToken(false, new address[](0));
    }

    function _restricted(address[] memory allowed) internal returns (ArtCoinsTokenV2) {
        return _newToken(true, allowed);
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    /// Canonical pool id the token computes from its own address.
    function _pid(address token) internal pure returns (bytes32) {
        return PoolId.unwrap(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TS,
                hooks: IHooks(HOOK)
            }).toId()
        );
    }

    /// Grant the transient PoolManager allowance as the canonical hook.
    function _grant(ArtCoinsTokenV2 token, uint256 amount) internal {
        vm.prank(HOOK);
        token.increaseTransferAllowance(_pid(address(token)), amount);
    }
}

contract TokenV2Test is TokenV2Base {
    function test_unrestricted_transfersFreely() public {
        ArtCoinsTokenV2 token = _plain();
        token.transfer(address(0xA11CE), 100);
        assertEq(token.balanceOf(address(0xA11CE)), 100);
        vm.prank(address(0xA11CE));
        token.transfer(address(0xB0B), 40);
        assertEq(token.balanceOf(address(0xB0B)), 40);
        assertFalse(token.restricted());
    }

    function test_restricted_walletToWalletReverts() public {
        ArtCoinsTokenV2 token = _restricted(_one(address(this)));
        // seed a wallet with coin via the allowlisted launcher.
        token.transfer(address(0xA11CE), 100);
        vm.prank(address(0xA11CE));
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.TransferRestricted.selector, address(0xA11CE), address(0xB0B), 10
            )
        );
        token.transfer(address(0xB0B), 10);
    }

    function test_restricted_allowlistedFromPasses() public {
        ArtCoinsTokenV2 token = _restricted(_one(address(this)));
        // address(this) is allowlisted, so the send passes.
        token.transfer(address(0xA11CE), 100);
        assertEq(token.balanceOf(address(0xA11CE)), 100);
    }

    function test_restricted_allowlistedToPasses() public {
        address sink = address(0x5151);
        address[] memory allowed = new address[](2);
        allowed[0] = address(this);
        allowed[1] = sink;
        ArtCoinsTokenV2 token = _restricted(allowed);
        token.transfer(address(0xA11CE), 100);
        // alice is not allowlisted, but the recipient is.
        vm.prank(address(0xA11CE));
        token.transfer(sink, 30);
        assertEq(token.balanceOf(sink), 30);
    }

    function test_restricted_poolManagerNeedsAllowance() public {
        ArtCoinsTokenV2 token = _restricted(_one(address(this)));
        token.transfer(address(0xA11CE), 100);
        // alice -> PM with no allowance reverts.
        vm.prank(address(0xA11CE));
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.TransferRestricted.selector, address(0xA11CE), PM, 100
            )
        );
        token.transfer(PM, 100);
    }

    function test_restricted_poolManagerAllowanceConsumed() public {
        ArtCoinsTokenV2 token = _restricted(_one(address(this)));
        token.transfer(address(0xA11CE), 100);
        _grant(token, 60);
        assertEq(token.transferAllowance(), 60);
        // alice -> PM consumes 40, leaving 20.
        vm.prank(address(0xA11CE));
        token.transfer(PM, 40);
        assertEq(token.transferAllowance(), 20);
        assertEq(token.balanceOf(PM), 40);
        // a second transfer above the remainder reverts.
        vm.prank(address(0xA11CE));
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.TransferRestricted.selector, address(0xA11CE), PM, 30
            )
        );
        token.transfer(PM, 30);
        // PM -> wallet consumes the rest.
        _grant(token, 0); // no op
        vm.prank(address(0xA11CE));
        token.transfer(PM, 20);
        assertEq(token.transferAllowance(), 0);
    }

    function test_restricted_poolManagerToWalletConsumes() public {
        ArtCoinsTokenV2 token = _restricted(_one(address(this)));
        // fund PM through the allowlisted launcher first.
        token.transfer(PM, 500);
        _grant(token, 300);
        vm.prank(PM);
        token.transfer(address(0xA11CE), 300);
        assertEq(token.balanceOf(address(0xA11CE)), 300);
        assertEq(token.transferAllowance(), 0);
    }

    function test_increaseAllowance_onlyHook() public {
        ArtCoinsTokenV2 token = _restricted(new address[](0));
        vm.prank(address(0xDEAD));
        vm.expectRevert(IArtCoinsTokenV2.NotCanonicalHook.selector);
        token.increaseTransferAllowance(_pid(address(token)), 100);
    }

    function test_increaseAllowance_wrongPoolNoOp() public {
        ArtCoinsTokenV2 token = _restricted(new address[](0));
        vm.prank(HOOK);
        token.increaseTransferAllowance(bytes32(uint256(1)), 100);
        assertEq(token.transferAllowance(), 0);
        vm.prank(HOOK);
        token.increaseTransferAllowance(_pid(address(token)), 0);
        assertEq(token.transferAllowance(), 0);
    }

    function test_mintAndBurn_bypassRestriction() public {
        ArtCoinsTokenV2 token = _restricted(new address[](0));
        // the mint to the launcher at construction was not blocked.
        assertEq(token.balanceOf(address(this)), Constants.DEFAULT_TOKEN_SUPPLY);
        // burn works while restricted.
        token.burn(1000);
        assertEq(token.totalSupply(), Constants.DEFAULT_TOKEN_SUPPLY - 1000);
    }

    function test_setAllowed_adminOnly() public {
        ArtCoinsTokenV2 token = _restricted(new address[](0));
        vm.prank(address(0xDEAD));
        vm.expectRevert(IArtCoinsTokenV2.NotAdmin.selector);
        token.setAllowed(address(0xA11CE), true);

        token.setAllowed(address(0xA11CE), true);
        assertTrue(token.isAllowed(address(0xA11CE)));
        token.setAllowed(address(0xA11CE), false);
        assertFalse(token.isAllowed(address(0xA11CE)));

        vm.expectRevert(IArtCoinsTokenV2.ZeroAddress.selector);
        token.setAllowed(address(0), true);
    }

    function test_unrestrict_oneWay() public {
        ArtCoinsTokenV2 token = _restricted(new address[](0));
        vm.prank(address(0xDEAD));
        vm.expectRevert(IArtCoinsTokenV2.NotAdmin.selector);
        token.unrestrict();

        token.unrestrict();
        assertFalse(token.restricted());
        // now wallet to wallet passes.
        token.transfer(address(0xA11CE), 100);
        vm.prank(address(0xA11CE));
        token.transfer(address(0xB0B), 50);
        assertEq(token.balanceOf(address(0xB0B)), 50);
        // unrestrict again reverts.
        vm.expectRevert(IArtCoinsTokenV2.NotRestricted.selector);
        token.unrestrict();
    }

    function test_lock_blocksSetAllowedAndUnrestrict() public {
        ArtCoinsTokenV2 token = _restricted(new address[](0));
        vm.prank(address(0xDEAD));
        vm.expectRevert(IArtCoinsTokenV2.NotAdmin.selector);
        token.lock();

        token.lock();
        assertTrue(token.locked());
        vm.expectRevert(IArtCoinsTokenV2.AlreadyLocked.selector);
        token.setAllowed(address(0xA11CE), true);
        vm.expectRevert(IArtCoinsTokenV2.AlreadyLocked.selector);
        token.unrestrict();
        vm.expectRevert(IArtCoinsTokenV2.AlreadyLocked.selector);
        token.lock();
    }

    function test_constructor_unrestrictedRejectsAllowlist() public {
        vm.expectRevert(IArtCoinsTokenV2.RestrictionConfigInvalid.selector);
        _newToken(false, _one(address(this)));
    }

    function test_constructor_restrictedRejectsZeroEntry() public {
        vm.expectRevert(IArtCoinsTokenV2.RestrictionConfigInvalid.selector);
        _newToken(true, _one(address(0)));
    }

    function test_constructor_seedsAllowlist() public {
        address[] memory allowed = new address[](2);
        allowed[0] = address(0xA11CE);
        allowed[1] = address(0xB0B);
        ArtCoinsTokenV2 token = _restricted(allowed);
        assertTrue(token.isAllowed(address(0xA11CE)));
        assertTrue(token.isAllowed(address(0xB0B)));
        assertFalse(token.isAllowed(address(0xC0C0)));
    }

    // ── metadata and admin (unchanged behavior) ─────────────────────────────

    function test_metadata_defaultUri() public {
        ArtCoinsTokenV2 token = _plain();
        string memory uri = token.contractURI();
        assertTrue(bytes(uri).length > 0);
    }

    function test_metadata_renderer() public {
        ArtCoinsTokenV2 token = _plain();
        TV2Renderer r = new TV2Renderer();
        token.setMetadataRenderer(address(r));
        assertEq(token.contractURI(), "custom");
    }

    function test_admin_updateAndRenounce() public {
        ArtCoinsTokenV2 token = _plain();
        token.updateAdmin(address(0xA11CE));
        assertEq(token.admin(), address(0xA11CE));
        vm.prank(address(0xA11CE));
        token.renounceAdmin();
        assertEq(token.admin(), address(0));
    }

    function test_stringCap_nameTooLong() public {
        IArtCoinsFactoryV2.TokenConfigV2 memory t = _tokenConfig();
        t.name = new string(65);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsTokenV2.StringTooLong.selector, uint8(0), uint256(65))
        );
        new ArtCoinsTokenV2(
            t,
            Constants.DEFAULT_TOKEN_SUPPLY,
            _restriction(false, new address[](0)),
            new address[](0),
            _canon(),
            address(this)
        );
    }

    function test_setAllowed_rejectsPoolManagerAndHook() public {
        ArtCoinsTokenV2 token = _restricted(new address[](0));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.AllowedForbidden.selector, PM));
        token.setAllowed(PM, true);
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.AllowedForbidden.selector, HOOK));
        token.setAllowed(HOOK, true);
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.AllowedForbidden.selector, PM));
        token.setAllowed(PM, false);
    }

    function test_constructor_rejectsPoolManagerAndHookInAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.AllowedForbidden.selector, PM));
        _newToken(true, _one(PM));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.AllowedForbidden.selector, HOOK));
        _newToken(true, _one(HOOK));
    }

    function test_constructor_badCanon_separateError() public {
        IArtCoinsFactoryV2.TokenConfigV2 memory t = _tokenConfig();
        ArtCoinsTokenV2.CanonicalPool memory bad =
            ArtCoinsTokenV2.CanonicalPool({hook: HOOK, poolManager: PM, tickSpacing: 0});
        vm.expectRevert(IArtCoinsTokenV2.CanonicalPoolInvalid.selector);
        new ArtCoinsTokenV2(
            t,
            Constants.DEFAULT_TOKEN_SUPPLY,
            _restriction(false, new address[](0)),
            new address[](0),
            bad,
            address(this)
        );
    }

    function test_pinned_cannotBeRemoved() public {
        address keep = address(0xACE1);
        address user = address(0xACE2);
        address[] memory allowed = new address[](2);
        allowed[0] = keep;
        allowed[1] = user;
        ArtCoinsTokenV2 token = _newToken(true, allowed, _one(keep)); // keep is pinned
        assertTrue(token.isPinned(keep));
        assertFalse(token.isPinned(user));
        // a pinned entry cannot be removed
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.AllowedPinned.selector, keep));
        token.setAllowed(keep, false);
        // a non pinned entry can be removed, and re-adding a pinned is fine
        token.setAllowed(user, false);
        assertFalse(token.isAllowed(user));
        token.setAllowed(keep, true);
        assertTrue(token.isAllowed(keep));
    }

    // ── deployer ─────────────────────────────────────────────────────────

    function test_deployer_predictMatchesDeploy() public {
        IArtCoinsFactoryV2.TokenConfigV2 memory t = _tokenConfig();
        IArtCoinsFactoryV2.RestrictionConfigV2 memory r = _restriction(false, new address[](0));
        address[] memory pinned = new address[](0);
        bytes32 salt = keccak256("t1");
        address predicted = deployer.predict(
            t, Constants.DEFAULT_TOKEN_SUPPLY, r, pinned, _canon(), address(this), salt
        );
        address token = deployer.deploy(
            t, Constants.DEFAULT_TOKEN_SUPPLY, r, pinned, _canon(), address(this), salt
        );
        assertEq(token, predicted);
    }

    function test_deployer_onlyFactory() public {
        IArtCoinsFactoryV2.TokenConfigV2 memory t = _tokenConfig();
        IArtCoinsFactoryV2.RestrictionConfigV2 memory r = _restriction(false, new address[](0));
        vm.prank(address(0xDEAD));
        vm.expectRevert(ArtCoinsDeployerV2.NotFactory.selector);
        deployer.deploy(
            t,
            Constants.DEFAULT_TOKEN_SUPPLY,
            r,
            new address[](0),
            _canon(),
            address(this),
            bytes32(0)
        );
    }

    function test_constantsHash_matches() public view {
        assertEq(deployer.constantsHash(), Constants.hash());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "../../../src/v2/interfaces/IArtCoinsTokenV2.sol";
import {IntegrationV2Base} from "../integration/IntegrationV2Base.sol";
import {I1EmptyTreasury} from "../integration/mocks/I1Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// v4 periphery ExactInputSingleParams / ExactOutputSingleParams as the live
/// universal router decodes them.
struct URExactInSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

struct URExactOutSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountOut;
    uint128 amountInMaximum;
    bytes hookData;
}

interface IUniversalRouterLike {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev A contract that sends coin wherever its caller directs. Allowlisting
///      such a forwarder reopens wallet to wallet transfers; the hazard test
///      below proves it, which is why routers are never allowlisted.
contract RRForwarder {
    function fwd(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @notice D73 review fix: a restricted coin trades through the live universal
///         router (and permit2) without either on the allowlist, because the
///         only coin move is directly between the PoolManager and the user,
///         covered by the per swap allowance the hook grants. The seeded
///         entries (escrow, locker, extensions) move coin only on their own
///         fixed logic, so a user cannot use them to reach an arbitrary wallet.
contract RestrictionRouterV2ForkTest is IntegrationV2Base {
    IUniversalRouterLike internal ur = IUniversalRouterLike(UNIVERSAL_ROUTER);

    // v4 action bytes
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;
    // universal router command bytes
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWEEP = 0x04;

    function _restrictedLaunch() internal returns (address coin, PoolKey memory key) {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c =
            _restrictedConfig(address(new I1EmptyTreasury()));
        coin = _ownerLaunch(c);
        key = _key(coin);
        _pastWindow();
    }

    // ── the standard routers are not on the allowlist ──────────────────────

    function test_restricted_routersNotAllowlisted() public onlyFork {
        (address coin,) = _restrictedLaunch();
        assertFalse(IArtCoinsTokenV2(coin).isAllowed(UNIVERSAL_ROUTER), "UR not allowlisted");
        assertFalse(IArtCoinsTokenV2(coin).isAllowed(PERMIT2), "permit2 not allowlisted");
        assertEq(IArtCoinsFactoryV2(address(v2.factory)).defaultAllowed().length, 0);
    }

    // ── universal router trades the restricted coin without allowlisting ────

    function test_restricted_universalRouter_buyExactIn() public onlyFork {
        (address coin, PoolKey memory key) = _restrictedLaunch();
        uint256 a = 1 ether;
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            URExactInSingle(key, true, uint128(a), uint128(0), _refundData(address(this)))
        );
        params[1] = abi.encode(key.currency0, a);
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0)); // sweep leftover eth

        ur.execute{value: a}(abi.encodePacked(V4_SWAP, SWEEP), inputs, block.timestamp);

        // coin reached the user directly (PoolManager take), covered by the
        // per swap allowance; the router holds nothing.
        assertGt(IERC20(coin).balanceOf(address(this)), 0, "bought");
        assertEq(IERC20(coin).balanceOf(UNIVERSAL_ROUTER), 0, "UR holds no coin");
        assertEq(IArtCoinsTokenV2(coin).transferAllowance(), 0, "allowance consumed");
    }

    function test_restricted_universalRouter_buyExactOut() public onlyFork {
        (address coin, PoolKey memory key) = _restrictedLaunch();
        uint128 outWanted = 1_000_000e18;
        uint128 maxIn = 5 ether;
        bytes memory actions = abi.encodePacked(SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(URExactOutSingle(key, true, outWanted, maxIn, _refundData(address(this))));
        params[1] = abi.encode(key.currency0, uint256(maxIn));
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0));

        ur.execute{value: maxIn}(abi.encodePacked(V4_SWAP, SWEEP), inputs, block.timestamp);

        assertEq(IERC20(coin).balanceOf(address(this)), outWanted, "exact coin out");
        assertEq(IERC20(coin).balanceOf(UNIVERSAL_ROUTER), 0, "UR holds no coin");
    }

    function test_restricted_universalRouter_sell() public onlyFork {
        (address coin, PoolKey memory key) = _restrictedLaunch();
        // acquire coin through a plain buy first (user holds it, not allowlisted).
        uint256 held = _buy(key, 1 ether);
        assertGt(held, 0);
        uint256 sellAmt = held / 2;
        // permit2 can pull from the user (solady fixes the token's permit2
        // allowance at infinity); approve the UR as a permit2 spender.
        IPermit2Like(PERMIT2)
            .approve(coin, UNIVERSAL_ROUTER, uint160(sellAmt), uint48(block.timestamp + 3600));

        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            URExactInSingle(key, false, uint128(sellAmt), uint128(0), _refundData(address(this)))
        );
        params[1] = abi.encode(key.currency1, sellAmt); // settle coin (pulled from the user)
        params[2] = abi.encode(key.currency0, uint256(0)); // take eth
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0)); // sweep eth out

        uint256 eth0 = address(this).balance;
        ur.execute(abi.encodePacked(V4_SWAP, SWEEP), inputs, block.timestamp);

        assertGt(address(this).balance, eth0, "eth received from the sell");
        assertEq(IERC20(coin).balanceOf(address(this)), held - sellAmt, "coin spent");
        assertEq(IERC20(coin).balanceOf(UNIVERSAL_ROUTER), 0, "UR holds no coin");
    }

    // ── a direct transfer to the router reverts (it is not allowlisted) ─────

    function test_restricted_userTransferToUniversalRouter_reverts() public onlyFork {
        (address coin, PoolKey memory key) = _restrictedLaunch();
        uint256 held = _buy(key, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.TransferRestricted.selector, address(this), UNIVERSAL_ROUTER, held
            )
        );
        IERC20(coin).transfer(UNIVERSAL_ROUTER, held);
    }

    // ── hazard: an allowlisted forwarder reopens wallet to wallet ───────────

    function test_allowlistedForwarder_enablesWalletToWallet() public onlyFork {
        RRForwarder fwd = new RRForwarder();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c =
            _restrictedConfig(address(new I1EmptyTreasury()));
        c.restriction.allowed = new address[](1);
        c.restriction.allowed[0] = address(fwd);
        address coin = _ownerLaunch(c);
        PoolKey memory key = _key(coin);
        _pastWindow();

        uint256 held = _buy(key, 1 ether); // the user holds coin, not allowlisted
        address bob = address(0xB0B);
        // user -> forwarder passes (to is allowlisted); forwarder -> bob passes
        // (from is allowlisted): the pair is a wallet to wallet move.
        IERC20(coin).transfer(address(fwd), held);
        fwd.fwd(coin, bob, held);
        assertEq(IERC20(coin).balanceOf(bob), held, "allowlisted forwarder bypassed restriction");
    }

    // ── seeded entries cannot be used by a user to reach an arbitrary wallet ─

    function test_restricted_escrow_cannotForwardToArbitraryWallet() public onlyFork {
        (address coin, PoolKey memory key) = _restrictedLaunch();
        assertTrue(IArtCoinsTokenV2(coin).isAllowed(address(v2.escrow)), "escrow seeded");
        uint256 held = _buy(key, 1 ether);
        // a raw send to the escrow passes (escrow is allowlisted) but books no
        // credit (storeFees is depositor only), so the user cannot claim it out.
        IERC20(coin).transfer(address(v2.escrow), held);
        assertEq(v2.escrow.balances(address(this), coin), 0, "no credit from a raw send");
        vm.expectRevert(); // NoFeesToClaim
        v2.escrow.claim(address(this), coin);
        vm.expectRevert(); // NoFeesToClaim (claimTo requires msg.sender == feeOwner)
        v2.escrow.claimTo(address(this), coin, payable(address(0xB0B)));
    }

    function test_restricted_locker_paysOnlyFrozenRecipients() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c =
            _restrictedConfig(address(new I1EmptyTreasury()));
        address project = c.locker.rewardRecipients[0];
        address coin = _ownerLaunch(c);
        PoolKey memory key = _key(coin);
        _pastWindow();
        // trade both ways so the locker position accrues coin fees
        uint256 got = _buy(key, 2 ether);
        _sell(key, got / 2);
        address stranger_ = address(0xDEAD1);
        uint256 strangerBefore = IERC20(coin).balanceOf(stranger_);
        v2.locker.collectRewards(coin);
        // coin fees reach the frozen reward recipient (directly or as an escrow
        // credit), never a caller chosen wallet.
        assertGt(
            IERC20(coin).balanceOf(project) + v2.escrow.balances(project, coin),
            0,
            "project slot paid"
        );
        assertEq(IERC20(coin).balanceOf(stranger_), strangerBefore, "no arbitrary payout");
    }
}

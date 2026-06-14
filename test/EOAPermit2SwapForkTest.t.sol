// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IUniversalRouter} from "../lib/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "../lib/universal-router/contracts/libraries/Commands.sol";

import {MainnetLaunchRehearsalForkTest} from "./MainnetLaunchRehearsalForkTest.t.sol";

/// @title EOAPermit2SwapForkTest
/// @notice End-to-end proof that an EOA holder can sell artcoins for ETH on
///         the live mainnet V4 stack with **zero** prior `token.approve` calls
///         — only a single Permit2 PermitSingle signature in the same tx.
///
///         Inherits the full launch deploy from `MainnetLaunchRehearsalForkTest`
///         so the LAYER pool, hook, locker, and seeded liquidity are already in
///         place when the test starts. The test contract itself starts with the
///         entire LP allocation (it's the deployer/funder for the rehearsal),
///         so we transfer a chunk to a fresh EOA holder, build + sign a
///         PermitSingle, and call `UR.execute([PERMIT2_PERMIT, V4_SWAP, UNWRAP_WETH])`
///         from the holder.
///
/// Run:
///   forge test --match-contract EOAPermit2SwapForkTest \
///     --fork-url $MAINNET_RPC_URL -vvv
contract EOAPermit2SwapForkTest is MainnetLaunchRehearsalForkTest {
    /// @dev Sample holder. The private key is fixed so the test is deterministic;
    ///      the address has no special meaning, it's just a fresh EOA on the fork.
    uint256 internal constant HOLDER_PK = 0xA11CE;

    /// @dev Permit2's EIP-712 type hashes (per the spec, no version field in the
    ///      domain). Frontends MUST use these byte-for-byte.
    bytes32 internal constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)"
        "PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    /// @notice Holder sells LAYER for ETH in a single tx + 1 sig, with zero
    ///         prior `token.approve` calls. Asserts the artcoin balance went
    ///         down by exactly amountIn, the holder's ETH went up, the artcoin
    ///         allowance for PERMIT2 still reads `type(uint256).max` (proving
    ///         the Solady short-circuit held), and the Permit2 nonce advanced
    ///         (proving the PermitSingle was actually consumed by UR).
    function test_eoaSell_singleTxWithPermit2() public onlyFork withClean {
        // Skip past the MEV sniper fee window so the swap reflects the
        // steady-state fee path. The proof we want — Permit2 short-circuit
        // + UR PERMIT2_PERMIT + V4_SWAP + UNWRAP_WETH — is independent of
        // the time-decay sniper module; warping just makes the assertions
        // simpler (full input consumed, predictable output).
        vm.warp(launchTimestamp + 1 days);

        // The launch initialises the pool at the bottom of the LP range
        // (LAYER_STARTING_TICK), and the LP positions are LAYER-only above
        // the starting tick. To sell LAYER for WETH there has to be WETH
        // available in the active range — i.e., the price has to have moved
        // up at least once. Mimic real post-launch state by doing a small
        // buy first; the test contract holds 20k WETH from setUp.
        _exactInputBuy(50 ether);

        address holder = vm.addr(HOLDER_PK);
        vm.deal(holder, 1 ether); // gas only

        // Fund the holder with LAYER directly via foundry's `deal`. The
        // post-launch LAYER distribution sends nearly all supply into LP +
        // extensions, so the test contract doesn't hold a useful balance to
        // transfer from. `deal` writes the holder's balance slot directly,
        // which is the cleanest way to set up a fresh-EOA-with-tokens
        // scenario for the sell test.
        uint256 amountIn = 1_000_000e18; // 1M LAYER
        deal(layerAddr, holder, amountIn);
        assertEq(IERC20(layerAddr).balanceOf(holder), amountIn, "holder funding");

        // Read holder's Permit2 nonce for (token, spender) — should be 0 first time.
        (,, uint48 nonce) =
            IAllowanceTransfer(PERMIT2).allowance(holder, layerAddr, UNIVERSAL_ROUTER);

        // Build PermitSingle. The `amount` is the per-signature spend cap; we
        // size it to amountIn for tight scoping (frontend may prefer
        // `type(uint160).max` for unlimited per-tx).
        IAllowanceTransfer.PermitDetails memory details = IAllowanceTransfer.PermitDetails({
            token: layerAddr,
            amount: uint160(amountIn),
            expiration: uint48(block.timestamp + 1 days),
            nonce: nonce
        });
        IAllowanceTransfer.PermitSingle memory permit = IAllowanceTransfer.PermitSingle({
            details: details, spender: UNIVERSAL_ROUTER, sigDeadline: block.timestamp + 30 minutes
        });

        bytes memory signature = _signPermitSingle(HOLDER_PK, permit);

        // Build commands: PERMIT2_PERMIT (set the Permit2→UR allowance from sig)
        //                  + V4_SWAP (sell LAYER for WETH, leave WETH in UR)
        //                  + UNWRAP_WETH (forward ETH to holder).
        bytes memory commands = abi.encodePacked(
            uint8(Commands.PERMIT2_PERMIT), uint8(Commands.V4_SWAP), uint8(Commands.UNWRAP_WETH)
        );
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(permit, signature);
        inputs[1] = _encodeSellLayerForWethAction(amountIn);
        inputs[2] = abi.encode(ActionConstants.MSG_SENDER, uint256(0)); // (recipient, minOut)

        uint256 layerBefore = IERC20(layerAddr).balanceOf(holder);
        uint256 ethBefore = holder.balance;

        // Sanity: no prior token.approve was made. The Solady short-circuit
        // is the only thing letting Permit2 transferFrom from the holder.
        // Before the call, the on-chain allowance view already reads max:
        assertEq(
            IERC20(layerAddr).allowance(holder, PERMIT2),
            type(uint256).max,
            "holder must have implicit Permit2 max allowance from Solady short-circuit"
        );

        vm.prank(holder);
        uint256 g0 = gasleft();
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 1);
        uint256 gasUsed = g0 - gasleft();
        console2.log("UR.execute() gas used:", gasUsed);

        // Assertions
        assertEq(
            IERC20(layerAddr).balanceOf(holder),
            layerBefore - amountIn,
            "holder LAYER balance must decrement by amountIn"
        );
        assertGt(holder.balance, ethBefore, "holder must have received ETH");
        assertEq(
            IERC20(layerAddr).allowance(holder, PERMIT2),
            type(uint256).max,
            "Solady Permit2 short-circuit must still read max post-swap"
        );

        // PermitSingle was consumed: nonce++.
        (,, uint48 newNonce) =
            IAllowanceTransfer(PERMIT2).allowance(holder, layerAddr, UNIVERSAL_ROUTER);
        assertEq(newNonce, nonce + 1, "Permit2 nonce must advance - proves PermitSingle was used");
    }

    /// @dev Builds `inputs[1]` for V4_SWAP: SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE.
    ///      Pays `amountIn` LAYER from the holder via Permit2, takes the WETH
    ///      output into UR (`ADDRESS_THIS`) so UNWRAP_WETH can forward ETH next.
    function _encodeSellLayerForWethAction(uint256 amountIn) internal view returns (bytes memory) {
        // In artcoins V4, layer is currency0 if `_layerIsToken0` (i.e., layerAddr < WETH).
        // Selling LAYER → WETH means `zeroForOne` matches `_layerIsToken0`.
        bool zeroForOne = _layerIsToken0;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        // SETTLE_ALL: pay LAYER (input). Cap is amountIn (the swap consumed all).
        params[1] = abi.encode(Currency.wrap(layerAddr), uint256(amountIn));
        // TAKE: pull WETH (output) into UR itself so UNWRAP_WETH has something
        //       to unwrap. ADDRESS_THIS is V4Router's recipient placeholder.
        params[2] = abi.encode(Currency.wrap(WETH), ActionConstants.ADDRESS_THIS, uint256(0));

        return abi.encode(actions, params);
    }

    /// @dev Signs an `IAllowanceTransfer.PermitSingle` per Permit2's EIP-712
    ///      domain. Domain has no `version` field — that's the canonical
    ///      Permit2 spec, and is what `IEIP712(PERMIT2).DOMAIN_SEPARATOR()`
    ///      returns. We read the live separator rather than recomputing,
    ///      to be robust against any cached-on-deploy storage layout.
    function _signPermitSingle(uint256 pk, IAllowanceTransfer.PermitSingle memory permit)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 detailsHash = keccak256(
            abi.encode(
                PERMIT_DETAILS_TYPEHASH,
                permit.details.token,
                permit.details.amount,
                permit.details.expiration,
                permit.details.nonce
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_SINGLE_TYPEHASH, detailsHash, permit.spender, permit.sigDeadline)
        );
        bytes32 domainSep = IAllowanceTransfer(PERMIT2).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        signature = abi.encodePacked(r, s, v);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Addresses} from "../../../script/Addresses.sol";
import {LaunchV2Lib} from "../../../script/v2/LaunchV2Coin.s.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsKeeperV2} from "../../../src/v2/interfaces/IArtCoinsKeeperV2.sol";
import {IArtCoinsLpLockerV2} from "../../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

struct FcExactIn {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

interface IFcUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IFcPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Treasury stand in: accepts eth within the 2300 gas stipend.
contract FcTreasury {
    receive() external payable {}
}

/// Recipient that reverts on eth, so the hook and locker fall back to the escrow.
contract FcRejecter {
    function claimTo(IArtCoinsFeeEscrowV2 e, address to) external {
        e.claimTo(address(this), address(0), payable(to));
    }
}

/// @notice Rehearsal of RUNBOOK 2b steps 3 to 7 against the deployed v2 stack.
///         Env: MAINNET_RPC_URL (default tenderly public), FORK_BLOCK (default
///         latest at or after the deploy block; must be >= 26_157_260).
contract FirstCoinRehearsal is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
    uint256 internal constant TX_CAP = 16_700_000;

    bool internal onFork;
    IArtCoinsFactoryV2 internal factory = IArtCoinsFactoryV2(Addresses.V2_FACTORY);
    IArtCoinsFeeEscrowV2 internal escrow = IArtCoinsFeeEscrowV2(Addresses.V2_ESCROW);
    address internal keeperCaller = makeAddr("keeperCaller");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    receive() external payable {}

    function setUp() public {
        string memory rpc =
            vm.envOr("MAINNET_RPC_URL", string("https://gateway.tenderly.co/public/mainnet"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        try vm.createSelectFork(rpc) returns (uint256) {
            if (blk != 0) vm.rollFork(blk);
            onFork = Addresses.V2_FACTORY.code.length != 0;
        } catch {
            console2.log("fork unavailable");
        }
        if (!onFork) vm.skip(true);
    }

    function _target() internal pure returns (LaunchV2Lib.Target memory t) {
        t = LaunchV2Lib.Target(
            Addresses.V2_FACTORY, Addresses.V2_HOOK, Addresses.V2_LOCKER, Addresses.V2_MEV_MODULE
        );
    }

    // ── step 3 to 5: launch ───────────────────────────────────────────────

    function _launch(string memory path, address recipient)
        internal
        returns (address token, PoolKey memory key, LaunchV2Lib.Launch memory l)
    {
        LaunchV2Lib.Target memory t = _target();
        l = LaunchV2Lib.parse(vm.readFile(path), t);
        l.cfg.fee.bountyRecipient = payable(recipient);
        l.cfg.locker.rewardRecipients[0] = recipient;

        (address predicted, uint256 value) = LaunchV2Lib.preflight(t, l, OWNER);
        bytes32 cfgHash = factory.configHash(l.cfg);
        vm.deal(OWNER, OWNER.balance + value);

        vm.recordLogs();
        vm.prank(OWNER);
        uint256 g = gasleft();
        token = factory.deployTokenAsOwner{value: value}(l.cfg, l.protocolBps);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console2.log("launch gas", g);
        console2.log("launch gas headroom to 16.7M cap", TX_CAP > g ? TX_CAP - g : 0);
        assertLt(g, TX_CAP, "launch gas above tx cap");
        assertEq(token, predicted, "token != predicted");
        PoolId pid = LaunchV2Lib.checkLaunched(t, l, token);
        assertTrue(factory.isCoin(token), "isCoin");
        assertEq(IArtCoinsHookV2(Addresses.V2_HOOK).poolInfo(pid).version, 2, "hook version");
        assertTrue(_logHas(logs, cfgHash), "configHash not echoed in TokenCreatedV2");
        key = IArtCoinsLpLockerV2(Addresses.V2_LOCKER).tokenRewards(token).poolKey;
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(pid), "pool id");
    }

    function _logHas(Vm.Log[] memory logs, bytes32 needle) internal view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != Addresses.V2_FACTORY) continue;
            for (uint256 j; j < logs[i].topics.length; ++j) {
                if (logs[i].topics[j] == needle) return true;
            }
            for (uint256 k; k + 32 <= logs[i].data.length; k += 32) {
                bytes32 w;
                bytes memory d = logs[i].data;
                assembly { w := mload(add(add(d, 32), k)) }
                if (w == needle) return true;
            }
        }
        return false;
    }

    // ── swaps through the live universal router ───────────────────────────

    function _buy(PoolKey memory key, uint256 ethIn) internal returns (uint256 got) {
        address coin = Currency.unwrap(key.currency1);
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(FcExactIn(key, true, uint128(ethIn), 0, ""));
        params[1] = abi.encode(key.currency0, ethIn);
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0));
        vm.deal(address(this), address(this).balance + ethIn);
        uint256 c0 = IERC20(coin).balanceOf(address(this));
        uint256 g = gasleft();
        IFcUniversalRouter(UNIVERSAL_ROUTER).execute{value: ethIn}(
            abi.encodePacked(uint8(0x10), uint8(0x04)), inputs, block.timestamp
        );
        g -= gasleft();
        got = IERC20(coin).balanceOf(address(this)) - c0;
        console2.log("buy gas", g);
        assertGt(got, 0, "buy got nothing");
    }

    function _sell(PoolKey memory key, uint256 coinIn) internal returns (uint256 got) {
        address coin = Currency.unwrap(key.currency1);
        IERC20(coin).approve(PERMIT2, type(uint256).max);
        IFcPermit2(PERMIT2)
            .approve(coin, UNIVERSAL_ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(FcExactIn(key, false, uint128(coinIn), 0, ""));
        params[1] = abi.encode(key.currency1, coinIn);
        params[2] = abi.encode(key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 e0 = address(this).balance;
        uint256 g = gasleft();
        IFcUniversalRouter(UNIVERSAL_ROUTER)
            .execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        g -= gasleft();
        got = address(this).balance - e0;
        console2.log("sell gas", g);
        assertGt(got, 0, "sell got nothing");
    }

    // ── step 7: keeper ────────────────────────────────────────────────────

    function _keeper(address token) internal {
        uint256 b0 = keeperCaller.balance;
        vm.prank(keeperCaller);
        uint256 g = gasleft();
        IArtCoinsKeeperV2(Addresses.V2_KEEPER).collectAndForward{gas: 2_000_000}(token, false, 0);
        g -= gasleft();
        console2.log("keeper gas", g);
        console2.log("keeper caller eth forwarded", keeperCaller.balance - b0);
    }

    function _flow(PoolKey memory key, address token) internal returns (uint256 coinHeld) {
        // inside the anti sniper window
        _buy(key, 0.5 ether);
        // after the window
        vm.warp(block.timestamp + 5000);
        vm.roll(block.number + 400);
        _buy(key, 0.5 ether);
        coinHeld = IERC20(token).balanceOf(address(this));
        _sell(key, coinHeld / 4);
    }

    // ── tests ─────────────────────────────────────────────────────────────

    function test_credits_plainTreasury() public {
        address treasury = address(new FcTreasury());
        (address token, PoolKey memory key,) =
            _launch("script/v2/launch-configs/example.json", treasury);
        assertFalse(_restricted(token), "not restricted");
        uint256 t0 = treasury.balance;
        _flow(key, token);
        uint256 t1 = treasury.balance;
        console2.log("treasury eth after swaps (bounty pushes)", t1 - t0);
        assertGt(t1, t0, "bounty pushed");
        _keeper(token);
        console2.log("treasury eth after keeper (locker share)", treasury.balance - t1);
        console2.log("escrow credit treasury", escrow.balances(treasury, address(0)));
        // plain erc20 transfer works
        IERC20(token).transfer(alice, 1e18);
        vm.prank(alice);
        IERC20(token).transfer(bob, 1e18);
    }

    function test_credits_rejectingRecipient_escrowAndClaim() public {
        FcRejecter rej = new FcRejecter();
        (address token, PoolKey memory key,) =
            _launch("script/v2/launch-configs/example.json", address(rej));
        _flow(key, token);
        uint256 credit1 = escrow.balances(address(rej), address(0));
        console2.log("escrow credit after swaps", credit1);
        assertGt(credit1, 0, "bounty credited to escrow");
        _keeper(token);
        uint256 credit2 = escrow.balances(address(rej), address(0));
        console2.log("escrow credit after keeper", credit2);
        assertGe(credit2, credit1);
        address payee = makeAddr("payee");
        rej.claimTo(escrow, payee);
        assertEq(payee.balance, credit2, "claimTo paid");
        assertEq(escrow.balances(address(rej), address(0)), 0, "credit cleared");
    }

    function test_restricted() public {
        address treasury = address(new FcTreasury());
        (address token, PoolKey memory key,) =
            _launch("script/v2/launch-configs/example-restricted.json", treasury);
        assertTrue(_restricted(token), "restricted");
        uint256 held = _flow(key, token);
        assertGt(held, 0);
        // wallet to wallet transfer between two EOAs reverts
        vm.prank(address(this));
        vm.expectRevert();
        IERC20(token).transfer(alice, 1e18);
        _keeper(token);
    }

    function _restricted(address token) internal view returns (bool) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("restricted()"));
        require(ok, "restricted()");
        return abi.decode(r, (bool));
    }
}

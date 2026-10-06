// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// dev buy extension against the live PoolManager (pinned block), on a hook
// less native eth pool created in the test. The skim path is covered by the
// hook packages; here the point is the extension: nonzero minOut, tokens
// delivered through the PoolManager, leftover eth refunded to the recipient
// fixed in extensionData, factory only. Skips when the rpc is unreachable.

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsUniv4EthDevBuyV2} from "../../src/v2/extensions/ArtCoinsUniv4EthDevBuyV2.sol";
import {
    IArtCoinsUniv4EthDevBuyV2
} from "../../src/v2/extensions/interfaces/IArtCoinsUniv4EthDevBuyV2.sol";
import {IArtCoinsExtensionV2} from "../../src/v2/interfaces/IArtCoinsExtensionV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract DBCoin is ERC20 {
    constructor() ERC20("Coin", "COIN") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @dev Plays the factory for one dev buy entry.
contract DBStubFactory {
    function launch(
        address ext,
        address token,
        PoolKey memory key,
        uint256 msgValue,
        uint16 bps,
        bytes memory data
    ) external payable {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: ext, msgValue: msgValue, extensionBps: bps, extensionData: data
        });
        c.pool.hook = address(key.hooks);
        IArtCoinsExtensionV2(ext).receiveTokens{value: msg.value}(c, key, token, 0, 0);
    }
}

contract RejectsEth {}

contract DevBuyV2ForkTest is Test {
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint256 internal constant FORK_BLOCK = 26_130_269;
    int24 internal constant TS = 60;
    // ~1000 coins per eth
    int24 internal constant START_TICK = 69_060;

    IPoolManager internal pm = IPoolManager(POOL_MANAGER);
    PoolModifyLiquidityTest internal liq;
    DBStubFactory internal stub;
    ArtCoinsUniv4EthDevBuyV2 internal devBuy;
    DBCoin internal coin;
    PoolKey internal key;
    bool internal onFork;
    /// @dev eth already sitting at the deterministic deploy address on the fork.
    uint256 internal dust;
    uint256 internal stubDust;

    address internal buyer = makeAddr("buyer");
    address internal refund = makeAddr("refund");

    receive() external payable {}

    function setUp() public {
        if (vm.envOr("SKIP_FORK_TESTS", false)) return;
        string memory rpc =
            vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        if (bytes(rpc).length == 0) rpc = "https://mainnet.gateway.tenderly.co";
        try vm.createSelectFork(rpc, FORK_BLOCK) {
            onFork = POOL_MANAGER.code.length != 0;
        } catch {}
        if (!onFork) return;

        stub = new DBStubFactory();
        devBuy = new ArtCoinsUniv4EthDevBuyV2(address(stub), POOL_MANAGER);
        liq = new PoolModifyLiquidityTest(pm);
        coin = new DBCoin();
        coin.approve(address(liq), type(uint256).max);
        vm.deal(address(this), 1000 ether);
        dust = address(devBuy).balance;
        stubDust = address(stub).balance;

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coin)),
            fee: 3000,
            tickSpacing: TS,
            hooks: IHooks(address(0))
        });
        pm.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));
    }

    modifier onlyFork() {
        if (!onFork) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _addLiquidity(int24 lo, int24 hi, int256 l) internal {
        liq.modifyLiquidity{value: 200 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: l, salt: 0
            }),
            ""
        );
    }

    /// @dev full range, both sides: a 1 eth buy always fills completely.
    function _deepPool() internal {
        _addLiquidity(-887_220, 887_220, 1e21);
    }

    /// @dev coin only liquidity below the start price: holds ~11 eth of depth,
    ///      anything above that cannot be taken.
    function _shallowPool() internal {
        _addLiquidity(START_TICK - 6000, START_TICK, 1e21);
    }

    function _data(address to, address refundTo, uint128 minOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(to, refundTo, minOut);
    }

    function _launch(uint256 value, bytes memory data) internal {
        stub.launch{value: value}(address(devBuy), address(coin), key, value, 0, data);
    }

    // ── validation ────────────────────────────────────────────────────────

    function test_minOutZeroReverts() public onlyFork {
        _deepPool();
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.ZeroMinOut.selector);
        _launch(1 ether, _data(buyer, refund, 0));
    }

    function test_zeroRecipientsRevert() public onlyFork {
        _deepPool();
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.ZeroRecipient.selector);
        _launch(1 ether, _data(address(0), refund, 1));
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.ZeroRecipient.selector);
        _launch(1 ether, _data(buyer, address(0), 1));
    }

    function test_nonFactoryCallerReverts() public onlyFork {
        _deepPool();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: address(devBuy),
            msgValue: 1 ether,
            extensionBps: 0,
            extensionData: _data(buyer, refund, 1)
        });
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.Unauthorized.selector);
        devBuy.receiveTokens{value: 1 ether}(c, key, address(coin), 0, 0);
    }

    function test_unlockCallbackOnlyPoolManager() public onlyFork {
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.NotPoolManager.selector);
        devBuy.unlockCallback("");
    }

    function test_msgValueMustMatchEntryAndBeNonzero() public onlyFork {
        _deepPool();
        // entry says 1 eth, call sends 2
        vm.expectRevert(IArtCoinsExtensionV2.InvalidMsgValue.selector);
        stub.launch{value: 2 ether}(
            address(devBuy), address(coin), key, 1 ether, 0, _data(buyer, refund, 1)
        );
        vm.expectRevert(IArtCoinsExtensionV2.InvalidMsgValue.selector);
        _launch(0, _data(buyer, refund, 1));
    }

    function test_takesNoSupply() public onlyFork {
        _deepPool();
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.InvalidDevBuyBps.selector);
        stub.launch{value: 1 ether}(
            address(devBuy), address(coin), key, 1 ether, 100, _data(buyer, refund, 1)
        );
    }

    function test_badDataLengthReverts() public onlyFork {
        _deepPool();
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.InvalidExtensionData.selector);
        _launch(1 ether, abi.encode(buyer, refund));
    }

    function test_wrongPoolKeyReverts() public onlyFork {
        _deepPool();
        PoolKey memory bad = key;
        bad.currency1 = Currency.wrap(address(0xdead));
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.InvalidPoolKey.selector);
        stub.launch{value: 1 ether}(
            address(devBuy), address(coin), bad, 1 ether, 0, _data(buyer, refund, 1)
        );
        // pool key hook differs from the launch config hook
        PoolKey memory badHook = key;
        badHook.hooks = IHooks(address(0xbeef));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: address(devBuy),
            msgValue: 1 ether,
            extensionBps: 0,
            extensionData: _data(buyer, refund, 1)
        });
        c.pool.hook = address(0);
        vm.prank(address(stub));
        vm.deal(address(stub), 1 ether);
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.InvalidPoolKey.selector);
        devBuy.receiveTokens{value: 1 ether}(c, badHook, address(coin), 0, 0);
    }

    // ── buys ──────────────────────────────────────────────────────────────

    function test_tokensDeliveredAndNothingLeftBehind() public onlyFork {
        _deepPool();
        uint256 minOut = 900e18;
        uint256 balBefore = address(this).balance;

        vm.expectEmit(true, true, false, false, address(devBuy));
        emit IArtCoinsUniv4EthDevBuyV2.EthDevBuy(address(coin), buyer, 0, 0, 0, refund);
        _launch(1 ether, _data(buyer, refund, uint128(minOut)));

        uint256 got = coin.balanceOf(buyer);
        assertGe(got, minOut, "min out honored");
        assertLt(got, 1000e18, "price moved against the buyer");
        assertEq(balBefore - address(this).balance, 1 ether, "full 1 eth spent");
        assertEq(refund.balance, 0, "full fill: no refund");
        assertEq(address(devBuy).balance, dust, "no eth stranded");
        assertEq(address(stub).balance, stubDust, "factory kept nothing");
        assertEq(coin.balanceOf(address(devBuy)), 0, "no coin stranded");
    }

    function test_minOutTooHighReverts() public onlyFork {
        _deepPool();
        // 1 eth cannot buy 2000 coins at a price of 1000
        vm.expectPartialRevert(IArtCoinsUniv4EthDevBuyV2.SlippageExceeded.selector);
        _launch(1 ether, _data(buyer, refund, 2000e18));
        assertEq(coin.balanceOf(buyer), 0);
    }

    function test_partialFillRefundsLeftoverEthToFixedRecipient() public onlyFork {
        _shallowPool();
        uint256 sent = 40 ether;
        uint256 refundBefore = refund.balance;
        _launch(sent, _data(buyer, refund, 1e18));

        uint256 got = coin.balanceOf(buyer);
        uint256 refunded = refund.balance - refundBefore;
        assertGt(got, 1e18, "tokens delivered");
        assertGt(refunded, 20 ether, "most of the eth could not be taken");
        assertLt(refunded, sent, "something was spent");
        assertEq(address(devBuy).balance, dust, "no eth stranded");
        assertEq(coin.balanceOf(address(devBuy)), 0);
        assertGt(sent - refunded, 5 ether, "the pool took the depth it had");
    }

    function test_refundRecipientThatRejectsEthReverts() public onlyFork {
        _shallowPool();
        address rejecter = address(new RejectsEth());
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.EthRefundFailed.selector);
        _launch(40 ether, _data(buyer, rejecter, 1e18));
        assertEq(coin.balanceOf(buyer), 0, "whole launch reverted");
    }

    function test_erc165AndBindings() public onlyFork {
        assertTrue(devBuy.supportsInterface(type(IArtCoinsExtensionV2).interfaceId));
        assertTrue(devBuy.supportsInterface(type(IConstantsBound).interfaceId));
        assertTrue(devBuy.supportsInterface(type(IERC165).interfaceId));
        assertFalse(devBuy.supportsInterface(0xffffffff));
        assertEq(devBuy.constantsHash(), Constants.hash());
        assertEq(devBuy.factory(), address(stub));
        assertEq(address(devBuy.poolManager()), POOL_MANAGER);
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.ZeroAddress.selector);
        new ArtCoinsUniv4EthDevBuyV2(address(0), POOL_MANAGER);
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.ZeroAddress.selector);
        new ArtCoinsUniv4EthDevBuyV2(address(stub), address(0));
    }
}

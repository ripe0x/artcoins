// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// shared fixture for the hooks / mev review proofs. no fork: deploys a fresh
// v4 PoolManager locally, places the hooks at flag-valid addresses by running
// their initcode in place (same technique as forge's deployCodeTo, which also
// sidesteps the EIP-170 limit the skim hook sits on at optimizer_runs 20000),
// and acts as the factory itself.

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArtCoinsFeeEscrow} from "../../../../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookSkimFee} from "../../../../src/hooks/ArtCoinsHookSkimFee.sol";
import {ArtCoinsHookStaticFee} from "../../../../src/hooks/ArtCoinsHookStaticFee.sol";
import {
    ArtCoinsPoolExtensionAllowlist
} from "../../../../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {
    IArtCoinsHookSkimFee,
    IReferralPayoutForHook,
    PCAttribution,
    PCSwapData
} from "../../../../src/hooks/interfaces/IArtCoinsHookSkimFee.sol";
import {IArtCoinsHookStaticFee} from "../../../../src/hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {IArtCoinsHook} from "../../../../src/interfaces/IArtCoinsHook.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract HMArt is ERC20 {
    address public admin;

    constructor(address admin_) ERC20("Art", "ART") {
        admin = admin_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// plain contract that accepts eth via receive and has no fallback
contract HMEthSink {
    receive() external payable {}
}

/// contract with an empty payable fallback: answers ANY selector with
/// success and zero bytes of return data (same shape as a Safe proxy with no
/// fallback handler). no withdraw path.
contract HMEmptyFallback {
    fallback() external payable {}
}

/// rejects all eth
contract HMRejecter {
    receive() external payable {
        revert("no eth");
    }
}

contract HMReferralPayout is IReferralPayoutForHook {
    mapping(address => uint256) public credited;

    function notify(address referrer) external payable override {
        credited[referrer] += msg.value;
    }
}

abstract contract HooksMevBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SKIM_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant STATIC_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint24 internal constant DYNAMIC_FEE = 0x800000;
    int24 internal constant TS = 60;

    IPoolManager internal pm;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    ArtCoinsFeeEscrow internal escrow;
    ArtCoinsPoolExtensionAllowlist internal allowlist;
    ArtCoinsHookSkimFee internal skimHook;
    ArtCoinsHookStaticFee internal staticHook;
    address internal weth = address(0xEEEE);
    address internal protocolR = address(0xBEEF01);

    function setUp() public virtual {
        pm = IPoolManager(address(new PoolManager(address(this))));
        escrow = new ArtCoinsFeeEscrow(address(this));
        allowlist = new ArtCoinsPoolExtensionAllowlist(address(this));

        bytes memory args =
            abi.encode(address(pm), address(this), address(allowlist), weth, address(escrow));
        address skimAt = address(uint160(uint256(0xA11CE) << 140) | SKIM_FLAGS);
        address staticAt = address(uint160(uint256(0xB0B0B) << 140) | STATIC_FLAGS);
        _deployAt(abi.encodePacked(type(ArtCoinsHookSkimFee).creationCode, args), skimAt);
        _deployAt(abi.encodePacked(type(ArtCoinsHookStaticFee).creationCode, args), staticAt);
        skimHook = ArtCoinsHookSkimFee(payable(skimAt));
        staticHook = ArtCoinsHookStaticFee(payable(staticAt));
        escrow.addDepositor(skimAt);
        escrow.addDepositor(staticAt);

        swapRouter = new PoolSwapTest(pm);
        liqRouter = new PoolModifyLiquidityTest(pm);
        vm.deal(address(this), 10_000 ether);
    }

    receive() external payable {}

    function _deployAt(bytes memory initcode, address target) internal {
        vm.etch(target, initcode);
        (bool ok, bytes memory runtime) = target.call("");
        require(ok, "ctor failed");
        vm.etch(target, runtime);
    }

    // ─── pool builders ───────────────────────────────────────────────────

    function _newArt() internal returns (HMArt t) {
        t = new HMArt(address(this));
        t.mint(address(this), 1_000_000_000 ether);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(liqRouter), type(uint256).max);
    }

    function _skimFeeData(
        uint24 baseline,
        uint16 bountyBps,
        uint24 maxRef,
        address bounty,
        address referralPayout
    ) internal view returns (bytes memory) {
        return abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: baseline,
                bountyBps: bountyBps,
                maxReferralBpsOfVolume: maxRef,
                lpFee: 10_000,
                bountyRecipient: payable(bounty),
                protocolRecipient: payable(protocolR),
                referralPayout: payable(referralPayout),
                quoteToken: address(0)
            })
        );
    }

    function _poolData(bytes memory feeData) internal pure returns (bytes memory) {
        return abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );
    }

    /// skim pool, ETH = currency0, art = currency1, price 1:1, no mev module
    function _skimPool(address art, bytes memory feeData, address lockerAddr, address mod)
        internal
        returns (PoolKey memory key)
    {
        key = skimHook.initializePool(art, address(0), 0, TS, lockerAddr, mod, _poolData(feeData));
    }

    function _staticPool(address art, uint24 artCoinFee, uint24 pairedFee, address mod)
        internal
        returns (PoolKey memory key)
    {
        bytes memory feeData = abi.encode(
            IArtCoinsHookStaticFee.PoolStaticConfigVars({
                artCoinFee: artCoinFee, pairedFee: pairedFee
            })
        );
        key = staticHook.initializePool(
            art, address(0), 0, TS, address(0x10C), mod, _poolData(feeData)
        );
    }

    function _addLiquidity(PoolKey memory key, int24 lower, int24 upper, uint256 liq) internal {
        liqRouter.modifyLiquidity{value: 2000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(liq), salt: 0
            }),
            ""
        );
    }

    function _swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        bytes memory hookData,
        uint256 value
    ) internal returns (BalanceDelta d) {
        if (limit == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        d = swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _attributionData(address referrer, uint24 bps) internal pure returns (bytes memory) {
        PCSwapData memory inner = PCSwapData({
            attribution: PCAttribution({
                sourceId: bytes32(0), referrer: referrer, campaignId: bytes16(0), referralBps: bps
            }),
            extensionPayload: ""
        });
        return abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: "", poolExtensionSwapData: abi.encode(inner)
            })
        );
    }

    function _lpFee(PoolKey memory key) internal view returns (uint24 fee) {
        (,,, fee) = pm.getSlot0(key.toId());
    }
}

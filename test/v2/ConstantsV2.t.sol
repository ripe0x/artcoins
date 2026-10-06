// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../src/Constants.sol";
import {IArtCoinsExtensionV2} from "../../src/v2/interfaces/IArtCoinsExtensionV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsKeeperV2} from "../../src/v2/interfaces/IArtCoinsKeeperV2.sol";
import {IArtCoinsLpLockerV2} from "../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {IArtCoinsMevSkimV2} from "../../src/v2/interfaces/IArtCoinsMevSkimV2.sol";
import {IArtCoinsTokenV2} from "../../src/v2/interfaces/IArtCoinsTokenV2.sol";
import {IBurnRouterV2} from "../../src/v2/interfaces/IBurnRouterV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {IFeeAutoSwapperV2} from "../../src/v2/interfaces/IFeeAutoSwapperV2.sol";
import {IProtocolFeeControllerV2} from "../../src/v2/interfaces/IProtocolFeeControllerV2.sol";
import {IReferralPayoutForHook} from "../../src/v2/interfaces/IReferralPayoutForHook.sol";

/// @notice Pins `Constants`. Any edit to a constant must update the literals
///         here; any edit to a hashed constant also changes the golden hash.
contract ConstantsV2Test is Test {
    /// @dev Update only together with an intended change to a hashed constant.
    bytes32 internal constant GOLDEN_HASH =
        0x0043610e634c3c3433ed1d5f6eaa5a90af502ba9d9bfa503deda2b1064d35684;

    function _literalHash() internal pure returns (bytes32) {
        bytes32 pool = keccak256(
            abi.encode(
                uint16(2), // STACK_VERSION
                uint256(10_000), // BPS
                uint256(100_000), // SKIM_DENOMINATOR
                uint256(1_000_000), // FEE_DENOMINATOR
                uint24(100_000), // MAX_LP_FEE
                uint24(90_000), // MAX_SKIM_BPS
                uint24(10_000), // MAX_BASELINE_SKIM_BPS
                uint24(1_000), // MAX_REFERRAL_CAP_OF_VOLUME
                uint16(9_999), // MAX_BOUNTY_BPS
                uint32(60), // MIN_MEV_WINDOW
                uint32(4_140), // DEFAULT_MEV_WINDOW
                uint32(10_800), // MAX_MEV_WINDOW
                uint24(68_690) // DEFAULT_START_SKIM_BPS
            )
        );
        bytes32 delivery = keccak256(
            abi.encode(
                uint32(10_000), // PUSH_GAS_MIN
                uint32(50_000), // PUSH_GAS_DEFAULT
                uint32(150_000), // PUSH_GAS_MAX
                uint32(30_000), // STREAM_GAS_MIN
                uint32(150_000), // STREAM_GAS_DEFAULT
                uint32(500_000), // STREAM_GAS_MAX
                uint96(1e16), // STREAM_MIN_BALANCE_DEFAULT
                uint96(10e18) // STREAM_MIN_BALANCE_MAX
            )
        );
        bytes32 launch = keccak256(
            abi.encode(
                uint256(7), // MAX_REWARD_PARTICIPANTS
                uint256(14), // MAX_LP_POSITIONS
                uint256(1e27), // DEFAULT_TOKEN_SUPPLY
                uint256(1e18), // MIN_TOKEN_SUPPLY
                uint256(10), // MAX_EXTENSIONS
                uint16(9_000), // MAX_EXTENSION_BPS
                uint16(3_000), // MAX_PROTOCOL_FEE_BPS
                uint8(0), // TAX_MODE_NONE
                uint8(1), // TAX_MODE_VENUE
                uint8(2), // TAX_MODE_HARD
                uint16(2_000), // TAX_BPS_ABSOLUTE_MAX
                uint256(32), // MAX_TAX_VENUES
                uint256(16), // MAX_TAX_EXEMPT
                address(0x000000000000000000000000000000000000dEaD) // DEAD
            )
        );
        bytes32 keeper = keccak256(
            abi.encode(
                uint256(50), // KEEPER_REWARD_BPS
                uint256(1e16), // KEEPER_REWARD_CAP
                uint256(8_000) // SPOT_FLOOR_BPS
            )
        );
        return keccak256(abi.encode(pool, delivery, launch, keeper));
    }

    function test_hash_matchesLiterals() public pure {
        assertEq(Constants.hash(), _literalHash(), "Constants.hash() drifted from literals");
    }

    function test_hash_golden() public pure {
        assertEq(Constants.hash(), GOLDEN_HASH, "hashed constant changed: bump GOLDEN_HASH");
    }

    function test_stackVersion() public pure {
        assertEq(Constants.STACK_VERSION, 2);
    }

    /// @dev Pins every value, hashed or not.
    function test_literals_all() public pure {
        assertEq(Constants.BPS, 10_000);
        assertEq(Constants.SKIM_DENOMINATOR, 100_000);
        assertEq(Constants.FEE_DENOMINATOR, 1_000_000);
        assertEq(Constants.MAX_LP_FEE, 100_000);
        assertEq(Constants.MAX_SKIM_BPS, 90_000);
        assertEq(Constants.MAX_BASELINE_SKIM_BPS, 10_000);
        assertEq(Constants.MAX_REFERRAL_CAP_OF_VOLUME, 1_000);
        assertEq(Constants.MAX_BOUNTY_BPS, 9_999);
        assertEq(Constants.PUSH_GAS_MIN, 10_000);
        assertEq(Constants.PUSH_GAS_DEFAULT, 50_000);
        assertEq(Constants.PUSH_GAS_MAX, 150_000);
        assertEq(Constants.STREAM_GAS_MIN, 30_000);
        assertEq(Constants.STREAM_GAS_DEFAULT, 150_000);
        assertEq(Constants.STREAM_GAS_MAX, 500_000);
        assertEq(Constants.STREAM_MIN_BALANCE_DEFAULT, 0.01 ether);
        assertEq(Constants.STREAM_MIN_BALANCE_MAX, 10 ether);
        assertEq(Constants.MIN_MEV_WINDOW, 1 minutes);
        assertEq(Constants.DEFAULT_MEV_WINDOW, 69 minutes);
        assertEq(Constants.MAX_MEV_WINDOW, 180 minutes);
        assertEq(Constants.DEFAULT_START_SKIM_BPS, 68_690);
        assertEq(Constants.MAX_REWARD_PARTICIPANTS, 7);
        assertEq(Constants.MAX_LP_POSITIONS, 14);
        assertEq(Constants.LOCKER_KEEPER_BPS_MAX, 200);
        assertEq(Constants.LOCKER_KEEPER_CAP_MIN, 0.001 ether);
        assertEq(Constants.LOCKER_KEEPER_CAP_MAX, 0.05 ether);
        assertEq(Constants.DEFAULT_TOKEN_SUPPLY, 1_000_000_000e18);
        assertEq(Constants.MIN_TOKEN_SUPPLY, 1e18);
        assertEq(Constants.MAX_EXTENSIONS, 10);
        assertEq(Constants.MAX_EXTENSION_BPS, 9_000);
        assertEq(Constants.MAX_PROTOCOL_FEE_BPS, 3_000);
        assertEq(Constants.MAX_DEPLOY_FEE, 1 ether);
        assertEq(Constants.TAX_MODE_NONE, 0);
        assertEq(Constants.TAX_MODE_VENUE, 1);
        assertEq(Constants.TAX_MODE_HARD, 2);
        assertEq(Constants.TAX_BPS_ABSOLUTE_MAX, 2_000);
        assertEq(Constants.MAX_TAX_VENUES, 32);
        assertEq(Constants.MAX_TAX_EXEMPT, 16);
        assertEq(Constants.DEAD, 0x000000000000000000000000000000000000dEaD);
        assertEq(Constants.KEEPER_REWARD_BPS, 50);
        assertEq(Constants.KEEPER_REWARD_CAP, 0.01 ether);
        assertEq(Constants.SPOT_FLOOR_BPS, 8_000);
        assertEq(Constants.SWAPPER_SLIPPAGE_MIN, 50);
        assertEq(Constants.SWAPPER_SLIPPAGE_MAX, 1_000);
        assertEq(Constants.SWAPPER_MIN_BLOCKS_MIN, 1);
        assertEq(Constants.SWAPPER_MIN_BLOCKS_MAX, 50_400);
        assertEq(Constants.BURN_IMPACT_MIN, 25);
        assertEq(Constants.BURN_IMPACT_DEFAULT, 100);
        assertEq(Constants.BURN_IMPACT_MAX, 300);
        assertEq(Constants.BURN_THRESHOLD_FLOOR, 0.001 ether);
        assertEq(Constants.PFC_MIN_TREASURY_BPS, 4_000);
        assertEq(Constants.PFC_MIN_BURN_BPS, 1_000);
        assertEq(Constants.MAX_GLYPHS, 256);
        assertEq(Constants.RENDER_GAS_BUDGET, 8_000_000);
        assertEq(Constants.HOOK_SIZE_HEADROOM_MIN, 1_024);
        assertEq(Constants.LEG_BOUNTY, 0);
        assertEq(Constants.LEG_PROTOCOL, 1);
        assertEq(Constants.LEG_REFERRAL, 2);
    }

    /// @dev min < default < max for every bounded tunable, and cross bound sanity.
    function test_bounds_ordering() public pure {
        assertLt(Constants.PUSH_GAS_MIN, Constants.PUSH_GAS_DEFAULT);
        assertLt(Constants.PUSH_GAS_DEFAULT, Constants.PUSH_GAS_MAX);
        assertLt(Constants.STREAM_GAS_MIN, Constants.STREAM_GAS_DEFAULT);
        assertLt(Constants.STREAM_GAS_DEFAULT, Constants.STREAM_GAS_MAX);
        assertLt(Constants.STREAM_MIN_BALANCE_DEFAULT, Constants.STREAM_MIN_BALANCE_MAX);
        assertLt(Constants.MIN_MEV_WINDOW, Constants.DEFAULT_MEV_WINDOW);
        assertLt(Constants.DEFAULT_MEV_WINDOW, Constants.MAX_MEV_WINDOW);
        assertLt(Constants.BURN_IMPACT_MIN, Constants.BURN_IMPACT_DEFAULT);
        assertLt(Constants.BURN_IMPACT_DEFAULT, Constants.BURN_IMPACT_MAX);
        assertLt(Constants.LOCKER_KEEPER_CAP_MIN, Constants.LOCKER_KEEPER_CAP_MAX);
        assertLt(Constants.SWAPPER_SLIPPAGE_MIN, Constants.SWAPPER_SLIPPAGE_MAX);
        assertLt(Constants.SWAPPER_MIN_BLOCKS_MIN, Constants.SWAPPER_MIN_BLOCKS_MAX);
        assertLt(Constants.MIN_TOKEN_SUPPLY, Constants.DEFAULT_TOKEN_SUPPLY);

        // skim: baseline and starting skim within the anti sniper ceiling, all within 100%
        assertLe(Constants.MAX_BASELINE_SKIM_BPS, Constants.MAX_SKIM_BPS);
        assertLe(Constants.DEFAULT_START_SKIM_BPS, Constants.MAX_SKIM_BPS);
        assertLt(Constants.MAX_SKIM_BPS, Constants.SKIM_DENOMINATOR);
        assertLe(Constants.MAX_REFERRAL_CAP_OF_VOLUME, Constants.MAX_BASELINE_SKIM_BPS);
        assertLt(Constants.MAX_BOUNTY_BPS, Constants.BPS);
        assertLt(Constants.MAX_LP_FEE, Constants.FEE_DENOMINATOR);
        // shares and caps within 100%
        assertLt(Constants.MAX_PROTOCOL_FEE_BPS, Constants.BPS);
        assertLt(Constants.MAX_EXTENSION_BPS, Constants.BPS);
        assertLt(Constants.TAX_BPS_ABSOLUTE_MAX, Constants.BPS);
        assertLe(Constants.LOCKER_KEEPER_BPS_MAX, Constants.BPS);
        assertLe(Constants.KEEPER_REWARD_BPS, Constants.BPS);
        assertLe(Constants.SPOT_FLOOR_BPS, Constants.BPS);
        assertLe(uint256(Constants.PFC_MIN_TREASURY_BPS) + Constants.PFC_MIN_BURN_BPS, Constants.BPS);
        assertLt(Constants.BURN_IMPACT_MAX, Constants.BPS);
        // tax modes distinct and ordered
        assertLt(Constants.TAX_MODE_NONE, Constants.TAX_MODE_VENUE);
        assertLt(Constants.TAX_MODE_VENUE, Constants.TAX_MODE_HARD);
        // ci gate fits under EIP-170
        assertLt(Constants.HOOK_SIZE_HEADROOM_MIN, 24_576);
    }

    /// @dev Interface ids used for erc165 checks are stable and non zero.
    function test_interfaceIds_nonZero() public pure {
        assertTrue(type(IFeeAutoSwapperV2).interfaceId != bytes4(0));
        assertTrue(type(IArtCoinsMevSkimV2).interfaceId != bytes4(0));
        assertTrue(type(IArtCoinsExtensionV2).interfaceId != bytes4(0));
        assertTrue(type(IConstantsBound).interfaceId == IConstantsBound.constantsHash.selector);
        // touch every interface so the suite compiles them
        assertTrue(type(IArtCoinsFactoryV2).interfaceId != bytes4(0));
        assertTrue(type(IArtCoinsHookV2).interfaceId != bytes4(0));
        assertTrue(type(IArtCoinsTokenV2).interfaceId != bytes4(0));
        assertTrue(type(IArtCoinsLpLockerV2).interfaceId != bytes4(0));
        assertTrue(type(IArtCoinsFeeEscrowV2).interfaceId != bytes4(0));
        assertTrue(type(IBurnRouterV2).interfaceId != bytes4(0));
        assertTrue(type(IProtocolFeeControllerV2).interfaceId != bytes4(0));
        assertTrue(type(IArtCoinsKeeperV2).interfaceId != bytes4(0));
        assertTrue(type(IReferralPayoutForHook).interfaceId != bytes4(0));
    }
}

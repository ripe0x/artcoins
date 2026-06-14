// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsMevModule} from "../src/interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../src/interfaces/IArtCoinsMevModuleBase.sol";

import {ArtCoinsMevDescendingFees} from "../src/mev-modules/ArtCoinsMevDescendingFees.sol";
import {ArtCoinsMevLinearFees} from "../src/mev-modules/ArtCoinsMevLinearFees.sol";
import {ArtCoinsMevLinearSkim} from "../src/mev-modules/ArtCoinsMevLinearSkim.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";
import {ArtCoinsMevTimeDelay} from "../src/mev-modules/ArtCoinsMevTimeDelay.sol";
import {IArtCoinsMevSkim} from "../src/mev-modules/interfaces/IArtCoinsMevSkim.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";

/// @title  MevModuleBaseInterfaceTest
/// @notice Pins the post-refactor MEV-module interface ids and proves the
///         factory's `setMevModule` gate keys off the shared
///         {IArtCoinsMevModuleBase} id — so both fee-dialing modules AND the
///         skim module (which no longer implements `beforeSwap`) register,
///         while a contract that implements neither the base nor a kind is
///         rejected.
/// @dev    The id values are HARD-PINNED. Factoring `initialize` /
///         `supportsInterface` into the base changed
///         `type(IArtCoinsMevModule).interfaceId` from the old three-selector
///         XOR to exactly `beforeSwap.selector`; the base id is the XOR of the
///         two selectors it now owns. If any of these signatures change, these
///         literals must be re-derived intentionally.
contract MevModuleBaseInterfaceTest is Test {
    /// @dev `initialize.selector ^ supportsInterface.selector`.
    bytes4 internal constant BASE_ID = 0x65a5dc93;
    /// @dev `beforeSwap.selector` (the only selector now declared directly on
    ///      `IArtCoinsMevModule`).
    bytes4 internal constant MEV_MODULE_ID = 0x831d7dd2;

    ArtCoinsFactory internal factory;

    ArtCoinsMevLinearSkim internal skim;
    ArtCoinsMevLinearFees internal linearFees;
    ArtCoinsMevDescendingFees internal descendingFees;
    ArtCoinsMevSniperSteppedFees internal sniperFees;
    ArtCoinsMevTimeDelay internal timeDelay;

    function setUp() public {
        // The test contract is the factory owner, so it may call setMevModule.
        factory = new ArtCoinsFactory(address(this));

        skim = new ArtCoinsMevLinearSkim();
        linearFees = new ArtCoinsMevLinearFees();
        descendingFees = new ArtCoinsMevDescendingFees();
        sniperFees = new ArtCoinsMevSniperSteppedFees();
        timeDelay = new ArtCoinsMevTimeDelay(60);
    }

    // ─── interface-id pinning ────────────────────────────────────────────

    function test_baseInterfaceId_isInitXorSupportsInterface() public pure {
        // Solidity excludes inherited functions from `type(I).interfaceId`, so
        // the base id is exactly the XOR of the two selectors it declares.
        assertEq(
            bytes32(type(IArtCoinsMevModuleBase).interfaceId),
            bytes32(
                IArtCoinsMevModuleBase.initialize.selector
                    ^ IArtCoinsMevModuleBase.supportsInterface.selector
            )
        );
        assertEq(bytes32(type(IArtCoinsMevModuleBase).interfaceId), bytes32(BASE_ID));
    }

    function test_mevModuleInterfaceId_isBeforeSwapOnly() public pure {
        // `IArtCoinsMevModule` now declares only `beforeSwap` directly;
        // `initialize` / `supportsInterface` are inherited from the base and
        // excluded from the id. So its id collapses to the beforeSwap selector.
        assertEq(
            bytes32(type(IArtCoinsMevModule).interfaceId),
            bytes32(IArtCoinsMevModule.beforeSwap.selector)
        );
        assertEq(bytes32(type(IArtCoinsMevModule).interfaceId), bytes32(MEV_MODULE_ID));
    }

    function test_interfaceIds_areDisjoint() public pure {
        bytes4 base = type(IArtCoinsMevModuleBase).interfaceId;
        assertTrue(base != type(IArtCoinsMevModule).interfaceId);
        assertTrue(base != type(IArtCoinsMevSkim).interfaceId);
        assertTrue(base != type(IERC165).interfaceId);
        assertTrue(type(IArtCoinsMevModule).interfaceId != type(IArtCoinsMevSkim).interfaceId);
    }

    // ─── every module advertises the base id ─────────────────────────────

    function test_allModulesAdvertiseBaseId() public view {
        bytes4 base = type(IArtCoinsMevModuleBase).interfaceId;
        assertTrue(skim.supportsInterface(base), "skim");
        assertTrue(linearFees.supportsInterface(base), "linearFees");
        assertTrue(descendingFees.supportsInterface(base), "descendingFees");
        assertTrue(sniperFees.supportsInterface(base), "sniperFees");
        assertTrue(timeDelay.supportsInterface(base), "timeDelay");
    }

    function test_skimIsNotAnIArtCoinsMevModule_butFeeModulesAre() public view {
        bytes4 mevModuleId = type(IArtCoinsMevModule).interfaceId;
        // The skim module shed `beforeSwap` — it must NOT advertise the
        // fee-module id (only the base + skim kind).
        assertFalse(skim.supportsInterface(mevModuleId));
        assertTrue(skim.supportsInterface(type(IArtCoinsMevSkim).interfaceId));
        // Fee modules are still fee-dialing IArtCoinsMevModules.
        assertTrue(linearFees.supportsInterface(mevModuleId));
        assertTrue(descendingFees.supportsInterface(mevModuleId));
        assertTrue(sniperFees.supportsInterface(mevModuleId));
        assertTrue(timeDelay.supportsInterface(mevModuleId));
    }

    // ─── factory gate keys off the base id ───────────────────────────────

    function test_setMevModule_acceptsSkimAndAllFeeModules() public {
        // Base-gated, so both the skim module and every fee module register
        // without reverting.
        factory.setMevModule(address(skim), true);
        factory.setMevModule(address(linearFees), true);
        factory.setMevModule(address(descendingFees), true);
        factory.setMevModule(address(sniperFees), true);
        factory.setMevModule(address(timeDelay), true);

        assertTrue(factory.enabledMevModules(address(skim)));
        assertTrue(factory.enabledMevModules(address(linearFees)));
        assertTrue(factory.enabledMevModules(address(descendingFees)));
        assertTrue(factory.enabledMevModules(address(sniperFees)));
        assertTrue(factory.enabledMevModules(address(timeDelay)));
    }

    function test_setMevModule_rejectsNonConforming() public {
        NotAMevModule bad = new NotAMevModule();
        vm.expectRevert(IArtCoinsFactory.InvalidMevModule.selector);
        factory.setMevModule(address(bad), true);
    }
}

/// @dev Supports ERC-165 but NOT the MEV-module base — the factory gate must
///      reject it (`InvalidMevModule`).
contract NotAMevModule {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

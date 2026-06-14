// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";

interface IHookView {
    function protocolFeeNumerator() external view returns (uint256);
}

interface IExtensionFactory {
    function factory() external view returns (address);
}

interface ILayerCounterView {
    function hook() external view returns (address);
}

interface ILayerRendererView {
    function counter() external view returns (address);
}

/// @title PreflightLaunch
/// @notice Pre-broadcast sanity check for the LAYER launch on either
///         mainnet or Sepolia. Reads `.env`, prints every address it will
///         use, and reports any drift from the expected values
///         (mismatched WETH, wrong starting tick, missing code, factory
///         not wired to ProtocolFeeController, hook protocolFeeNumerator
///         non-zero, deployer EOA balance below the deploy fee, etc.).
///
///         Read-only — never broadcasts.
///
/// Usage:
///   forge script script/PreflightLaunch.s.sol --rpc-url $MAINNET_RPC_URL
///   forge script script/PreflightLaunch.s.sol --rpc-url $SEPOLIA_RPC_URL
contract PreflightLaunch is Script {
    // Mainnet WETH + infra
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant MAINNET_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant MAINNET_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    // Sepolia WETH + infra
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant SEPOLIA_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant SEPOLIA_UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;

    int24 constant LAYER_STARTING_TICK = -190_400;

    uint256 internal failures;
    uint256 internal warnings;

    function run() public {
        string memory net;
        address expectedWeth;
        address expectedPoolManager;
        address expectedPositionManager;
        address expectedUniversalRouter;
        if (block.chainid == 1) {
            net = "mainnet";
            expectedWeth = MAINNET_WETH;
            expectedPoolManager = MAINNET_POOL_MANAGER;
            expectedPositionManager = MAINNET_POSITION_MANAGER;
            expectedUniversalRouter = MAINNET_UNIVERSAL_ROUTER;
        } else if (block.chainid == 11_155_111) {
            net = "Sepolia";
            expectedWeth = SEPOLIA_WETH;
            expectedPoolManager = SEPOLIA_POOL_MANAGER;
            expectedPositionManager = SEPOLIA_POSITION_MANAGER;
            expectedUniversalRouter = SEPOLIA_UNIVERSAL_ROUTER;
        } else {
            console2.log("FATAL: unsupported chain", block.chainid);
            revert("Unsupported chain. Use mainnet (1) or Sepolia (11155111).");
        }

        console2.log("=== Preflight: LAYER launch ===");
        console2.log("Network: ", net);
        console2.log("ChainId: ", block.chainid);
        console2.log("");

        _checkRoles();
        _checkConstants(expectedWeth);
        _checkInfra(expectedPoolManager, expectedPositionManager, expectedUniversalRouter);
        _checkStack();
        _checkDeployerBalance();

        console2.log("");
        console2.log("=== SUMMARY ===");
        console2.log("Failures: ", failures);
        console2.log("Warnings: ", warnings);
        if (failures > 0) {
            revert("Preflight FAILED. Fix the issues above before broadcasting.");
        }
        if (warnings > 0) {
            console2.log("Preflight passed with warnings. Review them carefully.");
        } else {
            console2.log("Preflight PASSED. Safe to proceed with broadcast.");
        }
    }

    // ─── Sections ──────────────────────────────────────────────────────
    function _checkRoles() internal {
        console2.log("--- Roles ---");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address artistTreasury = _envOptional("ARTIST_TREASURY");
        address artistRecipient = _envOptional("ARTIST_RECIPIENT");
        address feeAdmin = _envOptional("FEE_ADMIN");
        address protocolTreasury = _envOptional("PROTOCOL_TREASURY");

        console2.log("Deployer EOA:        ", deployer);
        console2.log("ARTIST_TREASURY:     ", artistTreasury);
        console2.log(
            "ARTIST_RECIPIENT:    ",
            artistRecipient == address(0) ? "(unset, defaults to ARTIST_TREASURY)" : "(set)"
        );
        console2.log("ARTIST_RECIPIENT raw:", artistRecipient);
        console2.log("FEE_ADMIN:           ", feeAdmin);
        console2.log("PROTOCOL_TREASURY:   ", protocolTreasury);

        _failIfZero(artistTreasury, "ARTIST_TREASURY missing");
        _failIfZero(feeAdmin, "FEE_ADMIN missing");
        _failIfZero(protocolTreasury, "PROTOCOL_TREASURY missing");

        if (artistTreasury == deployer && feeAdmin == deployer && protocolTreasury == deployer) {
            _warn(
                "All admin roles point to the deployer EOA - acceptable for a test launch but use a multisig for production."
            );
        }
        console2.log("");
    }

    function _checkConstants(address expectedWeth) internal {
        console2.log("--- Constants ---");
        int24 startingTick = int24(vm.envInt("STARTING_TICK"));
        console2.log("STARTING_TICK env:   ", int256(startingTick));
        console2.log("LAYER preset tick:   ", int256(LAYER_STARTING_TICK));
        if (startingTick != LAYER_STARTING_TICK) {
            _fail("STARTING_TICK does not match LAYER preset (-190400). LaunchLayer will revert.");
        }
        address weth = _envOptional("WETH");
        console2.log("WETH env:            ", weth);
        console2.log("WETH expected:       ", expectedWeth);
        if (weth == address(0)) {
            _warn(
                "WETH env unset. LaunchLayer hard-codes its own WETH but DeployProtocolFeeStack reads this."
            );
        } else if (weth != expectedWeth) {
            _fail("WETH env does not match expected for this chain.");
        }
        console2.log("");
    }

    function _checkInfra(address pm, address posm, address ur) internal {
        console2.log("--- Uniswap v4 infra (expected to be present on this chain) ---");
        _checkHasCode(pm, "PoolManager");
        _checkHasCode(posm, "PositionManager");
        _checkHasCode(ur, "UniversalRouter");
        _checkHasCode(0x000000000022D473030F116dDEE9F6B43aC78BA3, "Permit2");
        console2.log("");
    }

    function _checkStack() internal {
        console2.log("--- ArtCoins stack ---");
        address factoryAddr = _envOptional("FACTORY");
        address hookAddr = _envOptional("HOOK");
        address lockerAddr = _envOptional("LOCKER");
        address airdropAddr = _envOptional("AIRDROP");
        address feeLockerAddr = _envOptional("FEE_LOCKER");
        address mevSniperStepped = _envOptional("MEV_SNIPER_STEPPED");
        address burnExtension = _envOptional("BURN_EXTENSION");
        address llCounter = _envOptional("LL_COUNTER");
        address llRenderer = _envOptional("LL_RENDERER");
        address burnRouterAddr = _envOptional("BURN_ROUTER");
        address controllerAddr = _envOptional("PROTOCOL_FEE_CONTROLLER");

        console2.log("FACTORY:                ", factoryAddr);
        console2.log("HOOK:                   ", hookAddr);
        console2.log("LOCKER:                 ", lockerAddr);
        console2.log("AIRDROP:                ", airdropAddr);
        console2.log("FEE_LOCKER:             ", feeLockerAddr);
        console2.log("MEV_SNIPER_STEPPED:     ", mevSniperStepped);
        console2.log("BURN_EXTENSION:         ", burnExtension);
        console2.log("LL_COUNTER:             ", llCounter);
        console2.log("LL_RENDERER:            ", llRenderer);
        console2.log("BURN_ROUTER:            ", burnRouterAddr);
        console2.log("PROTOCOL_FEE_CONTROLLER:", controllerAddr);

        _checkHasCode(factoryAddr, "FACTORY");
        _checkHasCode(hookAddr, "HOOK");
        _checkHasCode(lockerAddr, "LOCKER");
        _checkHasCode(airdropAddr, "AIRDROP");
        _checkHasCode(feeLockerAddr, "FEE_LOCKER");
        _checkHasCode(mevSniperStepped, "MEV_SNIPER_STEPPED");
        _checkHasCode(burnExtension, "BURN_EXTENSION");
        _checkHasCode(llCounter, "LL_COUNTER");
        _checkHasCode(llRenderer, "LL_RENDERER");
        _checkHasCode(burnRouterAddr, "BURN_ROUTER");
        _checkHasCode(controllerAddr, "PROTOCOL_FEE_CONTROLLER");

        // Wiring checks (only if everything has code)
        if (factoryAddr.code.length > 0) {
            ArtCoinsFactory factory = ArtCoinsFactory(factoryAddr);
            try factory.teamFeeRecipient() returns (address tfr) {
                if (tfr != controllerAddr) {
                    _fail("factory.teamFeeRecipient != PROTOCOL_FEE_CONTROLLER");
                }
                console2.log("factory.teamFeeRecipient:", tfr);
            } catch {
                _warn("factory.teamFeeRecipient view failed");
            }
            try factory.deprecated() returns (bool dep) {
                console2.log("factory.deprecated:     ", dep);
                if (dep) {
                    uint256 pk = vm.envUint("PRIVATE_KEY");
                    address deployer = vm.addr(pk);
                    bool deployerCanBypass;
                    try factory.owner() returns (address owner) {
                        deployerCanBypass = owner == deployer;
                    } catch {
                        _warn("factory.owner view failed");
                    }
                    try factory.admins(deployer) returns (bool isAdmin) {
                        deployerCanBypass = deployerCanBypass || isAdmin;
                    } catch {
                        _warn("factory.admins view failed");
                    }
                    if (!deployerCanBypass) {
                        _fail(
                            "factory.deprecated == true and deployer is not owner/admin. deployToken will revert."
                        );
                    }
                }
            } catch {
                _warn("factory.deprecated view failed");
            }
            try factory.defaultProtocolFeeBps() returns (uint16 bps) {
                console2.log("factory.defaultProtocolFeeBps:", bps);
                if (bps != 2000) {
                    _fail("factory.defaultProtocolFeeBps != 2000. LaunchLayer will revert.");
                }
            } catch {
                _warn("factory.defaultProtocolFeeBps view failed");
            }
            try factory.deployFee() returns (uint256 fee) {
                console2.log("factory.deployFee (wei):", fee);
            } catch {}
        }
        if (hookAddr.code.length > 0) {
            try IHookView(hookAddr).protocolFeeNumerator() returns (uint256 n) {
                console2.log("hook.protocolFeeNumerator:", n);
                if (n != 0) _fail("hook.protocolFeeNumerator != 0. LaunchLayer will revert.");
            } catch {
                _warn("hook.protocolFeeNumerator view failed");
            }
        }
        if (controllerAddr.code.length > 0) {
            ProtocolFeeController c = ProtocolFeeController(payable(controllerAddr));
            try c.treasury() returns (address t) {
                console2.log("controller.treasury:    ", t);
                address expectedTreasury = _envOptional("PROTOCOL_TREASURY");
                if (expectedTreasury != address(0) && t != expectedTreasury) {
                    _warn(
                        "controller.treasury != PROTOCOL_TREASURY env. Verify intentional (e.g., already migrated)."
                    );
                }
            } catch {}
        }
        if (burnRouterAddr.code.length > 0) {
            BurnRouter r = BurnRouter(payable(burnRouterAddr));
            try r.initialized() returns (bool init) {
                console2.log("burnRouter.initialized: ", init);
                if (init) {
                    try r.layerToken() returns (address lt) {
                        console2.log("burnRouter.layerToken:  ", lt);
                        _warn(
                            "BurnRouter is already initialized. LaunchLayer's preflight will require it to bind to the predicted LAYER address."
                        );
                    } catch {}
                }
            } catch {}
            try r.owner() returns (address o) {
                console2.log("burnRouter.owner:       ", o);
                uint256 pk = vm.envUint("PRIVATE_KEY");
                address deployer = vm.addr(pk);
                if (o != deployer) {
                    _warn(
                        "BurnRouter owner != deployer EOA. LaunchLayer requires deployer to be the router owner if router is uninitialized."
                    );
                }
            } catch {}
        }
        if (burnExtension.code.length > 0) {
            try IExtensionFactory(burnExtension).factory() returns (address f) {
                if (f != factoryAddr) {
                    _fail(
                        "BurnExtension.factory != FACTORY env. Re-deploy against the right factory."
                    );
                }
            } catch {}
        }
        if (llCounter.code.length > 0) {
            try ILayerCounterView(llCounter).hook() returns (address h) {
                if (h != hookAddr) _fail("LL_COUNTER.hook != HOOK env.");
            } catch {
                _warn("LL_COUNTER.hook view failed");
            }
        }
        if (llRenderer.code.length > 0) {
            try ILayerRendererView(llRenderer).counter() returns (address c) {
                if (c != llCounter) _fail("LL_RENDERER.counter != LL_COUNTER env.");
            } catch {
                _warn("LL_RENDERER.counter view failed");
            }
        }
        console2.log("");
    }

    function _checkDeployerBalance() internal {
        console2.log("--- Deployer EOA balance ---");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 bal = deployer.balance;
        console2.log("Deployer EOA:    ", deployer);
        console2.log("Balance (wei):   ", bal);
        console2.log("Balance (ether): ", bal / 1e18);
        // Heuristic: ~0.5 ETH covers Deploy + DeployProtocolFeeStack +
        // LaunchLayer with comfortable headroom.
        if (bal < 0.069 ether) {
            _fail("Deployer balance below the 0.069 ETH default deploy fee.");
        } else if (bal < 0.5 ether) {
            _warn(
                "Deployer balance under 0.5 ETH. Mainnet gas at peak may exhaust the EOA. Top up before broadcasting."
            );
        }
        console2.log("");
    }

    // ─── helpers ───────────────────────────────────────────────────────
    function _checkHasCode(address a, string memory label) internal {
        if (a == address(0)) {
            _warn(string.concat(label, " env unset"));
            return;
        }
        if (a.code.length == 0) {
            _fail(
                string.concat(label, " has no code on this chain. Re-deploy or update the env var.")
            );
        }
    }

    function _envOptional(string memory key) internal view returns (address) {
        return vm.envOr(key, address(0));
    }

    function _failIfZero(address a, string memory msg_) internal {
        if (a == address(0)) _fail(msg_);
    }

    function _fail(string memory msg_) internal {
        failures += 1;
        console2.log("  FAIL: ", msg_);
    }

    function _warn(string memory msg_) internal {
        warnings += 1;
        console2.log("  WARN: ", msg_);
    }
}

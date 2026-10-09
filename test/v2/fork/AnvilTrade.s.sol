// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Addresses} from "../../../script/Addresses.sol";
import {IArtCoinsLpLockerV2} from "../../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {FcExactIn, IFcPermit2, IFcUniversalRouter} from "./FirstCoinRehearsal.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Script, console2} from "forge-std/Script.sol";

/// Local anvil fork only. Env: TOKEN, MODE (buy|sell), AMOUNT (wei of eth for buy, coin units for sell).
/// Run with --unlocked --sender <non-allowlisted EOA> --broadcast.
contract AnvilTrade is Script {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    function run() external {
        address token = vm.envAddress("TOKEN");
        bool buy = keccak256(bytes(vm.envString("MODE"))) == keccak256("buy");
        uint256 amt = vm.envUint("AMOUNT");
        PoolKey memory key = IArtCoinsLpLockerV2(Addresses.V2_LOCKER).tokenRewards(token).poolKey;
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        vm.startBroadcast();
        if (buy) {
            params[0] = abi.encode(FcExactIn(key, true, uint128(amt), 0, ""));
            params[1] = abi.encode(key.currency0, amt);
            params[2] = abi.encode(key.currency1, uint256(0));
            bytes[] memory inputs = new bytes[](2);
            inputs[0] = abi.encode(actions, params);
            inputs[1] = abi.encode(address(0), vm.envAddress("TRADER"), uint256(0));
            IFcUniversalRouter(UR).execute{value: amt}(
                abi.encodePacked(uint8(0x10), uint8(0x04)), inputs, block.timestamp + 1 hours
            );
        } else {
            IERC20(token).approve(PERMIT2, type(uint256).max);
            IFcPermit2(PERMIT2)
                .approve(token, UR, type(uint160).max, uint48(block.timestamp + 1 days));
            params[0] = abi.encode(FcExactIn(key, false, uint128(amt), 0, ""));
            params[1] = abi.encode(key.currency1, amt);
            params[2] = abi.encode(key.currency0, uint256(0));
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(actions, params);
            IFcUniversalRouter(UR)
                .execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 1 hours);
        }
        vm.stopBroadcast();
    }
}

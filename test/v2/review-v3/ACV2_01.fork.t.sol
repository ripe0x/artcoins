// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "../../../src/v2/interfaces/IArtCoinsTokenV2.sol";
import {IntegrationV2Base} from "../integration/IntegrationV2Base.sol";
import {I1EmptyTreasury} from "../integration/mocks/I1Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice ACV2-01 regression under D73. The old attack bought canonically to
///         earn a spent exemption and then moved the coin out of a side venue
///         untaxed. With the tax retired and restriction on, a restricted coin
///         bought through the canonical pool cannot be sent to a non allowlisted
///         wallet, so the coins the old sequence moved stay restricted.
contract ACV2_01Regression is IntegrationV2Base {
    function _launchRestricted() internal returns (address coin, PoolKey memory key) {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c =
            _restrictedConfig(address(new I1EmptyTreasury()));
        coin = _ownerLaunch(c);
        key = _key(coin);
        _pastWindow();
    }

    function test_restricted_boughtCoinCannotMoveToWallet() public onlyFork {
        (address coin, PoolKey memory key) = _launchRestricted();
        uint256 got = _buy(key, 1 ether);
        assertGt(got, 0, "bought");
        assertEq(IERC20(coin).balanceOf(address(this)), got, "coin held by buyer");
        // the swap's granted allowance was fully consumed by the take.
        assertEq(IArtCoinsTokenV2(coin).transferAllowance(), 0, "no leftover allowance");
        // the coin is restricted: moving it to a non allowlisted wallet reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.TransferRestricted.selector, address(this), address(0xA11CE), got
            )
        );
        IERC20(coin).transfer(address(0xA11CE), got);
    }

    function test_restricted_roundTripResidualStaysRestricted() public onlyFork {
        (address coin, PoolKey memory key) = _launchRestricted();
        uint256 got = _buy(key, 1 ether);
        // sell half back; the coin side move to the PoolManager is covered by
        // that sell's own granted allowance.
        uint256 half = got / 2;
        _sell(key, half);
        uint256 residual = IERC20(coin).balanceOf(address(this));
        assertGt(residual, 0, "residual coin held");
        // whatever coin remains cannot be sent wallet to wallet.
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.TransferRestricted.selector,
                address(this),
                address(0xB0B),
                residual
            )
        );
        IERC20(coin).transfer(address(0xB0B), residual);
    }
}

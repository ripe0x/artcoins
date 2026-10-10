// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// generated from deployments/mainnet.json, do not edit.
// regenerate: cd script-js && npm run gen:addresses   (check: node script-js/verify-registry.mjs)

/// @title Addresses
/// @notice Ethereum mainnet addresses of the artcoins stacks, copied from the registry.
///         Constants are prefixed with the stack id. CURRENT_* is the 0x4959 stack (v1 abi), V2_* is the v2
///         stack, OPEN_* and LEGACY_* are older stacks. Scripts that target a superseded stack must say
///         so and be gated behind ALLOW_SUPERSEDED=1.
library Addresses {
    uint256 internal constant CHAIN_ID = 1;

    /// @dev owner of nearly every contract below (single eoa).
    address internal constant OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;

    // CURRENT stack (superseded): current stack (skim fee), factory deployed 2026-06-06
    address internal constant CURRENT_FACTORY = 0x49596c375c139E79bb937bcf826068a8F78D4e0e;
    address internal constant CURRENT_HOOK = 0x636c050296B5Cc528D8785169Bf8923716FCa9cc;
    address internal constant CURRENT_LOCKER = 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab;
    address internal constant CURRENT_ESCROW = 0x7559689765aE86cBB38e68CD1294830CccB125F2;
    address internal constant CURRENT_MEV_LINEAR_SKIM = 0xb038D597365FfD108D63C265Bb0621444a1D8B83;
    address internal constant CURRENT_DEPLOYER_LIB = 0x92584B320A8B871934A50b9D6f05833f6F82Cb81;
    address internal constant CURRENT_SKIM_INIT_LIB = 0x115510a709d1AfD798325F3FFb74B127a08dD3C9;
    address internal constant CURRENT_PROTOCOL_FEE_CONTROLLER =
        0xd8C63401268744d430EbE0C18412211421498013;
    address internal constant CURRENT_BURN_ROUTER = 0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca;
    address internal constant CURRENT_FEE_SWAPPER = 0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961;
    address internal constant CURRENT_LIVE_BID_ADAPTER = 0x8C72FBc2bB32e76aa54243F76745266a0F92CD01;
    address internal constant CURRENT_PROTOCOL_FEE_PHASE_ADAPTER =
        0xed3E9D3Bf693372060b7ce62aDB49650145b2ba9;
    address internal constant CURRENT_TOKEN_ADMIN_POKER =
        0xA96a11257890ED1C43C16c098E286e18e45E6258;
    address internal constant CURRENT_PAYOUT = 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4;
    address internal constant CURRENT_POOL_EXTENSION_ALLOWLIST =
        0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8;
    uint256 internal constant CURRENT_FACTORY_DEPLOY_BLOCK = 25_260_062;

    // OPEN stack (superseded): open stack (native eth, static fee), factory deployed 2026-05-19
    address internal constant OPEN_FACTORY = 0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e;
    address internal constant OPEN_HOOK = 0xAAd673ea3945dF5F7Ef328974d2c07c8BdcAA8Cc;
    address internal constant OPEN_LOCKER = 0xd914c864D9AEf3D8E51370139300aC534FB497b2;
    address internal constant OPEN_ESCROW = 0xDD1b8C9C99Be3C717B9A5eb3C84297C5bfca1C06;
    address internal constant OPEN_ALLOWLIST = 0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8;
    address internal constant OPEN_BURN_ROUTER = 0xE60046ee745B235109C10d322A1cbDB3c029De43;
    address internal constant OPEN_BURN_ROUTER_V0 = 0x9304a81965Ef3F7A092bd9eFd8c2fFc411E5F34d;
    uint256 internal constant OPEN_FACTORY_DEPLOY_BLOCK = 25_125_708;

    // V2 stack (current): v2 stack (skim hook v2, constants bound), factory deployed 2026-10-09
    address internal constant V2_FACTORY = 0x9b17bf6f97F5429368E11028BC637479b4667f7b;
    address internal constant V2_HOOK = 0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc;
    address internal constant V2_LOCKER = 0x1e2456861B864B96FFe6b34066b12FBD7EEb23fC;
    address internal constant V2_ESCROW = 0x32845df52436a737C9623Af1d461A1c9999BBc1e;
    address internal constant V2_ALLOWLIST = 0xddbC9EE6A8E08b4afC208B9dD1f283506E669C11;
    address internal constant V2_MEV_MODULE = 0xFbb55b4C13b8517C000e2686efB12F0FAAFc9072;
    address internal constant V2_DEPLOYER = 0xB2f0086E6EE82f059AD1736dD265a783cE50f473;
    address internal constant V2_BURN_ROUTER = 0x6f159a0BDddB808Ca364cd006fb29C7B52eB88e1;
    address internal constant V2_PROTOCOL_FEE_CONTROLLER =
        0x183De82db1b7AAb798328AB1d7AE181ff39460c2;
    address internal constant V2_KEEPER = 0x9884B79974a51aaa07b3a7f0B45b6Ae294FC7072;
    uint256 internal constant V2_FACTORY_DEPLOY_BLOCK = 26_157_200;

    // LEGACY stack (legacy): legacy stack (LAYER), factory deployed 2026-05-07
    address internal constant LEGACY_FACTORY = 0xD1595A2742C392d1c109b616b4F08918D02292f9;
    address internal constant LEGACY_HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc;
    address internal constant LEGACY_LOCKER = 0x75BE7E95745915fD0C1761B74F3f9650ad2d1118;
    address internal constant LEGACY_FEE_LOCKER = 0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05;
    address internal constant LEGACY_ALLOWLIST = 0xDD06Ba83198a2A74c3EE0C3a5405DB481bE601e4;
    address internal constant LEGACY_DEPLOYER_LIB = 0xbb0F4d9762387B2be45E4Ac6cAC2d264f98B82C2;
    address internal constant LEGACY_MEV_TIME_DELAY = 0xf080D741D069B107D728B68F781843d83A0EA8Fb;
    address internal constant LEGACY_MEV_DESCENDING_FEES =
        0x7958DE7d8C857CdD37465FB920A961B1f8F74301;
    address internal constant LEGACY_MEV_LINEAR_FEES = 0xAe19E402420359062eE422a03589e04a52cD8C6F;
    address internal constant LEGACY_MEV_SNIPER_STEPPED_FEES =
        0x1AB013ebEf60E82DFC55Ec90B0974A86d283B935;
    address internal constant LEGACY_VAULT = 0x84732a79e4Ec8F03063a138c7ef866a9d222C661;
    address internal constant LEGACY_AIRDROP = 0xF937dFf16a45E417951794758E77CbEd0A7F27eC;
    address internal constant LEGACY_BURN_EXTENSION = 0x034d6bAbBB067EEE4A67357B687c9B1267aEA1CE;
    address internal constant LEGACY_DEV_BUY = 0xfCB6a929dB98A1D69b5F33A2f7E073cB7449cF30;
    address internal constant LEGACY_DEFAULT_RENDERER = 0x7dBfF01528AC8B1e7c7B75eeCFA123962319070A;
    address internal constant LEGACY_LL_COUNTER_EXTENSION =
        0xc4a1E94749c0C3c608577FcD7567a5fBcAcE0A65;
    address internal constant LEGACY_LL_RENDERER = 0x0572C1754378c2f9Aef51b57b2830D343ee9d186;
    address internal constant LEGACY_LL_RENDERER_V0 = 0x93bDB2462d23720BE9A635F526287A3fD0f6D7d4;
    address internal constant LEGACY_AUTOFORWARD_EXTENSION =
        0x38d03af54ba9F80c3476B3D3B3a6415A399303f7;
    address internal constant LEGACY_BURN_ROUTER = 0x2eDBdF011768d8cd4Ef537658b41440900C52000;
    address internal constant LEGACY_PROTOCOL_FEE_CONTROLLER =
        0x5fDc39756A64A84518ef00CB6a0ED46971e00A60;
    uint256 internal constant LEGACY_FACTORY_DEPLOY_BLOCK = 25_040_120;

    // coins
    /// @dev Liquidity Layer, legacy stack
    address internal constant COIN_LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    /// @dev permanent collection, current stack
    address internal constant COIN_111 = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;

    // external infra (not in the registry)
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;
    address internal constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;
}

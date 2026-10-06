// generated from deployments/mainnet.json, do not edit.
// regenerate: cd script-js && npm run gen:addresses   (check: node script-js/verify-registry.mjs)
import type { Address } from 'viem';

export const REGISTRY_CHAIN_ID = 1;
export const REGISTRY_OWNER: Address = '0xCB43078C32423F5348Cab5885911C3B5faE217F9';

export type StackId = 'legacy' | 'open' | 'current';
export const CURRENT_STACK_ID: StackId = 'current';

export interface RegistryStack {
  label: string;
  status: 'current' | 'superseded' | 'legacy';
  factory: Address;
  deployedAt: string;
  /** block of the factory deployment, the fromBlock for TokenCreated scans */
  deployBlock: bigint;
}

export const STACKS: Record<StackId, RegistryStack> = {
  legacy: {
    label: 'legacy stack (LAYER)',
    status: 'legacy',
    factory: '0xD1595A2742C392d1c109b616b4F08918D02292f9',
    deployedAt: '2026-05-07',
    deployBlock: 25040120n,
  },
  open: {
    label: 'open stack (native eth, static fee)',
    status: 'superseded',
    factory: '0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e',
    deployedAt: '2026-05-19',
    deployBlock: 25125708n,
  },
  current: {
    label: 'current stack (skim fee)',
    status: 'current',
    factory: '0x49596c375c139E79bb937bcf826068a8F78D4e0e',
    deployedAt: '2026-06-06',
    deployBlock: 25260062n,
  },
};

/** addresses of the stack with id current */
export const CURRENT = {
  factory: '0x49596c375c139E79bb937bcf826068a8F78D4e0e',
  hook: '0x636c050296B5Cc528D8785169Bf8923716FCa9cc',
  locker: '0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab',
  escrow: '0x7559689765aE86cBB38e68CD1294830CccB125F2',
  mevLinearSkim: '0xb038D597365FfD108D63C265Bb0621444a1D8B83',
  deployerLib: '0x92584B320A8B871934A50b9D6f05833f6F82Cb81',
  skimInitLib: '0x115510a709d1AfD798325F3FFb74B127a08dD3C9',
  protocolFeeController: '0xd8C63401268744d430EbE0C18412211421498013',
  burnRouter: '0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca',
  feeSwapper: '0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961',
  liveBidAdapter: '0x8C72FBc2bB32e76aa54243F76745266a0F92CD01',
  protocolFeePhaseAdapter: '0xed3E9D3Bf693372060b7ce62aDB49650145b2ba9',
  tokenAdminPoker: '0xA96a11257890ED1C43C16c098E286e18e45E6258',
  payout: '0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4',
  poolExtensionAllowlist: '0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8',
} as const satisfies Record<string, Address>;

/** addresses by stack id, for the stacks with a table here */
export const STACK_ADDRESSES = { current: CURRENT } as const;

/** addresses of the stack whose registry status is current */
export const ACTIVE = STACK_ADDRESSES.current;

/** external infra (not in the registry) */
export const INFRA = {
  poolManager: '0x000000000004444c5dc75cB358380D2e3dE08A90',
  positionManager: '0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e',
  permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
  weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  universalRouter: '0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af',
  stateView: '0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227',
  create2Deployer: '0x4e59b44847b379578588920cA78FbF26c0B4956C',
  scriptyBuilder: '0xD7587F110E08F4D120A231bA97d3B577A81Df022',
  scriptyStorage: '0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699',
} as const satisfies Record<string, Address>;

export interface RegistryCoin {
  symbol: string;
  name: string;
  address: Address;
  stack: StackId;
  factory: Address;
  launchBlock: bigint;
}

export const COINS: RegistryCoin[] = [
  {
    symbol: 'LAYER',
    name: 'Liquidity Layer',
    address: '0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9',
    stack: 'legacy',
    factory: '0xD1595A2742C392d1c109b616b4F08918D02292f9',
    launchBlock: 25045152n,
  },
  {
    symbol: '111',
    name: 'permanent collection',
    address: '0x61C9d89fe1212F6b55fF888816A151463287B8ae',
    stack: 'current',
    factory: '0x49596c375c139E79bb937bcf826068a8F78D4e0e',
    launchBlock: 25275351n,
  },
];

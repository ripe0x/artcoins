// Decodes a Universal Router execute() the ui sent, down to the v4 swap's hookData.
import { decodeAbiParameters, decodeFunctionData, type Address, type Hex } from 'viem';
import { universalRouterAbi } from '../src/lib/abi';

const POOL_SWAP_DATA = [
  { type: 'tuple', components: [{ name: 'mevModuleSwapData', type: 'bytes' }, { name: 'poolExtensionSwapData', type: 'bytes' }] },
] as const;
const PC_SWAP_DATA = [
  {
    type: 'tuple',
    components: [
      {
        name: 'attribution',
        type: 'tuple',
        components: [
          { name: 'sourceId', type: 'bytes32' },
          { name: 'referrer', type: 'address' },
          { name: 'campaignId', type: 'bytes16' },
          { name: 'referralBps', type: 'uint24' },
        ],
      },
      { name: 'extensionPayload', type: 'bytes' },
    ],
  },
] as const;
const EXACT_IN_SINGLE = [
  {
    type: 'tuple',
    components: [
      {
        name: 'poolKey',
        type: 'tuple',
        components: [
          { name: 'currency0', type: 'address' },
          { name: 'currency1', type: 'address' },
          { name: 'fee', type: 'uint24' },
          { name: 'tickSpacing', type: 'int24' },
          { name: 'hooks', type: 'address' },
        ],
      },
      { name: 'zeroForOne', type: 'bool' },
      { name: 'amountIn', type: 'uint128' },
      { name: 'amountOutMinimum', type: 'uint128' },
      { name: 'hookData', type: 'bytes' },
    ],
  },
] as const;

export interface DecodedSwap {
  commands: Hex;
  actions: Hex;
  deadline: bigint;
  zeroForOne: boolean;
  amountIn: bigint;
  amountOutMinimum: bigint;
  hooks: Address;
  hookData: Hex;
  /** abi.decode(mevModuleSwapData, (address)) when it is exactly 32 bytes, the v2 refund address */
  refundTo: Address | null;
  referrer: Address | null;
  referralBps: number | null;
}

export function decodeRouterSwap(data: Hex): DecodedSwap {
  const { functionName, args } = decodeFunctionData({ abi: universalRouterAbi, data });
  if (functionName !== 'execute') throw new Error(`not execute: ${functionName}`);
  const [commands, inputs, deadline] = args as unknown as [Hex, Hex[], bigint];
  // the V4_SWAP (0x10) input is the one carrying (bytes actions, bytes[] params)
  const cmds = commands.slice(2).match(/../g)!.map((b) => parseInt(b, 16) & 0x3f);
  const i = cmds.indexOf(0x10);
  if (i < 0) throw new Error('no V4_SWAP command');
  const [actions, params] = decodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], inputs[i]);
  const [swap] = decodeAbiParameters(EXACT_IN_SINGLE, params[0]);
  let refundTo: Address | null = null;
  let referrer: Address | null = null;
  let referralBps: number | null = null;
  if (swap.hookData !== '0x') {
    const [psd] = decodeAbiParameters(POOL_SWAP_DATA, swap.hookData);
    if ((psd.mevModuleSwapData.length - 2) / 2 === 32) [refundTo] = decodeAbiParameters([{ type: 'address' }], psd.mevModuleSwapData);
    if (psd.poolExtensionSwapData !== '0x') {
      const [pc] = decodeAbiParameters(PC_SWAP_DATA, psd.poolExtensionSwapData);
      referrer = pc.attribution.referrer;
      referralBps = pc.attribution.referralBps;
    }
  }
  return {
    commands,
    actions,
    deadline,
    zeroForOne: swap.zeroForOne,
    amountIn: swap.amountIn,
    amountOutMinimum: swap.amountOutMinimum,
    hooks: swap.poolKey.hooks,
    hookData: swap.hookData,
    refundTo,
    referrer,
    referralBps,
  };
}

import {
  encodeAbiParameters,
  type Address,
  type Hex,
} from 'viem';
import type { PoolKey } from './pool';

// Universal Router commands
const CMD_V4_SWAP = 0x10;
const CMD_WRAP_ETH = 0x0b;
const CMD_UNWRAP_WETH = 0x0c;

// V4 router actions
const ACT_SWAP_EXACT_IN_SINGLE = 0x06;
const ACT_SETTLE = 0x0b;     // (Currency, uint256, bool payerIsUser)
const ACT_SETTLE_ALL = 0x0c; // (Currency, uint256 maxAmount)  — payer is always msg.sender
const ACT_TAKE_ALL = 0x0f;

/** Zero address — used as the "currency" sentinel meaning ETH for the router */
const ETH_ADDRESS: Address = '0x0000000000000000000000000000000000000000';

/** Universal Router constants for `amount` fields */
const CONTRACT_BALANCE: bigint = 1n << 255n; // sentinel: "use full balance on router"

function packBytes1(values: number[]): Hex {
  const hex = values.map(v => v.toString(16).padStart(2, '0')).join('');
  return `0x${hex}` as Hex;
}

const poolKeyComponents = [
  { name: 'currency0', type: 'address' },
  { name: 'currency1', type: 'address' },
  { name: 'fee', type: 'uint24' },
  { name: 'tickSpacing', type: 'int24' },
  { name: 'hooks', type: 'address' },
] as const;

const exactInputSingleComponents = [
  { name: 'poolKey', type: 'tuple', components: poolKeyComponents },
  { name: 'zeroForOne', type: 'bool' },
  { name: 'amountIn', type: 'uint128' },
  { name: 'amountOutMinimum', type: 'uint128' },
  { name: 'hookData', type: 'bytes' },
] as const;

/**
 * Encode V4 SWAP_EXACT_IN_SINGLE + SETTLE/SETTLE_ALL + TAKE_ALL.
 *
 * @param payerIsUser
 *   - `true` → SETTLE_ALL: pulls input token from the user (msg.sender) via Permit2.
 *              Used for SELL (user's token → WETH).
 *   - `false` → SETTLE: pays from the router's own balance (address(this)).
 *              Used for BUY (ETH was already wrapped to WETH on the router via WRAP_ETH).
 */
function encodeV4SwapInput(params: {
  poolKey: PoolKey;
  zeroForOne: boolean;
  amountIn: bigint;
  amountOutMinimum: bigint;
  hookData: Hex;
  inputToken: Address;
  outputToken: Address;
  payerIsUser: boolean;
}): Hex {
  const settleAction = params.payerIsUser ? ACT_SETTLE_ALL : ACT_SETTLE;

  const actions = packBytes1([
    ACT_SWAP_EXACT_IN_SINGLE,
    settleAction,
    ACT_TAKE_ALL,
  ]);

  // Encode ExactInputSingleParams as a single dynamic tuple — matching abi.encode(struct).
  // Because the struct contains a dynamic field (bytes hookData), abi.encode(struct) wraps
  // the data with a leading offset word (0x20). The V4Router's CalldataDecoder dereferences
  // this offset in assembly: `swapParams := add(params.offset, calldataload(params.offset))`.
  // Passing the fields as flat top-level params would omit the offset, causing a revert.
  const swapParams = encodeAbiParameters(
    [{ type: 'tuple', components: exactInputSingleComponents }],
    [
      {
        poolKey: {
          currency0: params.poolKey.currency0,
          currency1: params.poolKey.currency1,
          fee: params.poolKey.fee,
          tickSpacing: params.poolKey.tickSpacing,
          hooks: params.poolKey.hooks,
        },
        zeroForOne: params.zeroForOne,
        amountIn: params.amountIn,
        amountOutMinimum: params.amountOutMinimum,
        hookData: params.hookData,
      },
    ]
  );

  // SETTLE_ALL: (Currency, uint256 maxAmount)
  // SETTLE:     (Currency, uint256 amount, bool payerIsUser)
  const settleParams = params.payerIsUser
    ? encodeAbiParameters(
        [{ type: 'address' }, { type: 'uint256' }],
        [params.inputToken, params.amountIn]
      )
    : encodeAbiParameters(
        [{ type: 'address' }, { type: 'uint256' }, { type: 'bool' }],
        [params.inputToken, params.amountIn, false]
      );

  const takeParams = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }],
    [params.outputToken, params.amountOutMinimum]
  );

  return encodeAbiParameters(
    [{ type: 'bytes' }, { type: 'bytes[]' }],
    [actions, [swapParams, settleParams, takeParams]]
  );
}

export interface BuildBuyArgs {
  poolKey: PoolKey;
  /** Is the artcoin token0? (derived from the hook) */
  artCoinIsToken0: boolean;
  /** WETH address (paired token) */
  weth: Address;
  /** Token being bought (the artcoin) */
  token: Address;
  /** Amount of ETH being spent */
  ethAmount: bigint;
  /** Minimum amount of token to receive (slippage-protected) */
  minTokenOut: bigint;
  /** Hook data — usually `0x` */
  hookData?: Hex;
}

/**
 * Build Universal Router inputs for a buy (ETH → Token).
 * Flow: WRAP_ETH → V4_SWAP (WETH → Token)
 * ETH is sent as msg.value and wrapped by the router.
 */
export function buildBuyCalldata(args: BuildBuyArgs): {
  commands: Hex;
  inputs: Hex[];
  value: bigint;
} {
  const hookData: Hex = args.hookData ?? '0x';

  const commands = packBytes1([CMD_WRAP_ETH, CMD_V4_SWAP]);

  // WRAP_ETH: (recipient, amount) — recipient = router (address(2) = ADDRESS_THIS), amount = contract balance
  const wrapInput = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }],
    ['0x0000000000000000000000000000000000000002', CONTRACT_BALANCE]
  );

  // V4 swap: zeroForOne = true if paying token0 (WETH) for token1 (artcoin), false otherwise
  // We're selling WETH → artcoin. So zeroForOne is true iff WETH is token0.
  const wethIsToken0 = !args.artCoinIsToken0;
  const zeroForOne = wethIsToken0;

  const v4Input = encodeV4SwapInput({
    poolKey: args.poolKey,
    zeroForOne,
    amountIn: args.ethAmount,
    amountOutMinimum: args.minTokenOut,
    hookData,
    inputToken: args.weth,
    outputToken: args.token,
    payerIsUser: false, // router pays from its own WETH (wrapped via WRAP_ETH)
  });

  return {
    commands,
    inputs: [wrapInput, v4Input],
    value: args.ethAmount,
  };
}

export interface BuildSellArgs {
  poolKey: PoolKey;
  artCoinIsToken0: boolean;
  weth: Address;
  token: Address;
  /** Amount of token being sold */
  tokenAmount: bigint;
  /** Minimum amount of ETH to receive */
  minEthOut: bigint;
  /** Recipient of the ETH */
  recipient: Address;
  hookData?: Hex;
}

/**
 * Build Universal Router inputs for a sell (Token → ETH).
 * Flow: V4_SWAP (Token → WETH) → UNWRAP_WETH (to recipient)
 * User must have approved Token → Permit2 and Permit2 → UniversalRouter beforehand.
 */
export function buildSellCalldata(args: BuildSellArgs): {
  commands: Hex;
  inputs: Hex[];
  value: bigint;
} {
  const hookData: Hex = args.hookData ?? '0x';

  const commands = packBytes1([CMD_V4_SWAP, CMD_UNWRAP_WETH]);

  // Selling the artcoin for WETH. zeroForOne true iff the artcoin is token0.
  const zeroForOne = args.artCoinIsToken0;

  const v4Input = encodeV4SwapInput({
    poolKey: args.poolKey,
    zeroForOne,
    amountIn: args.tokenAmount,
    amountOutMinimum: args.minEthOut,
    hookData,
    inputToken: args.token,
    outputToken: args.weth,
    payerIsUser: true, // user pays via Permit2 (token approved beforehand)
  });

  // UNWRAP_WETH: (recipient, amountMin)
  const unwrapInput = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }],
    [args.recipient, args.minEthOut]
  );

  return {
    commands,
    inputs: [v4Input, unwrapInput],
    value: 0n,
  };
}

/** Apply slippage tolerance (in basis points) to an expected amount. */
export function applySlippage(expected: bigint, slippageBps: number): bigint {
  if (slippageBps <= 0) return expected;
  const denominator = 10_000n;
  const bpsLeft = denominator - BigInt(slippageBps);
  return (expected * bpsLeft) / denominator;
}

/** Max uint160 — used for "infinite" Permit2 allowance. */
export const MAX_UINT160 = (1n << 160n) - 1n;
/** Max uint256 — used for "infinite" ERC20 allowance to Permit2. */
export const MAX_UINT256 = (1n << 256n) - 1n;

export { ETH_ADDRESS };

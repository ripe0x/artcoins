// Hand written abis for contracts this repo does not compile (Uniswap, permit2, erc20, ReferralPayout and
// the v1 airdrop). Everything artcoins owns is generated: lib/abi/v1/* and lib/abi/v2/*, see
// scripts/gen-abis.mjs. UI-03 / UI-07 / UI-24 came from hand copies drifting from the contracts.

// ─── Uniswap V4 StateView ─────────────────────────────────────────
export const stateViewAbi = [
  {
    type: 'function',
    name: 'getSlot0',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [
      { name: 'sqrtPriceX96', type: 'uint160' },
      { name: 'tick', type: 'int24' },
      { name: 'protocolFee', type: 'uint24' },
      { name: 'lpFee', type: 'uint24' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getLiquidity',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ name: 'liquidity', type: 'uint128' }],
    stateMutability: 'view',
  },
] as const;

// ─── Standard ERC20 (balance, allowance, approve) ─────────────────
export const erc20Abi = [
  { type: 'function', name: 'balanceOf', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  { type: 'function', name: 'allowance', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  { type: 'function', name: 'approve', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }], stateMutability: 'nonpayable' },
  { type: 'function', name: 'decimals', inputs: [], outputs: [{ type: 'uint8' }], stateMutability: 'view' },
] as const;

// ─── Permit2 (allowance + approve) ────────────────────────────────
export const permit2Abi = [
  {
    type: 'function',
    name: 'allowance',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'token', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [
      { name: 'amount', type: 'uint160' },
      { name: 'expiration', type: 'uint48' },
      { name: 'nonce', type: 'uint48' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'approve',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint160' },
      { name: 'expiration', type: 'uint48' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const;

// ─── Universal Router — execute entry point ───────────────────────
export const universalRouterAbi = [
  {
    type: 'function',
    name: 'execute',
    inputs: [
      { name: 'commands', type: 'bytes' },
      { name: 'inputs', type: 'bytes[]' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [],
    stateMutability: 'payable',
  },
] as const;

// ─── Uniswap V4 Quoter ────────────────────────────────────────────
const quoteExactSingleParamsTuple = {
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
    { name: 'exactAmount', type: 'uint128' },
    { name: 'hookData', type: 'bytes' },
  ],
} as const;

export const quoterAbi = [
  {
    type: 'function',
    name: 'quoteExactInputSingle',
    inputs: [quoteExactSingleParamsTuple],
    outputs: [
      { name: 'amountOut', type: 'uint256' },
      { name: 'gasEstimate', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
] as const;

// ─── ArtCoinsAirdrop (v1) ─────────────────────────────────────────
export const airdropAbi = [
  {
    type: 'function',
    name: 'airdrops',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [
      { name: 'admin', type: 'address' },
      { name: 'merkleRoot', type: 'bytes32' },
      { name: 'totalSupply', type: 'uint256' },
      { name: 'totalClaimed', type: 'uint256' },
      { name: 'lockupEndTime', type: 'uint256' },
      { name: 'vestingEndTime', type: 'uint256' },
      { name: 'adminClaimTime', type: 'uint256' },
      { name: 'adminClaimed', type: 'bool' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'amountAvailableToClaim',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'recipient', type: 'address' },
      { name: 'allocatedAmount', type: 'uint256' },
    ],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'claim',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'recipient', type: 'address' },
      { name: 'allocatedAmount', type: 'uint256' },
      { name: 'proof', type: 'bytes32[]' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  { type: 'error', name: 'AirdropNotCreated', inputs: [] },
  { type: 'error', name: 'AirdropNotUnlocked', inputs: [] },
  { type: 'error', name: 'InvalidProof', inputs: [] },
  { type: 'error', name: 'ZeroClaim', inputs: [] },
  { type: 'error', name: 'ZeroToClaim', inputs: [] },
  { type: 'error', name: 'UserMaxClaimed', inputs: [] },
  { type: 'error', name: 'TotalMaxClaimed', inputs: [] },
  { type: 'error', name: 'AdminClaimed', inputs: [] },
] as const;

// ─── ReferralPayout ─────────────────────────────────────────────────
// Per-pool ledger that holds `balances[referrer]` for any referrer
// that's been credited by the hook. `notify` is hook-only (omitted —
// frontend never calls it directly). Anyone can claim on a referrer's
// behalf via `claimFor`; funds always go to the referrer's address,
// regardless of caller. Stray ETH via `receive()` is accepted but NOT
// credited to any referrer.
export const referralPayoutAbi = [
  { type: 'function', name: 'balances', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  { type: 'function', name: 'claim', inputs: [], outputs: [], stateMutability: 'nonpayable' },
  { type: 'function', name: 'claimFor', inputs: [{ name: 'referrer', type: 'address' }], outputs: [], stateMutability: 'nonpayable' },
  // Events (for future indexer integration; not consumed by the page today).
  { type: 'event', name: 'ReferralCredited', inputs: [{ name: 'referrer', type: 'address', indexed: true }, { name: 'amount', type: 'uint256', indexed: false }] },
  { type: 'event', name: 'ReferralClaimed', inputs: [{ name: 'referrer', type: 'address', indexed: true }, { name: 'amount', type: 'uint256', indexed: false }] },
  // Errors surfaced from claim attempts (best-effort decode in the UI).
  { type: 'error', name: 'TransferFailed', inputs: [{ type: 'address' }, { type: 'uint256' }] },
  { type: 'error', name: 'NothingToClaim', inputs: [] },
] as const;

export const factoryAbi = [
  {
    type: 'function',
    name: 'deployToken',
    inputs: [{
      name: 'deploymentConfig',
      type: 'tuple',
      components: [
        { name: 'tokenConfig', type: 'tuple', components: [
          { name: 'tokenAdmin', type: 'address' },
          { name: 'name', type: 'string' },
          { name: 'symbol', type: 'string' },
          { name: 'salt', type: 'bytes32' },
          { name: 'image', type: 'string' },
          { name: 'metadata', type: 'string' },
          { name: 'context', type: 'string' },
          { name: 'totalSupply', type: 'uint256' },
        ]},
        { name: 'poolConfig', type: 'tuple', components: [
          { name: 'hook', type: 'address' },
          { name: 'pairedToken', type: 'address' },
          { name: 'tickIfToken0IsNewMaterial', type: 'int24' },
          { name: 'tickSpacing', type: 'int24' },
          { name: 'poolData', type: 'bytes' },
        ]},
        { name: 'lockerConfig', type: 'tuple', components: [
          { name: 'locker', type: 'address' },
          { name: 'rewardAdmins', type: 'address[]' },
          { name: 'rewardRecipients', type: 'address[]' },
          { name: 'rewardBps', type: 'uint16[]' },
          { name: 'tickLower', type: 'int24[]' },
          { name: 'tickUpper', type: 'int24[]' },
          { name: 'positionBps', type: 'uint16[]' },
          { name: 'lockerData', type: 'bytes' },
        ]},
        { name: 'mevModuleConfig', type: 'tuple', components: [
          { name: 'mevModule', type: 'address' },
          { name: 'mevModuleData', type: 'bytes' },
        ]},
        { name: 'extensionConfigs', type: 'tuple[]', components: [
          { name: 'extension', type: 'address' },
          { name: 'msgValue', type: 'uint256' },
          { name: 'extensionBps', type: 'uint16' },
          { name: 'extensionData', type: 'bytes' },
        ]},
      ]
    }],
    outputs: [{ name: 'tokenAddress', type: 'address' }],
    stateMutability: 'payable',
  },
  {
    type: 'function',
    name: 'tokenDeploymentInfo',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [{
      type: 'tuple',
      components: [
        { name: 'token', type: 'address' },
        { name: 'hook', type: 'address' },
        { name: 'locker', type: 'address' },
        { name: 'extensions', type: 'address[]' },
      ],
    }],
    stateMutability: 'view',
  },
  {
    type: 'event',
    name: 'TokenCreated',
    inputs: [
      { name: 'msgSender', type: 'address', indexed: false },
      { name: 'tokenAddress', type: 'address', indexed: true },
      { name: 'tokenAdmin', type: 'address', indexed: true },
      { name: 'tokenImage', type: 'string', indexed: false },
      { name: 'tokenName', type: 'string', indexed: false },
      { name: 'tokenSymbol', type: 'string', indexed: false },
      { name: 'tokenMetadata', type: 'string', indexed: false },
      { name: 'tokenContext', type: 'string', indexed: false },
      { name: 'startingTick', type: 'int24', indexed: false },
      { name: 'poolHook', type: 'address', indexed: false },
      { name: 'poolId', type: 'bytes32', indexed: false },
      { name: 'pairedToken', type: 'address', indexed: false },
      { name: 'locker', type: 'address', indexed: false },
      { name: 'mevModule', type: 'address', indexed: false },
      { name: 'extensionsSupply', type: 'uint256', indexed: false },
      { name: 'extensions', type: 'address[]', indexed: false },
    ],
  },
] as const;

// ─── NewMaterialToken (read-only subset) ──────────────────────────
export const tokenAbi = [
  { type: 'function', name: 'name', inputs: [], outputs: [{ type: 'string' }], stateMutability: 'view' },
  { type: 'function', name: 'symbol', inputs: [], outputs: [{ type: 'string' }], stateMutability: 'view' },
  { type: 'function', name: 'totalSupply', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  { type: 'function', name: 'admin', inputs: [], outputs: [{ type: 'address' }], stateMutability: 'view' },
  { type: 'function', name: 'originalAdmin', inputs: [], outputs: [{ type: 'address' }], stateMutability: 'view' },
  { type: 'function', name: 'imageUrl', inputs: [], outputs: [{ type: 'string' }], stateMutability: 'view' },
  { type: 'function', name: 'metadata', inputs: [], outputs: [{ type: 'string' }], stateMutability: 'view' },
  { type: 'function', name: 'context', inputs: [], outputs: [{ type: 'string' }], stateMutability: 'view' },
  { type: 'function', name: 'contractURI', inputs: [], outputs: [{ type: 'string' }], stateMutability: 'view' },
  { type: 'function', name: 'tokenURI', inputs: [], outputs: [{ type: 'string' }], stateMutability: 'view' },
  { type: 'function', name: 'metadataRenderer', inputs: [], outputs: [{ type: 'address' }], stateMutability: 'view' },
  { type: 'function', name: 'isVerified', inputs: [], outputs: [{ type: 'bool' }], stateMutability: 'view' },
] as const;

// PoolKey tuple shared by V4 calls (hookAbi + mevLinearAbi).
const poolKeyTuple = {
  type: 'tuple',
  components: [
    { name: 'currency0', type: 'address' },
    { name: 'currency1', type: 'address' },
    { name: 'fee', type: 'uint24' },
    { name: 'tickSpacing', type: 'int24' },
    { name: 'hooks', type: 'address' },
  ],
} as const;

// ─── NewMaterialHookV2 / StaticFeeV2 (read-only subset) ───────────
export const hookAbi = [
  { type: 'function', name: 'newMaterialIsToken0', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'bool' }], stateMutability: 'view' },
  { type: 'function', name: 'locker', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'address' }], stateMutability: 'view' },
  { type: 'function', name: 'mevModule', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'address' }], stateMutability: 'view' },
  { type: 'function', name: 'mevModuleEnabled', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'bool' }], stateMutability: 'view' },
  { type: 'function', name: 'poolCreationTimestamp', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  { type: 'function', name: 'newMaterialFee', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'uint24' }], stateMutability: 'view' },
  { type: 'function', name: 'pairedFee', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'uint24' }], stateMutability: 'view' },
  { type: 'function', name: 'protocolFeeNumerator', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  // Per-pool skim config; the `referralPayout` field tells us which
  // ReferralPayout instance holds balances for this pool.
  {
    type: 'function',
    name: 'skimConfig',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [
      { name: 'baselineSkimBps', type: 'uint24' },
      { name: 'bountyBps', type: 'uint16' },
      { name: 'maxReferralBpsOfVolume', type: 'uint24' },
      { name: 'lpFee', type: 'uint24' },
      { name: 'bountyRecipient', type: 'address' },
      { name: 'protocolRecipient', type: 'address' },
      { name: 'referralPayout', type: 'address' },
      { name: 'permanentCollection', type: 'address' },
      { name: 'quoteToken', type: 'address' },
    ],
    stateMutability: 'view',
  },
  // Per-swap accrual within the current tx (rarely non-zero between
  // swaps; useful only when a forward to ReferralPayout previously failed).
  {
    type: 'function',
    name: 'accruedReferral',
    inputs: [{ type: 'bytes32' }, { type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  // Held amount: a previously-flushed referral that couldn't be forwarded
  // (e.g. recipient reverted). Drainable via `flushReferral` / `retryHeldReferral`.
  {
    type: 'function',
    name: 'heldReferral',
    inputs: [{ type: 'bytes32' }, { type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  // Escape hatch: drain any held + freshly-accrued referral for a referrer
  // to ReferralPayout. In normal swap traffic this is automatic in
  // `_afterSwap` and never needs to be called externally.
  {
    type: 'function',
    name: 'flushReferral',
    inputs: [poolKeyTuple, { name: 'referrer', type: 'address' }],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const;

// ─── NewMaterialMevLinearFees (read-only subset) ─────────────────
export const mevLinearAbi = [
  { type: 'function', name: 'getCurrentFee', inputs: [poolKeyTuple], outputs: [{ type: 'uint24' }], stateMutability: 'view' },
  { type: 'function', name: 'getTimeRemaining', inputs: [poolKeyTuple], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  {
    type: 'function',
    name: 'feeConfigs',
    inputs: [{ type: 'bytes32' }],
    outputs: [
      { name: 'startingFee', type: 'uint24' },
      { name: 'endingFee', type: 'uint24' },
      { name: 'duration', type: 'uint32' },
      { name: 'startTime', type: 'uint256' },
    ],
    stateMutability: 'view',
  },
] as const;

// ─── NewMaterialLpLockerMultiple (read-only subset) ───────────────
export const lockerAbi = [
  {
    type: 'function',
    name: 'tokenRewards',
    inputs: [{ type: 'address' }],
    outputs: [{
      type: 'tuple',
      components: [
        { name: 'rewardAdmins', type: 'address[]' },
        { name: 'rewardRecipients', type: 'address[]' },
        { name: 'rewardBps', type: 'uint16[]' },
        { name: 'tickLower', type: 'int24[]' },
        { name: 'tickUpper', type: 'int24[]' },
        { name: 'positionBps', type: 'uint16[]' },
      ],
    }],
    stateMutability: 'view',
  },
] as const;

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

// ─── NewMaterialAirdropV2 ─────────────────────────────────────────
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

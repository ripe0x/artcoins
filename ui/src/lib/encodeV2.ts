// Builds the `DeploymentConfigV2` the v2 factory takes (src/v2/interfaces/IArtCoinsFactoryV2.sol).
// Units follow the contracts:
//   lpFeePips                  pips, 1_000_000 = 100% (Constants.FEE_DENOMINATOR), max 100_000
//   baselineSkimBps, start skim, maxReferralBpsOfVolume, bountyBps, rewardBps, positionBps, extensionBps
//                              Constants.BPS = 10_000 = 100%
//   ticks                      token0 frame (coin as currency0). The coin is always currency1 against
//                              native eth, the contracts mirror them: pool tick = -tick
// The v1 encoder (encode.ts) stays only for the legacy event reader and the deploy fee tooling.
import {
  encodeAbiParameters,
  getAddress,
  isAddress,
  parseEther,
  type Address,
  type Hex,
} from 'viem';
import {
  BPS,
  EXTENSION_MAX_DURATION_DAYS,
  FEE_DENOMINATOR,
  MAX_BASELINE_SKIM_BPS,
  MAX_BOUNTY_BPS,
  MAX_EXTENSION_BPS,
  MAX_ALLOWED,
  MAX_EXTENSIONS,
  MAX_LP_FEE,
  MAX_LP_POSITIONS,
  MAX_MEV_WINDOW,
  MAX_PROTOCOL_FEE_BPS,
  MAX_REFERRAL_CAP_OF_VOLUME,
  MAX_REWARD_PARTICIPANTS,
  MAX_SKIM_BPS,
  MAX_TICK,
  MIN_MEV_WINDOW,
  MIN_TICK,
  MIN_TOKEN_SUPPLY,
  SECONDS_PER_DAY,
  VAULT_MIN_LOCKUP_DAYS,
  VAULT_MIN_VESTING_DAYS,
  ZERO_ADDRESS,
} from './constants';
import type { LaunchForm } from './types';
import {
  maxReferralCapBps,
  parseAllowedInput,
  referralCapWithinFloor,
  seededAllowedCount,
  stringCapIssue,
} from './launchRules';

// ── config types, field for field the interface structs ─────────────────────────────────────────

export interface TokenConfigV2 {
  tokenAdmin: Address;
  name: string;
  symbol: string;
  salt: Hex;
  image: string;
  description: string;
  totalSupply: bigint;
  renderer: Address;
}
export interface PoolConfigV2 {
  hook: Address;
  tickIfToken0IsCoin: number;
  tickSpacing: number;
  extension: Address;
  extensionData: Hex;
}
export interface FeeConfigV2 {
  lpFeePips: number;
  baselineSkimBps: number;
  bountyBps: number;
  maxReferralBpsOfVolume: number;
  bountyRecipient: Address;
}
export interface LockerConfigV2 {
  locker: Address;
  rewardRecipients: Address[];
  rewardBps: number[];
  tickLower: number[];
  tickUpper: number[];
  positionBps: number[];
}
export interface MevConfigV2 {
  module: Address;
  startingSkimBps: number;
  windowSeconds: number;
}
export interface RestrictionConfigV2 {
  restricted: boolean;
  allowed: Address[];
}
export interface ExtensionConfigV2 {
  extension: Address;
  msgValue: bigint;
  extensionBps: number;
  extensionData: Hex;
}
export interface DeploymentConfigV2 {
  token: TokenConfigV2;
  pool: PoolConfigV2;
  fee: FeeConfigV2;
  locker: LockerConfigV2;
  mev: MevConfigV2;
  restriction: RestrictionConfigV2;
  extensions: ExtensionConfigV2[];
}

/** Everything chain side the builder needs. Read the numbers from the factory, never hardcode them. */
export interface LaunchContext {
  /** the sender, used for the "default to connected wallet" fields */
  sender: Address;
  hook: Address;
  locker: Address;
  /** zero when the stack has no anti sniper module */
  mevModule: Address;
  vault: Address;
  airdrop: Address;
  devBuy: Address;
  /** pool extension, 0 for none */
  poolExtension?: Address;
  /** factory.defaultProtocolFeeBps(), the protocol slot `deployToken` appends */
  protocolBps: number;
  /** factory.minProtocolSkimShareBps(), caps the bounty share */
  minProtocolSkimShareBps: number;
  /** factory.defaultAllowed().length: owner entries the factory seeds into every restricted launch */
  defaultAllowedCount: number;
  /** factory.deployFee() */
  deployFee: bigint;
  salt: Hex;
}

export interface Issue {
  severity: 'error' | 'warning';
  field: string;
  message: string;
}

export class LaunchConfigError extends Error {
  issues: Issue[];
  constructor(issues: Issue[]) {
    super(issues.filter((i) => i.severity === 'error').map((i) => `${i.field}: ${i.message}`).join('; '));
    this.name = 'LaunchConfigError';
    this.issues = issues;
  }
}

// ── unit conversion ─────────────────────────────────────────────────────────────────────────────

/** percent of the swap amount to pips (1% = 10_000) */
export const percentToPips = (pct: number): number => Math.round(pct * (FEE_DENOMINATOR / 100));
/** percent to bps (1% = 100) */
export const percentToBps = (pct: number): number => Math.round(pct * (BPS / 100));
export const pipsToPercent = (pips: number): number => pips / (FEE_DENOMINATOR / 100);
export const bpsToPercent = (bps: number): number => bps / (BPS / 100);

/** whole coins (string) to wei, '' or 0 means 0 = the factory default supply. Exact, no float. */
export function supplyToWei(whole: string): bigint {
  const s = whole.trim();
  if (s === '') return 0n;
  if (!/^\d+$/.test(s)) throw new Error('supply must be a whole number of coins');
  return BigInt(s) * 10n ** 18n;
}

export function generateSalt(): Hex {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return `0x${Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')}` as Hex;
}

const isZeroAddr = (a: string): boolean => a.toLowerCase() === ZERO_ADDRESS;

/** returns the checksummed address, or null when the string is not a valid address (mixed case must checksum) */
export function parseAddress(raw: string): Address | null {
  const s = raw.trim();
  if (!isAddress(s, { strict: true })) return null;
  return getAddress(s);
}

// ── extension data (frozen layouts of the v2 extensions) ─────────────────────────────────────────

/** ArtCoinsVaultV2: abi.encode(beneficiary, lockupDuration, vestingDuration), seconds */
export function encodeVaultDataV2(beneficiary: Address, lockupDays: number, vestingDays: number): Hex {
  return encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }],
    [beneficiary, BigInt(Math.round(lockupDays * SECONDS_PER_DAY)), BigInt(Math.round(vestingDays * SECONDS_PER_DAY))]
  );
}

/** ArtCoinsAirdropV2: abi.encode(sweepRecipient, merkleRoot, lockupDuration, vestingDuration), seconds */
export function encodeAirdropDataV2(
  sweepRecipient: Address,
  merkleRoot: Hex,
  lockupDays: number,
  vestingDays: number
): Hex {
  return encodeAbiParameters(
    [{ type: 'address' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'uint256' }],
    [
      sweepRecipient,
      merkleRoot,
      BigInt(Math.round(lockupDays * SECONDS_PER_DAY)),
      BigInt(Math.round(vestingDays * SECONDS_PER_DAY)),
    ]
  );
}

/** ArtCoinsUniv4EthDevBuyV2: abi.encode(recipient, refundRecipient, uint128 minTokenOut), exactly 96 bytes */
export function encodeDevBuyDataV2(recipient: Address, refundRecipient: Address, minTokenOut: bigint): Hex {
  return encodeAbiParameters(
    [{ type: 'address' }, { type: 'address' }, { type: 'uint128' }],
    [recipient, refundRecipient, minTokenOut]
  );
}

/** MevConfigV2 -> the hook's module config: abi.encode(uint24 startingSkimBps, uint32 windowSeconds) */
export function encodeMevModuleConfig(startingSkimBps: number, windowSeconds: number): Hex {
  return encodeAbiParameters([{ type: 'uint24' }, { type: 'uint32' }], [startingSkimBps, windowSeconds]);
}

// ── validation ──────────────────────────────────────────────────────────────────────────────────

const err = (field: string, message: string): Issue => ({ severity: 'error', field, message });

const AMOUNT_RE = /^\d+(\.\d{1,18})?$/;

/** project side reward bps the factory requires: 10_000 minus the protocol slot */
export function projectSideBps(protocolBps: number): number {
  return BPS - protocolBps;
}

/** max bounty share the factory accepts: min(BPS - minProtocolSkimShareBps, MAX_BOUNTY_BPS) */
export function maxBountyBps(minProtocolSkimShareBps: number): number {
  return Math.min(BPS - minProtocolSkimShareBps, MAX_BOUNTY_BPS);
}

/** Mirrors the factory, locker, hook and token checks so a bad config fails here with a readable reason. */
export function validateLaunch(form: LaunchForm, ctx: LaunchContext): Issue[] {
  const out: Issue[] = [];
  const { token, pool, mev, restriction, rewards, extensions } = form;

  // token
  if (!token.name.trim()) out.push(err('token.name', 'name is required'));
  if (!token.symbol.trim()) out.push(err('token.symbol', 'symbol is required'));
  // the factory and the token cap every string in utf8 bytes (D30). check what the builder sends
  for (const [field, value] of [
    ['name', token.name.trim()],
    ['symbol', token.symbol.trim()],
    ['image', token.image.trim()],
    ['description', token.description],
  ] as const) {
    const issue = stringCapIssue(field, value);
    if (issue) out.push(err(`token.${field}`, issue));
  }
  if (token.admin.trim() && !parseAddress(token.admin)) out.push(err('token.admin', 'not a valid address (check the checksum)'));
  if (token.renderer.trim()) {
    const r = parseAddress(token.renderer);
    if (!r || isZeroAddr(r)) out.push(err('token.renderer', 'renderer must be a valid nonzero address or empty'));
  }
  try {
    const supply = supplyToWei(token.totalSupply);
    if (supply !== 0n && supply < MIN_TOKEN_SUPPLY) out.push(err('token.totalSupply', 'supply below the minimum of 1 coin'));
  } catch (e) {
    out.push(err('token.totalSupply', (e as Error).message));
  }

  // pool
  const spacing = pool.tickSpacing;
  if (!Number.isInteger(spacing) || spacing <= 0) out.push(err('pool.tickSpacing', 'tick spacing must be a positive integer'));
  if (!Number.isInteger(pool.startingTick)) out.push(err('pool.startingTick', 'starting tick must be an integer'));
  else if (spacing > 0 && pool.startingTick % spacing !== 0) out.push(err('pool.startingTick', `starting tick must be a multiple of ${spacing}`));
  if (pool.startingTick < MIN_TICK || pool.startingTick > MAX_TICK) out.push(err('pool.startingTick', 'starting tick out of range'));

  // fees
  const lpFee = percentToPips(pool.lpFeePercent);
  const baseline = percentToBps(pool.baselineSkimPercent);
  const bounty = percentToBps(pool.bountyPercent);
  const refCap = percentToBps(pool.referralCapPercent);
  if (lpFee < 0 || lpFee > MAX_LP_FEE) out.push(err('pool.lpFee', `lp fee must be 0 to ${MAX_LP_FEE / 10_000}%`));
  if (lpFee === 0 && baseline === 0) out.push(err('pool.baselineSkim', 'set an lp fee or a baseline skim above 0, a pool with neither earns nothing'));
  if (baseline < 0 || baseline > MAX_BASELINE_SKIM_BPS) out.push(err('pool.baselineSkim', `baseline skim must be 0 to ${MAX_BASELINE_SKIM_BPS / 100}% of volume`));
  if (refCap < 0 || refCap > MAX_REFERRAL_CAP_OF_VOLUME) out.push(err('pool.referralCap', `referral cap must be 0 to ${MAX_REFERRAL_CAP_OF_VOLUME / 100}% of volume`));
  const maxBounty = maxBountyBps(ctx.minProtocolSkimShareBps);
  if (bounty < 0 || bounty > maxBounty) out.push(err('pool.bounty', `bounty share must be 0 to ${maxBounty / 100}% (the protocol keeps at least ${ctx.minProtocolSkimShareBps / 100}% of the skim)`));
  // referral cap: the referral leg is carved from the protocol leg and may not take it below the floor
  const bountyOk = bounty >= 0 && bounty <= maxBounty;
  if (bountyOk && refCap >= 0 && refCap <= MAX_REFERRAL_CAP_OF_VOLUME && baseline >= 0 && baseline <= MAX_BASELINE_SKIM_BPS) {
    if (!referralCapWithinFloor(refCap, baseline, bounty, ctx.minProtocolSkimShareBps)) {
      const capMax = maxReferralCapBps(baseline, bounty, ctx.minProtocolSkimShareBps);
      out.push(
        err(
          'pool.referralCap',
          `referral cap is above the maximum of ${capMax / 100}% of volume for these fees (baseline skim x (100% - bounty share - protocol floor of ${ctx.minProtocolSkimShareBps / 100}%)). Lower the cap, the bounty share, or raise the baseline skim`
        )
      );
    }
  }
  const bountyRecipient = pool.bountyRecipient.trim() ? parseAddress(pool.bountyRecipient) : ctx.sender;
  if (!bountyRecipient || isZeroAddr(bountyRecipient)) out.push(err('pool.bountyRecipient', 'bounty recipient must be a valid nonzero address'));

  // mev
  if (mev.enabled) {
    if (isZeroAddr(ctx.mevModule)) out.push(err('mev', 'no anti sniper module is configured for this stack, turn it off'));
    const secs = Math.round(mev.windowMin * 60);
    const start = percentToBps(mev.startPercent);
    if (secs < MIN_MEV_WINDOW || secs > MAX_MEV_WINDOW) out.push(err('mev.window', `window must be ${MIN_MEV_WINDOW / 60} to ${MAX_MEV_WINDOW / 60} minutes`));
    if (start > MAX_SKIM_BPS) out.push(err('mev.start', `starting skim must be at most ${MAX_SKIM_BPS / 100}% of volume`));
    if (start < baseline) out.push(err('mev.start', 'starting skim must be at least the baseline skim'));
  }

  // rewards
  const target = projectSideBps(ctx.protocolBps);
  const slots = rewards.recipients.length + (ctx.protocolBps === 0 ? 0 : 1);
  if (rewards.recipients.length === 0 && ctx.protocolBps === 0) out.push(err('rewards', 'at least one reward recipient is required'));
  if (slots > MAX_REWARD_PARTICIPANTS) out.push(err('rewards', `at most ${MAX_REWARD_PARTICIPANTS - (ctx.protocolBps === 0 ? 0 : 1)} project recipients (the protocol slot takes one of ${MAX_REWARD_PARTICIPANTS})`));
  let sum = 0;
  rewards.recipients.forEach((r, i) => {
    const a = parseAddress(r.recipient || ctx.sender);
    if (!a || isZeroAddr(a)) out.push(err(`rewards.${i}`, 'recipient must be a valid nonzero address'));
    if (!Number.isInteger(r.bps) || r.bps <= 0) out.push(err(`rewards.${i}`, 'share must be a positive whole number of bps'));
    sum += r.bps;
  });
  if (sum !== target) out.push(err('rewards.sum', `project shares must sum to ${target} bps (${target / 100}%), the protocol slot takes the other ${ctx.protocolBps / 100}%. now ${sum}`));
  if (ctx.protocolBps > MAX_PROTOCOL_FEE_BPS) out.push(err('rewards', 'factory protocol slot exceeds the allowed maximum'));

  // positions
  if (rewards.positions.length === 0 || rewards.positions.length > MAX_LP_POSITIONS) out.push(err('positions', `1 to ${MAX_LP_POSITIONS} positions`));
  let pSum = 0;
  rewards.positions.forEach((p, i) => {
    if (!(p.tickLower < p.tickUpper)) out.push(err(`positions.${i}`, 'upper tick must be above lower tick'));
    if (p.tickLower < MIN_TICK || p.tickUpper > MAX_TICK) out.push(err(`positions.${i}`, 'tick out of range'));
    if (spacing > 0 && (p.tickLower % spacing !== 0 || p.tickUpper % spacing !== 0)) out.push(err(`positions.${i}`, `ticks must be multiples of ${spacing}`));
    if (p.tickLower < pool.startingTick) out.push(err(`positions.${i}`, 'lower tick must be at least the starting tick (single sided liquidity)'));
    if (!Number.isInteger(p.bps) || p.bps <= 0) out.push(err(`positions.${i}`, 'share must be a positive whole number of bps'));
    pSum += p.bps;
  });
  if (pSum !== BPS) out.push(err('positions.sum', `position shares must sum to ${BPS} bps. now ${pSum}`));

  // extensions
  let extBps = 0;
  let extCount = 0;
  const v = extensions.vault;
  if (v.enabled) {
    extCount++;
    extBps += percentToBps(v.allocationPercent);
    if (isZeroAddr(ctx.vault)) out.push(err('vault', 'no vault extension is configured for this stack'));
    const b = parseAddress(v.beneficiary || ctx.sender);
    if (!b || isZeroAddr(b)) out.push(err('vault.beneficiary', 'beneficiary must be a valid nonzero address'));
    if (v.lockupDays < VAULT_MIN_LOCKUP_DAYS) out.push(err('vault.lockup', `lockup must be at least ${VAULT_MIN_LOCKUP_DAYS} days`));
    if (v.vestingDays < VAULT_MIN_VESTING_DAYS) out.push(err('vault.vesting', `vesting must be at least ${VAULT_MIN_VESTING_DAYS} days`));
    if (v.lockupDays > EXTENSION_MAX_DURATION_DAYS || v.vestingDays > EXTENSION_MAX_DURATION_DAYS) out.push(err('vault', `durations are capped at ${EXTENSION_MAX_DURATION_DAYS} days`));
  }
  const a = extensions.airdrop;
  if (a.enabled) {
    extCount++;
    extBps += percentToBps(a.allocationPercent);
    if (isZeroAddr(ctx.airdrop)) out.push(err('airdrop', 'no airdrop extension is configured for this stack'));
    const s = parseAddress(a.sweepRecipient || ctx.sender);
    if (!s || isZeroAddr(s)) out.push(err('airdrop.sweepRecipient', 'sweep recipient must be a valid nonzero address'));
    if (!/^0x[0-9a-fA-F]{64}$/.test(a.merkleRoot.trim()) || /^0x0{64}$/.test(a.merkleRoot.trim())) out.push(err('airdrop.merkleRoot', 'a nonzero 32 byte merkle root is required'));
    if (a.lockupDays > EXTENSION_MAX_DURATION_DAYS || a.vestingDays > EXTENSION_MAX_DURATION_DAYS) out.push(err('airdrop', `durations are capped at ${EXTENSION_MAX_DURATION_DAYS} days`));
  }
  const d = extensions.devBuy;
  if (d.enabled) {
    extCount++;
    if (isZeroAddr(ctx.devBuy)) out.push(err('devBuy', 'no dev buy extension is configured for this stack'));
    if (!AMOUNT_RE.test(d.ethAmount.trim()) || parseEther(d.ethAmount.trim() || '0') === 0n) out.push(err('devBuy.ethAmount', 'enter an eth amount above 0'));
    const r = parseAddress(d.recipient || ctx.sender);
    const f = parseAddress(d.refundRecipient || ctx.sender);
    if (!r || isZeroAddr(r)) out.push(err('devBuy.recipient', 'recipient must be a valid nonzero address'));
    if (!f || isZeroAddr(f)) out.push(err('devBuy.refundRecipient', 'refund recipient must be a valid nonzero address'));
    if (!/^\d+(\.\d{1,18})?$/.test(d.minTokenOut.trim()) || toWei18(d.minTokenOut) === 0n) out.push(err('devBuy.minTokenOut', 'a nonzero minimum coin out is required (a zero minimum can be sandwiched)'));
    else if (toWei18(d.minTokenOut) >= 1n << 128n) out.push(err('devBuy.minTokenOut', 'minimum coin out exceeds uint128'));
  }
  if (extCount > MAX_EXTENSIONS) out.push(err('extensions', `at most ${MAX_EXTENSIONS} extensions`));
  if (extBps > MAX_EXTENSION_BPS) out.push(err('extensions', `extension allocations total ${extBps / 100}%, the maximum is ${MAX_EXTENSION_BPS / 100}%`));

  // restriction (factory _validateRestriction and _restriction)
  const allowed = parseAllowedInput(restriction.allowed);
  if (!restriction.restricted) {
    if (allowed.length > 0) out.push(err('restriction.allowed', 'an unrestricted coin has no allowlist. Clear the list or turn on restrict transfers'));
  } else {
    const seeded = seededAllowedCount(ctx.defaultAllowedCount, extCount);
    if (seeded + allowed.length > MAX_ALLOWED) {
      out.push(err('restriction.allowed', `the allowlist holds at most ${MAX_ALLOWED} entries including ${seeded} added by the launcher (stack contracts, extensions, owner defaults), so at most ${Math.max(0, MAX_ALLOWED - seeded)} of your own`));
    }
    const seen = new Set<string>();
    for (const a of allowed) {
      const k = a.toLowerCase();
      if (!parseAddress(a) || isZeroAddr(a)) out.push(err('restriction.allowed', `${a} is not a valid nonzero address`));
      else if (seen.has(k)) out.push(err('restriction.allowed', `${a} is listed twice`));
      seen.add(k);
    }
  }

  return out;
}

function toWei18(s: string): bigint {
  try {
    return parseEther(s.trim() || '0');
  } catch {
    return 0n;
  }
}

// ── builder ─────────────────────────────────────────────────────────────────────────────────────

export interface BuiltLaunch {
  config: DeploymentConfigV2;
  /** msg.value to send: deployFee + sum of extension msgValue */
  value: bigint;
  extensionValue: bigint;
  issues: Issue[];
}

/** Throws `LaunchConfigError` when `validateLaunch` finds an error, so an invalid config is never encoded. */
export function buildLaunchConfigV2(form: LaunchForm, ctx: LaunchContext): BuiltLaunch {
  const issues = validateLaunch(form, ctx);
  if (issues.some((i) => i.severity === 'error')) throw new LaunchConfigError(issues);

  const { token, pool, mev, restriction, rewards, extensions } = form;
  const sender = ctx.sender;
  const admin = parseAddress(token.admin || sender)!;
  const bountyRecipient = parseAddress(pool.bountyRecipient || sender)!;

  const tokenConfig: TokenConfigV2 = {
    tokenAdmin: admin,
    name: token.name.trim(),
    symbol: token.symbol.trim(),
    salt: ctx.salt,
    image: token.image.trim(),
    description: token.description,
    totalSupply: supplyToWei(token.totalSupply),
    renderer: token.renderer.trim() ? parseAddress(token.renderer)! : ZERO_ADDRESS,
  };

  const poolConfig: PoolConfigV2 = {
    hook: ctx.hook,
    tickIfToken0IsCoin: pool.startingTick,
    tickSpacing: pool.tickSpacing,
    extension: ctx.poolExtension ?? ZERO_ADDRESS,
    extensionData: '0x',
  };

  const fee: FeeConfigV2 = {
    lpFeePips: percentToPips(pool.lpFeePercent),
    baselineSkimBps: percentToBps(pool.baselineSkimPercent),
    bountyBps: percentToBps(pool.bountyPercent),
    maxReferralBpsOfVolume: percentToBps(pool.referralCapPercent),
    bountyRecipient,
  };

  const locker: LockerConfigV2 = {
    locker: ctx.locker,
    rewardRecipients: rewards.recipients.map((r) => parseAddress(r.recipient || sender)!),
    rewardBps: rewards.recipients.map((r) => r.bps),
    tickLower: rewards.positions.map((p) => p.tickLower),
    tickUpper: rewards.positions.map((p) => p.tickUpper),
    positionBps: rewards.positions.map((p) => p.bps),
  };

  const mevConfig: MevConfigV2 = mev.enabled
    ? { module: ctx.mevModule, startingSkimBps: percentToBps(mev.startPercent), windowSeconds: Math.round(mev.windowMin * 60) }
    : { module: ZERO_ADDRESS, startingSkimBps: 0, windowSeconds: 0 };

  const restrictionConfig: RestrictionConfigV2 = restriction.restricted
    ? { restricted: true, allowed: parseAllowedInput(restriction.allowed).map((a) => parseAddress(a)!) }
    : { restricted: false, allowed: [] };

  const exts: ExtensionConfigV2[] = [];
  if (extensions.vault.enabled) {
    exts.push({
      extension: ctx.vault,
      msgValue: 0n,
      extensionBps: percentToBps(extensions.vault.allocationPercent),
      extensionData: encodeVaultDataV2(
        parseAddress(extensions.vault.beneficiary || sender)!,
        extensions.vault.lockupDays,
        extensions.vault.vestingDays
      ),
    });
  }
  if (extensions.airdrop.enabled) {
    exts.push({
      extension: ctx.airdrop,
      msgValue: 0n,
      extensionBps: percentToBps(extensions.airdrop.allocationPercent),
      extensionData: encodeAirdropDataV2(
        parseAddress(extensions.airdrop.sweepRecipient || sender)!,
        extensions.airdrop.merkleRoot.trim() as Hex,
        extensions.airdrop.lockupDays,
        extensions.airdrop.vestingDays
      ),
    });
  }
  if (extensions.devBuy.enabled) {
    const d = extensions.devBuy;
    exts.push({
      extension: ctx.devBuy,
      msgValue: parseEther(d.ethAmount.trim()),
      // the dev buy takes no supply, ArtCoinsUniv4EthDevBuyV2 reverts on any bps
      extensionBps: 0,
      extensionData: encodeDevBuyDataV2(
        parseAddress(d.recipient || sender)!,
        parseAddress(d.refundRecipient || sender)!,
        toWei18(d.minTokenOut)
      ),
    });
  }

  const extensionValue = exts.reduce((s, e) => s + e.msgValue, 0n);
  return {
    config: {
      token: tokenConfig,
      pool: poolConfig,
      fee,
      locker,
      mev: mevConfig,
      restriction: restrictionConfig,
      extensions: exts,
    },
    value: ctx.deployFee + extensionValue,
    extensionValue,
    issues,
  };
}

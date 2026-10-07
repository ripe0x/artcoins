import type { Address } from 'viem';
import { COINS, CURRENT } from '../src/lib/deployments.generated';

export const COIN_111 = COINS.find((c) => c.symbol === '111')!.address as Address;
export const LAYER = COINS.find((c) => c.symbol === 'LAYER')!.address as Address;
export const DEFAULT_REFERRER = CURRENT.payout as Address; // ui/public/config.json defaultReferrer
/** coin 111's referral ledger (hook skimConfig.referralPayout), registry name UnverifiedPcContract */
export const REFERRAL_PAYOUT_111: Address = '0xB03Cbd862F47059e928C113182814c676eA29d4c';
export const LEGACY_LOCKER: Address = '0x75BE7E95745915fD0C1761B74F3f9650ad2d1118';

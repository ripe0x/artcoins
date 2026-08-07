import { useCallback, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAccount, useChainId } from 'wagmi';
import { useQueryClient } from '@tanstack/react-query';
import { parseEther, decodeEventLog, type Address, type TransactionReceipt } from 'viem';
import { factoryAbi } from '../lib/abi';
import { getAddresses } from '../lib/config';
import { useTxFlow } from '../lib/useTxFlow';
import {
  generateSalt,
  encodePoolData,
  encodeMevLinearData,
  encodeMevDescendingData,
  encodeVaultData,
  encodeAirdropData,
  percentToFeeUnits,
} from '../lib/encode';
import { validateDeploy } from '../lib/validate';
import type {
  TokenFormState,
  PoolFormState,
  MevFormState,
  RewardsFormState,
  ExtensionsFormState,
} from '../lib/types';

interface Props {
  tokenForm: TokenFormState;
  poolForm: PoolFormState;
  mevForm: MevFormState;
  rewardsForm: RewardsFormState;
  extensionsForm: ExtensionsFormState;
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex justify-between py-1.5 border-b border-zinc-800 last:border-0">
      <span className="text-sm text-zinc-500">{label}</span>
      <span className="text-sm text-white text-right max-w-[60%] break-all">{value}</span>
    </div>
  );
}

/**
 * Pure log-parsing helper: pulls the deployed token address out of a
 * `TokenCreated` event in a deploy-transaction receipt. Returns `null` if no
 * such event is found (e.g. the receipt is for an unrelated tx, or the ABI
 * doesn't match). No side effects — safe to call from render or from an
 * effect.
 */
function parseDeployedTokenFromReceipt(receipt: TransactionReceipt): string | null {
  for (const log of receipt.logs) {
    try {
      const decoded = decodeEventLog({
        abi: factoryAbi,
        data: log.data,
        topics: log.topics,
      });
      if (decoded.eventName === 'TokenCreated') {
        const args = decoded.args as { tokenAddress?: string };
        if (args.tokenAddress) {
          return args.tokenAddress;
        }
      }
    } catch {
      // not our event
    }
  }
  return null;
}

export default function ReviewAndDeploy({
  tokenForm,
  poolForm,
  mevForm,
  rewardsForm,
  extensionsForm,
}: Props) {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const addresses = getAddresses(chainId);
  const queryClient = useQueryClient();

  const [deployedToken, setDeployedToken] = useState<string | null>(null);

  // Parse the TokenCreated event out of the receipt, and invalidate the
  // tokens list cache so the new token shows up on /tokens without a manual
  // refresh — both driven from onConfirmed (an effect internal to
  // useTxFlow), never during render.
  const onConfirmed = useCallback(
    (receipt: TransactionReceipt) => {
      const tokenAddress = parseDeployedTokenFromReceipt(receipt);
      if (tokenAddress) {
        setDeployedToken(tokenAddress);
        queryClient.invalidateQueries({ queryKey: ['tokens', chainId] });
      }
    },
    [chainId, queryClient]
  );

  const { submit, hash: txHash, status, error: writeError } = useTxFlow({ onConfirmed });
  const isPending = status === 'confirming';
  const isConfirming = status === 'pending';

  const etherscanBase = chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io';

  const handleDeploy = () => {
    if (!address) return;

    const admin = (tokenForm.admin || address) as Address;
    const salt = generateSalt();

    // Resolve paired token address
    const pairedToken: Address =
      poolForm.pairedToken === 'weth'
        ? addresses.weth
        : (poolForm.customPairedToken as Address);

    // Pool data
    const poolData = encodePoolData(
      percentToFeeUnits(poolForm.buyFeePercent),
      percentToFeeUnits(poolForm.sellFeePercent)
    );

    // MEV module
    let mevModule: Address = '0x0000000000000000000000000000000000000000';
    let mevModuleData: `0x${string}` = '0x';

    if (mevForm.moduleType === 'linear') {
      mevModule = addresses.mevLinearFees;
      mevModuleData = encodeMevLinearData(
        percentToFeeUnits(mevForm.linearStartPercent),
        percentToFeeUnits(mevForm.linearEndPercent),
        mevForm.linearDurationMin * 60
      );
    } else if (mevForm.moduleType === 'descending') {
      mevModule = addresses.mevDescFees;
      mevModuleData = encodeMevDescendingData(
        percentToFeeUnits(mevForm.descStartPercent),
        percentToFeeUnits(mevForm.descEndPercent),
        mevForm.descDurationSec
      );
    } else if (mevForm.moduleType === 'timeDelay') {
      mevModule = addresses.mevTimeDelay;
      mevModuleData = '0x';
    }

    // Locker config
    const rewardAdmins: Address[] = rewardsForm.recipients.map(r => (r.admin || address) as Address);
    const rewardRecipients: Address[] = rewardsForm.recipients.map(r => (r.recipient || address) as Address);
    const rewardBps: number[] = rewardsForm.recipients.map(r => r.bps);
    const tickLower: number[] = rewardsForm.positions.map(p => p.tickLower);
    const tickUpper: number[] = rewardsForm.positions.map(p => p.tickUpper);
    const positionBps: number[] = rewardsForm.positions.map(p => p.bps);

    // Total supply — exact bigint math. `validateDeploy` guarantees
    // `tokenForm.totalSupply` is either empty or a digits-only string, so
    // this never routes through `Number`/floating point (which loses
    // precision above 2^53). Empty or "0" means "use factory default".
    const supplyDigits = tokenForm.totalSupply.trim();
    const totalSupply =
      supplyDigits !== '' && BigInt(supplyDigits) > 0n
        ? BigInt(supplyDigits) * 10n ** 18n
        : 0n;

    // Extensions
    type ExtConfig = {
      extension: Address;
      msgValue: bigint;
      extensionBps: number;
      extensionData: `0x${string}`;
    };
    const extensionConfigs: ExtConfig[] = [];

    if (extensionsForm.vault.enabled) {
      const vaultAdmin = (extensionsForm.vault.admin || address) as Address;
      extensionConfigs.push({
        extension: addresses.vault,
        msgValue: 0n,
        extensionBps: extensionsForm.vault.allocationPercent * 100,
        extensionData: encodeVaultData(
          vaultAdmin,
          extensionsForm.vault.lockupDays,
          extensionsForm.vault.vestingDays
        ),
      });
    }

    if (extensionsForm.airdrop.enabled) {
      const airdropAdmin = (extensionsForm.airdrop.admin || address) as Address;
      const merkleRoot = (extensionsForm.airdrop.merkleRoot ||
        '0x0000000000000000000000000000000000000000000000000000000000000000') as `0x${string}`;
      extensionConfigs.push({
        extension: addresses.airdrop,
        msgValue: 0n,
        extensionBps: extensionsForm.airdrop.allocationPercent * 100,
        extensionData: encodeAirdropData(
          airdropAdmin,
          merkleRoot,
          extensionsForm.airdrop.lockupDays,
          extensionsForm.airdrop.vestingDays
        ),
      });
    }

    if (extensionsForm.devBuy.enabled) {
      extensionConfigs.push({
        extension: addresses.devBuy,
        msgValue: parseEther(extensionsForm.devBuy.ethAmount || '0'),
        extensionBps: extensionsForm.devBuy.allocationPercent * 100,
        extensionData: '0x',
      });
    }

    // Total ETH value
    const totalValue = extensionConfigs.reduce((sum, ext) => sum + ext.msgValue, 0n);

    const deploymentConfig = {
      tokenConfig: {
        tokenAdmin: admin,
        name: tokenForm.name,
        symbol: tokenForm.symbol,
        salt,
        image: tokenForm.image,
        metadata: tokenForm.metadata,
        context: tokenForm.context,
        totalSupply,
      },
      poolConfig: {
        hook: addresses.hook,
        pairedToken,
        tickIfToken0IsNewMaterial: poolForm.startingTick,
        tickSpacing: poolForm.tickSpacing,
        poolData,
      },
      lockerConfig: {
        locker: addresses.locker,
        rewardAdmins,
        rewardRecipients,
        rewardBps,
        tickLower,
        tickUpper,
        positionBps,
        lockerData: '0x' as `0x${string}`,
      },
      mevModuleConfig: {
        mevModule,
        mevModuleData,
      },
      extensionConfigs,
    };

    submit({
      address: addresses.factory,
      abi: factoryAbi,
      functionName: 'deployToken',
      args: [deploymentConfig],
      value: totalValue,
    });
  };

  const mevLabel =
    mevForm.moduleType === 'none'
      ? 'None'
      : mevForm.moduleType === 'linear'
        ? `Linear (${mevForm.linearStartPercent}% -> ${mevForm.linearEndPercent}% over ${mevForm.linearDurationMin}m)`
        : mevForm.moduleType === 'descending'
          ? `Descending (${mevForm.descStartPercent}% -> ${mevForm.descEndPercent}% over ${mevForm.descDurationSec}s)`
          : `Time Delay (${mevForm.timeDelaySec}s)`;

  const totalExtAlloc =
    (extensionsForm.vault.enabled ? extensionsForm.vault.allocationPercent : 0) +
    (extensionsForm.airdrop.enabled ? extensionsForm.airdrop.allocationPercent : 0) +
    (extensionsForm.devBuy.enabled ? extensionsForm.devBuy.allocationPercent : 0);

  const errors = validateDeploy({ tokenForm, poolForm, rewardsForm, extensionsForm });

  return (
    <div className="space-y-6">
      {/* Summary */}
      <div className="space-y-4">
        <div>
          <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">Token</h4>
          <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 px-4 py-2">
            <Row label="Name" value={tokenForm.name || '-'} />
            <Row label="Symbol" value={tokenForm.symbol || '-'} />
            <Row label="Admin" value={tokenForm.admin || 'Connected wallet'} />
            <Row label="Supply" value={Number(tokenForm.totalSupply) > 0 ? Number(tokenForm.totalSupply).toLocaleString() : 'Factory default'} />
          </div>
        </div>

        <div>
          <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">Pool</h4>
          <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 px-4 py-2">
            <Row label="Paired Token" value={poolForm.pairedToken === 'weth' ? 'WETH' : poolForm.customPairedToken} />
            <Row label="Tick Spacing" value={poolForm.tickSpacing} />
            <Row label="Starting Tick" value={poolForm.startingTick} />
            <Row label="Buy Fee" value={`${poolForm.buyFeePercent}%`} />
            <Row label="Sell Fee" value={`${poolForm.sellFeePercent}%`} />
          </div>
        </div>

        <div>
          <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">MEV Protection</h4>
          <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 px-4 py-2">
            <Row label="Module" value={mevLabel} />
          </div>
        </div>

        <div>
          <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">Rewards</h4>
          <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 px-4 py-2">
            <Row label="Mode" value={rewardsForm.mode} />
            <Row label="Recipients" value={rewardsForm.recipients.length} />
            <Row label="Positions" value={rewardsForm.positions.length} />
          </div>
        </div>

        <div>
          <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">Extensions</h4>
          <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 px-4 py-2">
            <Row label="Vault" value={extensionsForm.vault.enabled ? `${extensionsForm.vault.allocationPercent}%` : 'Disabled'} />
            <Row label="Airdrop" value={extensionsForm.airdrop.enabled ? `${extensionsForm.airdrop.allocationPercent}%` : 'Disabled'} />
            <Row label="Dev Buy" value={extensionsForm.devBuy.enabled ? `${extensionsForm.devBuy.ethAmount} ETH (${extensionsForm.devBuy.allocationPercent}%)` : 'Disabled'} />
            <Row label="Liquidity" value={`${100 - totalExtAlloc}%`} />
          </div>
        </div>
      </div>

      {/* Deploy */}
      {deployedToken ? (
        <div className="rounded-lg border border-green-800 bg-green-900/20 p-4 space-y-2">
          <h4 className="text-green-400 font-semibold">Token Deployed Successfully</h4>
          <p className="text-sm text-zinc-300 font-mono break-all">{deployedToken}</p>
          <div className="flex flex-wrap gap-3">
            <Link
              to={`/tokens/${deployedToken}`}
              className="text-sm text-violet-400 hover:text-violet-300 underline"
            >
              View token details
            </Link>
            <a
              href={`${etherscanBase}/address/${deployedToken}`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-sm text-violet-400 hover:text-violet-300 underline"
            >
              View on Etherscan
            </a>
            {txHash && (
              <a
                href={`${etherscanBase}/tx/${txHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-sm text-violet-400 hover:text-violet-300 underline"
              >
                View Transaction
              </a>
            )}
          </div>
        </div>
      ) : (
        <>
          {!isConnected && (
            <p className="text-sm text-amber-400">Connect your wallet to deploy.</p>
          )}

          {txHash && isConfirming && (
            <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-4 space-y-2">
              <p className="text-sm text-zinc-300">
                Transaction submitted. Waiting for confirmation...
              </p>
              <a
                href={`${etherscanBase}/tx/${txHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-sm text-violet-400 hover:text-violet-300 underline font-mono break-all"
              >
                {txHash}
              </a>
            </div>
          )}

          {writeError && (
            <div className="rounded-lg border border-red-800 bg-red-900/20 p-3">
              <p className="text-sm text-red-400">
                {writeError.message.length > 200
                  ? writeError.message.slice(0, 200) + '...'
                  : writeError.message}
              </p>
            </div>
          )}

          {errors.length > 0 && (
            <div className="rounded-lg border border-red-800 bg-red-900/20 p-3 space-y-1">
              <p className="text-sm font-medium text-red-400">
                Fix the following before deploying:
              </p>
              <ul className="list-disc pl-5 space-y-0.5">
                {errors.map((err, i) => (
                  <li key={i} className="text-sm text-red-400">
                    {err}
                  </li>
                ))}
              </ul>
            </div>
          )}

          <button
            type="button"
            onClick={handleDeploy}
            disabled={!isConnected || isPending || isConfirming || errors.length > 0}
            className="w-full rounded-xl bg-violet-600 py-3 text-base font-semibold text-white transition-colors hover:bg-violet-500 disabled:bg-zinc-700 disabled:text-zinc-500 disabled:cursor-not-allowed"
          >
            {isPending
              ? 'Confirm in Wallet...'
              : isConfirming
                ? 'Confirming...'
                : 'Deploy Token'}
          </button>
        </>
      )}
    </div>
  );
}

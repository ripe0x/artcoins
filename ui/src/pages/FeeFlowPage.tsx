/**
 * Snapshot of the Sepolia rehearsal of the LAYER mainnet launch +
 * fee-flow architecture. Hardcoded — this is a one-shot record of
 * the deploy and smoke tests, not a live dashboard.
 */

const ETHERSCAN = 'https://sepolia.etherscan.io';

type Row = { label: string; value: string; tx?: string; addr?: string; sub?: string };

function txLink(hash: string) {
  return `${ETHERSCAN}/tx/${hash}`;
}
function addrLink(addr: string) {
  return `${ETHERSCAN}/address/${addr}`;
}

function ShortAddr({ addr }: { addr: string }) {
  return (
    <a
      href={addrLink(addr)}
      target="_blank"
      rel="noreferrer"
      className="font-mono text-xs text-violet-400 hover:text-violet-300 underline-offset-2 hover:underline"
    >
      {addr.slice(0, 8)}…{addr.slice(-6)}
    </a>
  );
}
function ShortTx({ hash }: { hash: string }) {
  return (
    <a
      href={txLink(hash)}
      target="_blank"
      rel="noreferrer"
      className="font-mono text-xs text-emerald-400 hover:text-emerald-300 underline-offset-2 hover:underline"
    >
      {hash.slice(0, 10)}…{hash.slice(-8)}
    </a>
  );
}

function Section({ title, subtitle, children }: { title: string; subtitle?: string; children: React.ReactNode }) {
  return (
    <section className="border border-zinc-800 rounded-xl p-5 bg-zinc-950/40">
      <h2 className="text-lg font-semibold text-white mb-1">{title}</h2>
      {subtitle && <p className="text-sm text-zinc-400 mb-4">{subtitle}</p>}
      <div className="space-y-1.5">{children}</div>
    </section>
  );
}

function KV({ k, v, mono }: { k: string; v: React.ReactNode; mono?: boolean }) {
  return (
    <div className="grid grid-cols-12 gap-3 text-sm py-1 border-b border-zinc-900 last:border-b-0">
      <div className="col-span-4 text-zinc-400">{k}</div>
      <div className={`col-span-8 ${mono ? 'font-mono text-xs' : ''} text-zinc-100`}>{v}</div>
    </div>
  );
}

const CONTRACTS: Row[] = [
  { label: 'Factory',                  value: '', addr: '0xac2c38801485451317d9212d9631b1221a11ad6c' },
  { label: 'Hook (StaticFeeV2)',       value: '', addr: '0xed8c1f32cd8cc5691449dfa78cd81509252b28cc' },
  { label: 'LpLockerMultiple',         value: '', addr: '0x6bf7693f94f51333e12151abbaabb49867bf4c9c' },
  { label: 'FeeLocker',                value: '', addr: '0xa8f7e33f9bac7960ab3a9780c79e3ded98edaed6' },
  { label: 'ArtCoinsToken impl',       value: '', addr: '0x0f7f6df55ea54939d1b396b946dd5f47fbeecacc' },
  { label: 'PoolExtensionAllowlist',   value: '', addr: '0xd21be2b954f5d9ee770975f7794c9c35e17f9e96' },
  { label: 'ProtocolFeeController',    value: '', addr: '0xe92e7fbbaadfe83cdd7eac813041c50d33d999e0' },
  { label: 'BurnRouter (initialized)', value: '', addr: '0xa02ba69a5e0856e3101eb31d3abeefc0f6fc9bdd' },
  { label: 'BurnExtension',            value: '', addr: '0x925daed4e23abbd59f79e8abf16dbb5f238740fe' },
  { label: 'MevSteppedFees',           value: '', addr: '0x6d97a510fc873008a340b0d39f95bc2467175a31' },
  { label: 'MevLinearFees',            value: '', addr: '0xddecfb930d593b5c1874c2bb357f1a9ab332a069' },
  { label: 'MevDescendingFees',        value: '', addr: '0x8ebe592409a6e48d7072f24718860d41610012e1' },
  { label: 'AirdropV2',                value: '', addr: '0xaada5eef87a31f24586ca52b09d7fe409e95976e' },
  { label: 'Vault',                    value: '', addr: '0x9ad0311bab78b914b79cf9075503716887e6c09a' },
  { label: 'DevBuy',                   value: '', addr: '0x55427225861c018176df482508b14aafabadae0d' },
  { label: 'DefaultMetadataRenderer',  value: '', addr: '0x42543dd7e5a1580005c6a73bf75fc4e14dbb7be6' },
];

const LAYER_TOKEN = '0x6c9c31127738cf50e1a8d3747c0b1021aeba4ede';
const ARTTEST_TOKEN = '0x10d0d6db846581a0d1622a7b4b1c426adb44723b';
const BURN_ROUTER = '0xa02ba69a5e0856e3101eb31d3abeefc0f6fc9bdd';
const PROTOCOL_FEE_CONTROLLER = '0xe92e7fbbaadfe83cdd7eac813041c50d33d999e0';
const DEPLOYER = '0x4fa58ffc00d973fd222d573c256eb3cc81a8569c';

const DEPLOY_TXS: { name: string; hash: string }[] = [
  { name: 'FeeLocker',                hash: '0x852fa7b6ca5cd1549c29ea776472c8fb6de991d8247edad6fd71aa42c778a20c' },
  { name: 'ArtCoinsToken impl',       hash: '0xcdd51f3e04d09e046ddc92945a8219e1444702f0fa496d925a22c6b34bcaf91e' },
  { name: 'Factory',                  hash: '0x22178f672ade655e44712ce3ef8e2e550e190a273681adbdd4b7dfce9ca198df' },
  { name: 'PoolExtensionAllowlist',   hash: '0xb6b88e7215ec5a28634f723ede41cba645eb39325fbd9d70d3f7d4703644b665' },
  { name: 'Hook (StaticFeeV2)',       hash: '0x1546fcf104f457f52abded0f92ce1195f58af04c6ee9bf2555790022516ab8ea' },
  { name: 'LpLockerMultiple',         hash: '0x40d7108a08d04be1f0771104ad0e424e72612da0125fd4d2f03acdc29be311a2' },
  { name: 'AirdropV2',                hash: '0xf3d6e4cbf09b7a7d218b500f5bca9f327e14af1a547b92482634fc7779d31357' },
  { name: 'BurnExtension',            hash: '0xe0e1d067a792f6fa797d686e5f59de3d5178d7739a2c8c2163dc569bc2e5c76b' },
  { name: 'MevSteppedFees',           hash: '0x4f92fe7a4b6c16ec1abc54ecc61c5466a45e542fabd08e15d34263720f502c99' },
  { name: 'BurnRouter',               hash: '0xad0f17e139892dbdd273584358372041bfb6226edb9db4bdc7ec612f6dec1b36' },
  { name: 'ProtocolFeeController',    hash: '0x82e941e6df7599ee804e083b9cd73c7af2812cdaf991c63ad0ca5b79610b5997' },
];

// Smoke 1: 0.02 ETH WETH buy of ARTTEST. Fee = 1% × 0.02 = 0.0002 ETH (200_000_000_000_000 wei).
// Distributed by LpLockerMultiple per ARTTEST reward array.
const SMOKE1_TXS: { step: number; label: string; hash: string }[] = [
  { step: 1, label: 'Deploy PoolSwapTest helper',                      hash: '0x05023647bb28c8fc6db91d73b1e2cd32fc740921ac3930a1891f96baef569db8' },
  { step: 2, label: 'WETH.deposit (wrap 0.02 ETH)',                    hash: '0xe8279d24975e7321ca13969d70e85e60919956bc301462a93ca82f8b72b76e0f' },
  { step: 3, label: 'WETH.approve(swap helper)',                       hash: '0xa97ebf9a227dc0e200e46a9a1ae7261948268a8a75d0178177ff9555f0d8603b' },
  { step: 4, label: 'PoolManager.swap (WETH → ARTTEST, 0.02 ETH)',     hash: '0xec7720493b2a80e7c1851d69bf8962266d990b4ff20c13eacc7801597d0de735' },
  { step: 5, label: 'Locker.collectRewards(ARTTEST) — bps split',      hash: '0x5e08187b8cdf9c0fe8a84f23b2263c1632cfbe09617975554f389910d44d8469' },
  { step: 6, label: 'FeeLocker.claim(BurnRouter, WETH)',               hash: '0x94f3f3f4bbfd6e42a33b724fa326762f4268eeeacedebbbc8ff298268fcf15ad' },
  { step: 7, label: 'FeeLocker.claim(ProtocolFeeController, WETH)',    hash: '0xffb937d11b5477c5e211f6aa2ffce9d9e0c7d9619ffc7df9d4c4d04df594341c' },
  { step: 8, label: 'ProtocolFeeController.processFees(WETH) — 60/40', hash: '0xcbd510773793d54d5449c379a276ddafa4213a0199cb90a836fc7bf5439d39dc' },
];

// Smoke 3: claim ARTTEST-side fees through to BurnRouter — proves the cross-coin gap
// (non-LAYER non-WETH artcoin fees accumulate with no automatic conversion path).
const SMOKE3_TXS: { step: number; label: string; hash: string }[] = [
  { step: 1, label: 'FeeLocker.claim(BurnRouter, ARTTEST) — push project-burn slot share',         hash: '0x6f050901aba4eef318bec8f8063e569536773125d1328a4d4279fbcb940a2bef' },
  { step: 2, label: 'FeeLocker.claim(ProtocolFeeController, ARTTEST) — push protocol slot share',  hash: '0x90a9a74b0182b74ac1e684ef0d44880a7dc9230ead1ca82be492f0fc84b9dcda' },
  { step: 3, label: 'ProtocolFeeController.processFees(ARTTEST) — 60/40 split, BR side held',      hash: '0xaa264c3c5d7bfcd23997c9e0e0b9d4a5750d73fdae05d88feccb1a51683405b2' },
];

// Smoke 2: sell some ARTTEST + buy LAYER + transfer LAYER to BurnRouter + burn.
const SMOKE2_TXS: { step: number; label: string; hash: string }[] = [
  { step: 1, label: 'ARTTEST.approve(swap helper)',                       hash: '0x4a72a9bcde5390a9f3769f4146422a969661098a1a0b86bfa07d254f6a500f6f' },
  { step: 2, label: 'PoolManager.swap (ARTTEST → WETH, sell 25% held)',   hash: '0x6d0cacaa5f4d5c5c43400964e9792dff5b6e5e65a8bc09510bd291150f1c9dc5' },
  { step: 3, label: 'Locker.collectRewards(ARTTEST) — pushes ARTTEST-side fee', hash: '0xc945659557cd8d9a7f161d10cd515ab24cc6d4fa74efd635ef09f0990e9c9470' },
  { step: 4, label: 'WETH.deposit (wrap 0.005 ETH)',                       hash: '0xac2c5d4db750a2c1789cd2d6501876f242f339ee07f79d4c51ded2a9ecee341a' },
  { step: 5, label: 'WETH.approve(swap helper)',                           hash: '0xfa5092eb27b9fa6ced848bf3e0bd519ef7eee92b9e94f9d69ec8c7eb78fd8439' },
  { step: 6, label: 'PoolManager.swap (WETH → LAYER, 0.005 ETH)',          hash: '0xa786f1c7ec00af86f4250d26098b1568bdd629ee5c76f7b04a82cefd1438df61' },
  { step: 7, label: 'LAYER.transfer(BurnRouter) — half of bought LAYER',   hash: '0x941c9053cf864dfd2f20b52233c7d4b7d38952a1095c93a47ce1fcff6b644cc2' },
  { step: 8, label: 'BurnRouter.processBurnLayer() — 🔥',                  hash: '0x5f9ef5948f6d86416751b204362117f07a3c051fb5304ebcdce54edd0d170545' },
];

function FeeBox({
  recipient,
  recipientAddr,
  bps,
  ethAmount,
  weiAmount,
  note,
}: {
  recipient: string;
  recipientAddr?: string;
  bps: string;
  ethAmount: string;
  weiAmount: string;
  note?: string;
}) {
  return (
    <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
      <div className="flex items-center justify-between gap-3 mb-1">
        <div className="font-medium text-zinc-100">{recipient}</div>
        <div className="text-xs text-violet-300 font-mono">{bps}</div>
      </div>
      {recipientAddr && (
        <div className="mb-1">
          <ShortAddr addr={recipientAddr} />
        </div>
      )}
      <div className="font-mono text-sm text-emerald-300">{ethAmount}</div>
      <div className="font-mono text-[10px] text-zinc-500">{weiAmount}</div>
      {note && <div className="text-xs text-zinc-400 mt-1">{note}</div>}
    </div>
  );
}

export default function FeeFlowPage() {
  return (
    <div className="mx-auto max-w-5xl px-4 py-8 space-y-6">
      <header>
        <h1 className="text-2xl font-bold text-white">Sepolia rehearsal — fee flow</h1>
        <p className="text-sm text-zinc-400 mt-1">
          Snapshot of the Sepolia deploy of the LAYER + ARTTEST + protocol-fee
          stack, with smoke tests exercising the fee path through the locker,
          FeeLocker, ProtocolFeeController, and BurnRouter. Click any address
          or tx hash to open in Etherscan.
        </p>
        <div className="mt-3 text-xs text-zinc-500">
          Chain: <span className="text-zinc-300">Sepolia (11155111)</span>
          {'  ·  '}
          Deployer: <ShortAddr addr={DEPLOYER} />
        </div>
      </header>

      {/* ─── Fee architecture (artcoins v1) ────────────────────────── */}
      <Section
        title="Fee architecture — artcoins v1"
        subtitle="Trader pays exactly the configured pool fee. The protocol's share is taken from the locker reward distribution (not from a hook-level skim on top of the pool fee)."
      >
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-sm text-zinc-100 font-medium mb-1">Pool fee</div>
            <div className="text-xs text-zinc-400">
              The fee traders pay to swap. For LAYER: <span className="text-zinc-100 font-mono">1.00%</span>.
              Hook's <code className="text-violet-300">protocolFeeNumerator</code> is locked at <span className="text-zinc-100 font-mono">0</span> in artcoins v1, so the trader pays exactly this and nothing more.
            </div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-sm text-zinc-100 font-medium mb-1">Locker reward distribution</div>
            <div className="text-xs text-zinc-400">
              Collected LP fee splits per the locker reward array.
              For LAYER: 38% artist · 42% project burn → BurnRouter · 20% protocol reward slot → ProtocolFeeController.
            </div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-sm text-zinc-100 font-medium mb-1">Protocol reward slot</div>
            <div className="text-xs text-zinc-400">
              <span className="font-mono">2000 bps</span> of the locker reward array (factory-injected, immutable per pool). PFC then splits 60% artcoins treasury / 40% LAYER buy-and-burn.
            </div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-sm text-zinc-100 font-medium mb-1">No hook-level protocol skim</div>
            <div className="text-xs text-zinc-400">
              <span className="text-emerald-300 font-mono">protocolFeeNumerator = 0</span>. Asserted at deploy and at LAYER launch preflight. Live regression test: <code className="text-violet-300">HookProtocolFeeNumeratorZeroTest</code>.
            </div>
          </div>
        </div>

        <div className="text-sm text-zinc-300 mt-4 mb-2">Effective LAYER fee at 1% pool fee:</div>
        <div className="overflow-x-auto">
          <table className="w-full text-xs font-mono">
            <thead className="text-zinc-500 border-b border-zinc-800">
              <tr>
                <th className="text-left py-1.5 px-2">Recipient</th>
                <th className="text-left py-1.5 px-2">Path</th>
                <th className="text-right py-1.5 px-2">Share of fee</th>
                <th className="text-right py-1.5 px-2">% of trade volume</th>
              </tr>
            </thead>
            <tbody className="text-zinc-200">
              <tr className="border-b border-zinc-900">
                <td className="py-1.5 px-2">Artist treasury</td>
                <td className="py-1.5 px-2 text-zinc-400">locker slot 0</td>
                <td className="py-1.5 px-2 text-right">3,800 bps</td>
                <td className="py-1.5 px-2 text-right">0.38%</td>
              </tr>
              <tr className="border-b border-zinc-900">
                <td className="py-1.5 px-2">BurnRouter (project)</td>
                <td className="py-1.5 px-2 text-zinc-400">locker slot 1 → 🔥</td>
                <td className="py-1.5 px-2 text-right">4,200 bps</td>
                <td className="py-1.5 px-2 text-right">0.42%</td>
              </tr>
              <tr className="border-b border-zinc-900">
                <td className="py-1.5 px-2">artcoins treasury</td>
                <td className="py-1.5 px-2 text-zinc-400">locker slot 2 → PFC → 60% treasury</td>
                <td className="py-1.5 px-2 text-right">1,200 bps</td>
                <td className="py-1.5 px-2 text-right">0.12%</td>
              </tr>
              <tr className="border-b border-zinc-900">
                <td className="py-1.5 px-2">BurnRouter (protocol)</td>
                <td className="py-1.5 px-2 text-zinc-400">locker slot 2 → PFC → 40% burn</td>
                <td className="py-1.5 px-2 text-right">800 bps</td>
                <td className="py-1.5 px-2 text-right">0.08%</td>
              </tr>
              <tr className="border-t border-zinc-700 font-semibold">
                <td className="py-1.5 px-2">Total burn</td>
                <td className="py-1.5 px-2 text-emerald-400">project + protocol</td>
                <td className="py-1.5 px-2 text-right">5,000 bps</td>
                <td className="py-1.5 px-2 text-right text-emerald-300">0.50%</td>
              </tr>
              <tr className="font-semibold">
                <td className="py-1.5 px-2">Total treasury</td>
                <td className="py-1.5 px-2 text-violet-400">artist + artcoins</td>
                <td className="py-1.5 px-2 text-right">5,000 bps</td>
                <td className="py-1.5 px-2 text-right text-violet-300">0.50%</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div className="mt-4 border border-emerald-900 bg-emerald-950/30 rounded-lg p-3 text-xs text-emerald-200/80">
          <div className="text-sm text-emerald-300 font-medium mb-1">
            Anti-sniper extra-fee routing — DUAL-PATH (live)
          </div>
          The stepped MEV schedule (50% → 25% → 15% → 7% → 3% over the first 15 minutes) is signalled by <code>ArtCoinsMevSniperSteppedFees</code> as an <em>extra</em> ppm above the pool's base 1% LP fee. The hook collects the extra from the swap's input currency in <code>_beforeSwap</code> and routes it 100% to BurnRouter (LAYER buy-and-burn), bypassing the locker normal split. The base 1% continues to flow through the locker (38% artist / 42% project burn / 12% artcoins treasury / 8% protocol burn) unchanged. Trader pays exactly the headline rate (no hook double-skim — <code>protocolFeeNumerator == 0</code>).
        </div>

        <div className="mt-3 overflow-x-auto">
          <div className="text-sm text-zinc-300 mb-2">Per-window routing breakdown:</div>
          <table className="w-full text-xs font-mono">
            <thead className="text-zinc-500 border-b border-zinc-800">
              <tr>
                <th className="text-left py-1.5 px-2">Window</th>
                <th className="text-right py-1.5 px-2">Total fee</th>
                <th className="text-right py-1.5 px-2">Base (locker split)</th>
                <th className="text-right py-1.5 px-2">Extra (→ 100% burn)</th>
                <th className="text-right py-1.5 px-2">Effective burn</th>
                <th className="text-right py-1.5 px-2">Effective treasury</th>
              </tr>
            </thead>
            <tbody className="text-zinc-200">
              {[
                { w: '0–1m',    total: 50, base: 1, extra: 49 },
                { w: '1–3m',    total: 25, base: 1, extra: 24 },
                { w: '3–5m',    total: 15, base: 1, extra: 14 },
                { w: '5–10m',   total:  7, base: 1, extra:  6 },
                { w: '10–15m',  total:  3, base: 1, extra:  2 },
                { w: '15m+',    total:  1, base: 1, extra:  0 },
              ].map((row, i) => {
                // Base 1% splits 50/50 burn/treasury per LAYER spec.
                const burnFromBase = row.base * 0.5;
                const treasuryFromBase = row.base * 0.5;
                const totalBurn = burnFromBase + row.extra;
                return (
                  <tr key={i} className="border-b border-zinc-900">
                    <td className="py-1.5 px-2">{row.w}</td>
                    <td className="py-1.5 px-2 text-right">{row.total}%</td>
                    <td className="py-1.5 px-2 text-right">{row.base}%</td>
                    <td className="py-1.5 px-2 text-right text-emerald-300">{row.extra}%</td>
                    <td className="py-1.5 px-2 text-right text-emerald-300">{totalBurn.toFixed(2)}%</td>
                    <td className="py-1.5 px-2 text-right text-violet-300">{treasuryFromBase.toFixed(2)}%</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <div className="mt-2 text-xs text-zinc-500">
            "Effective burn" = base × 50% (project + protocol burn share) + extra × 100% (sniper-extra path). "Effective treasury" = base × 50% (artist + artcoins treasury). Sums to the trader's total fee.
          </div>
        </div>
      </Section>

      {/* ─── Preset L: the recommended LAYER launch shape ─────────── */}
      <Section
        title="LAYER recommended launch shape — Preset L (12-position thin-floor taper)"
        subtitle="Selected after 11-preset simulator iteration as the safest launch curve preserving no-ETH-seed. Tests in test/LayerPresetLDefault.t.sol lock the shape down. LaunchLayer.s.sol asserts these invariants pre-broadcast."
      >
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-xs text-zinc-500">Positions</div>
            <div className="font-mono text-zinc-100 text-lg">12</div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-xs text-zinc-500">Start tick</div>
            <div className="font-mono text-zinc-100 text-lg">−190,400</div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-xs text-zinc-500">End tick</div>
            <div className="font-mono text-zinc-100 text-lg">−130,400</div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-xs text-zinc-500">Total width</div>
            <div className="font-mono text-zinc-100 text-lg">60,000</div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-xs text-zinc-500">LAYER in LP</div>
            <div className="font-mono text-zinc-100 text-lg">639,800,000</div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-xs text-zinc-500">ETH/WETH seed</div>
            <div className="font-mono text-zinc-100 text-lg">0</div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-xs text-zinc-500">Tick spacing</div>
            <div className="font-mono text-zinc-100 text-lg">200</div>
          </div>
          <div className="border border-zinc-800 rounded-lg p-3 bg-zinc-900/40">
            <div className="text-xs text-zinc-500">Pool fee</div>
            <div className="font-mono text-zinc-100 text-lg">1%</div>
          </div>
        </div>

        <div className="text-sm text-zinc-300 mb-2">Per-position allocation:</div>
        <div className="overflow-x-auto">
          <table className="w-full text-xs font-mono">
            <thead className="text-zinc-500 border-b border-zinc-800">
              <tr>
                <th className="text-left py-1.5 px-2">#</th>
                <th className="text-left py-1.5 px-2">tickLower</th>
                <th className="text-left py-1.5 px-2">tickUpper</th>
                <th className="text-left py-1.5 px-2">width</th>
                <th className="text-left py-1.5 px-2">bps</th>
                <th className="text-left py-1.5 px-2">% of LP</th>
                <th className="text-left py-1.5 px-2">LAYER</th>
                <th className="text-left py-1.5 px-2">zone</th>
              </tr>
            </thead>
            <tbody className="text-zinc-200">
              {[
                { lo: 0,      hi: 1400,   bps: 50,   zone: 'thin floor' },
                { lo: 1400,   hi: 3400,   bps: 150,  zone: '' },
                { lo: 3400,   hi: 6000,   bps: 300,  zone: '' },
                { lo: 6000,   hi: 9400,   bps: 500,  zone: '' },
                { lo: 9400,   hi: 14000,  bps: 800,  zone: '' },
                { lo: 14000,  hi: 19400,  bps: 1300, zone: 'main growth' },
                { lo: 19400,  hi: 26000,  bps: 1700, zone: '' },
                { lo: 26000,  hi: 33000,  bps: 1700, zone: '' },
                { lo: 33000,  hi: 40000,  bps: 1300, zone: '' },
                { lo: 40000,  hi: 47000,  bps: 1000, zone: '' },
                { lo: 47000,  hi: 53400,  bps: 800,  zone: 'tail' },
                { lo: 53400,  hi: 60000,  bps: 400,  zone: '' },
              ].map((p, i) => {
                const startTick = -190_400;
                const layer = ((639_800_000 * p.bps) / 10_000).toLocaleString();
                return (
                  <tr key={i} className="border-b border-zinc-900">
                    <td className="py-1.5 px-2 text-zinc-500">{i + 1}</td>
                    <td className="py-1.5 px-2">{(startTick + p.lo).toLocaleString()}</td>
                    <td className="py-1.5 px-2">{(startTick + p.hi).toLocaleString()}</td>
                    <td className="py-1.5 px-2 text-zinc-400">{(p.hi - p.lo).toLocaleString()}</td>
                    <td className="py-1.5 px-2">{p.bps}</td>
                    <td className="py-1.5 px-2 text-zinc-400">{(p.bps / 100).toFixed(1)}%</td>
                    <td className="py-1.5 px-2">{layer}</td>
                    <td className="py-1.5 px-2 text-violet-400">{p.zone}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        <div className="mt-4 border border-amber-900 bg-amber-950/30 rounded-lg p-3 text-xs text-amber-200/80">
          <div className="text-sm text-amber-300 font-medium mb-1">Why this shape (simulator-validated)</div>
          0.5 ETH first-buy captures ~62M LAYER (~8.4% of post-burn supply) — meaningfully better than the 4-position baseline (397M, 53.8%) and the simple single wide LP (578M, 78.2%). Cumulative captures: 1 ETH→118M, 2 ETH→189M, 10 ETH→398M. Full LP exhaust at ~184 ETH. With anti-sniper at min 0 (50% extra fee), first 0.5 ETH drops to ~32M. <strong>Do not change the position table without re-running the simulator.</strong>
        </div>
      </Section>

      {/* ─── Tokens ─────────────────────────────────────────────── */}
      <Section
        title="Tokens"
        subtitle="LAYER (mirror of mainnet allocation) and ARTTEST (vanilla artcoin used to exercise the cross-coin path)."
      >
        <KV
          k="LAYER token"
          v={
            <span>
              <ShortAddr addr={LAYER_TOKEN} />
              <span className="ml-2 text-zinc-500">·</span>
              <a
                className="ml-2 text-xs text-violet-400 hover:underline"
                href={txLink('0x9c730c9b8c1af904982f1438b44150c99d61985abe0953a16e15f2c4ab124add')}
                target="_blank"
                rel="noreferrer"
              >
                deployToken tx
              </a>
              <span className="ml-2 text-zinc-500">·</span>
              <a
                className="ml-2 text-xs text-violet-400 hover:underline"
                href={txLink('0xa88549eb9ecc323db48cf2d7289c71f0f5199a96c608a61b0c46e1cc881d0682')}
                target="_blank"
                rel="noreferrer"
              >
                BurnRouter.initialize tx
              </a>
            </span>
          }
        />
        <KV k="LAYER initial supply"   v={<span className="font-mono">1,000,000,000.000 LAYER (1B)</span>} />
        <KV k="LAYER pre-burn (migration)" v={<span className="font-mono">−260,200,000.000 LAYER (26.02%)</span>} />
        <KV k="LAYER post-burn supply" v={<span className="font-mono">739,800,000.000 LAYER</span>} />
        <KV k="LAYER airdrop pool"     v={<span className="font-mono">100,000,000.000 LAYER (10%) → AirdropV2</span>} />
        <KV k="LAYER LP allocation"    v={<span className="font-mono">639,800,000.000 LAYER → 4-position LP</span>} />
        <KV
          k="ARTTEST token"
          v={
            <span>
              <ShortAddr addr={ARTTEST_TOKEN} />
              <span className="ml-2 text-zinc-500">·</span>
              <a
                className="ml-2 text-xs text-violet-400 hover:underline"
                href={txLink('0x1ce8732a53fbde0c4bb0639c813469c8cc24fb5839f04e15d214d83dabca23d9')}
                target="_blank"
                rel="noreferrer"
              >
                deployToken tx
              </a>
            </span>
          }
        />
        <KV k="ARTTEST supply"   v={<span className="font-mono">1,000,000,000.000 ARTTEST (full to LP)</span>} />
        <KV k="ARTTEST splits"   v={<span className="font-mono">artist 50% / project-burn 30% / protocol 20%</span>} />
      </Section>

      {/* ─── Smoke 1 — buy ARTTEST, walk fee path ───────────────────── */}
      <Section
        title="Smoke 1 — Buy ARTTEST, fee distributes through the stack"
        subtitle="0.02 ETH WETH → ARTTEST swap. 1% LP fee = 0.0002 ETH (200,000,000,000,000 wei) on the WETH side. Distributed per ARTTEST locker reward array, then PFC applies 60/40."
      >
        <div className="grid grid-cols-1 md:grid-cols-3 gap-3 my-3">
          <FeeBox
            recipient="Artist treasury"
            recipientAddr={DEPLOYER}
            bps="5000 bps · 50% of fee"
            ethAmount="≈ 0.0001 ETH"
            weiAmount="≈ 100,199,600,798,403 wei"
            note="Deployer doubles as artist treasury for this rehearsal."
          />
          <FeeBox
            recipient="BurnRouter (project-burn slot)"
            recipientAddr={BURN_ROUTER}
            bps="3000 bps · 30% of fee"
            ethAmount="0.0000598… ETH"
            weiAmount="59,880,239,520,957 wei"
            note="Direct credit. Held as WETH in the router."
          />
          <FeeBox
            recipient="ProtocolFeeController"
            recipientAddr={PROTOCOL_FEE_CONTROLLER}
            bps="2000 bps · 20% of fee · injected by factory"
            ethAmount="0.0000399… ETH"
            weiAmount="39,920,159,680,640 wei"
            note="Then split 60/40 by PFC."
          />
        </div>

        <div className="text-sm text-zinc-300 mt-2 mb-2">
          ProtocolFeeController.processFees(WETH) split:
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3 mb-2">
          <FeeBox
            recipient="artcoins treasury (60%)"
            recipientAddr={DEPLOYER}
            bps="treasuryBps 6000"
            ethAmount="0.0000239… ETH"
            weiAmount="23,952,095,808,384 wei"
            note="Deployer also doubles as protocol treasury for the rehearsal."
          />
          <FeeBox
            recipient="BurnRouter (protocol-burn slice)"
            recipientAddr={BURN_ROUTER}
            bps="burnBps 4000 · rewardsBps 0"
            ethAmount="0.0000159… ETH"
            weiAmount="15,968,063,872,256 wei"
            note="Adds to project-burn slice from above."
          />
        </div>

        <div className="border-t border-zinc-800 mt-4 pt-4">
          <div className="text-sm text-zinc-300 mb-1">BurnRouter total WETH after this trade:</div>
          <div className="font-mono text-emerald-300">0.0000758… ETH (75,848,303,393,213 wei)</div>
          <div className="text-xs text-zinc-500 mt-1">
            Below the 0.001 ETH MIN_THRESHOLD_FLOOR, so processBurnWeth is gated
            (correctly). A real production run on mainnet generates much higher
            volume; the path itself is exercised by the
            LaunchLayerForkTest + DemoFeeFlowForkTest fork tests.
          </div>
        </div>

        <div className="border-t border-zinc-800 mt-4 pt-4">
          <div className="text-sm text-zinc-300 mb-2">Transactions, in order:</div>
          <ol className="space-y-1">
            {SMOKE1_TXS.map((t) => (
              <li key={t.hash} className="grid grid-cols-12 gap-3 text-sm py-1">
                <div className="col-span-1 text-zinc-500">{t.step}.</div>
                <div className="col-span-7 text-zinc-300">{t.label}</div>
                <div className="col-span-4 text-right">
                  <ShortTx hash={t.hash} />
                </div>
              </li>
            ))}
          </ol>
        </div>
      </Section>

      {/* ─── Smoke 2 — direct LAYER burn ─────────────────────────── */}
      <Section
        title="Smoke 2 — Direct LAYER burn via BurnRouter"
        subtitle="Bought 0.005 ETH worth of LAYER through the LAYER/WETH pool, transferred half to BurnRouter, called processBurnLayer(). LAYER totalSupply drops by exactly the transferred amount."
      >
        <div className="grid grid-cols-2 gap-3">
          <FeeBox
            recipient="LAYER supply (before)"
            bps="—"
            ethAmount="739,800,000 LAYER"
            weiAmount="739,800,000.000000000000000000"
          />
          <FeeBox
            recipient="LAYER supply (after)"
            bps="—"
            ethAmount="718,504,660.142… LAYER"
            weiAmount="718,504,660,142,482,817,027,087,696 wei"
          />
        </div>
        <div className="mt-3 border border-emerald-900 bg-emerald-950/30 rounded-lg p-3">
          <div className="text-sm text-emerald-300">🔥 LAYER burned this run</div>
          <div className="font-mono text-lg text-emerald-200">21,295,339.857… LAYER</div>
          <div className="text-xs text-emerald-300/70 mt-1">
            Direct call to BurnRouter.processBurnLayer() — same path that fires
            on mainnet whenever LAYER itself accumulates in the router.
          </div>
        </div>

        <div className="border-t border-zinc-800 mt-4 pt-4">
          <div className="text-sm text-zinc-300 mb-2">Transactions, in order:</div>
          <ol className="space-y-1">
            {SMOKE2_TXS.map((t) => (
              <li key={t.hash} className="grid grid-cols-12 gap-3 text-sm py-1">
                <div className="col-span-1 text-zinc-500">{t.step}.</div>
                <div className="col-span-7 text-zinc-300">{t.label}</div>
                <div className="col-span-4 text-right">
                  <ShortTx hash={t.hash} />
                </div>
              </li>
            ))}
          </ol>
        </div>
      </Section>

      {/* ─── Smoke 3 — cross-coin gap ────────────────────────────── */}
      <Section
        title="Smoke 3 — Cross-coin gap (the v1 limitation)"
        subtitle="When ARTTEST is sold, the LP fee is denominated in ARTTEST (not WETH). The locker still routes the project-burn 30% slot + protocol 20% slot to BurnRouter — but BurnRouter has no automatic ARTTEST → LAYER conversion path in v1. ARTTEST sits in the router until adminSweepHeldToken is called."
      >
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3 my-3">
          <FeeBox
            recipient="BurnRouter ARTTEST balance"
            recipientAddr={BURN_ROUTER}
            bps="held — no auto burn path"
            ethAmount="131,334.117… ARTTEST"
            weiAmount="131,334,117,240,929,755,989,265 wei"
            note="processBurnLayer() reverts with NothingToBurn. processBurnWeth() ignores ARTTEST. heldBalance(ARTTEST) is exposed as a view so admins can monitor."
          />
          <FeeBox
            recipient="ProtocolFeeController treasury share"
            recipientAddr={DEPLOYER}
            bps="60% of PFC's slice"
            ethAmount="≈ 41,473.93… ARTTEST"
            weiAmount="60% of 69,123 ARTTEST PFC received"
            note="ARTTEST flows out cleanly to the treasury (deployer here). It's only the burn slice that gets stuck."
          />
        </div>
        <div className="mt-3 border border-amber-900 bg-amber-950/30 rounded-lg p-3">
          <div className="text-sm text-amber-300">v1 gap, by design — fix planned</div>
          <div className="text-xs text-amber-200/80 mt-1">
            For LAYER itself this is fine: LAYER-side fees burn directly,
            WETH-side fees swap to LAYER. The gap only matters for non-LAYER
            artcoins (e.g. ARTTEST). The post-LAYER fee-swap hook (a v2 hook
            that re-enters PoolManager.swap inside afterSwap to convert
            coin-side fees to WETH at the source) is the planned closure.
            Until then, admin sweep of held ARTTEST is the only path.
          </div>
        </div>

        <div className="border-t border-zinc-800 mt-4 pt-4">
          <div className="text-sm text-zinc-300 mb-2">Transactions, in order:</div>
          <ol className="space-y-1">
            {SMOKE3_TXS.map((t) => (
              <li key={t.hash} className="grid grid-cols-12 gap-3 text-sm py-1">
                <div className="col-span-1 text-zinc-500">{t.step}.</div>
                <div className="col-span-7 text-zinc-300">{t.label}</div>
                <div className="col-span-4 text-right">
                  <ShortTx hash={t.hash} />
                </div>
              </li>
            ))}
          </ol>
        </div>
      </Section>

      {/* ─── Stack deployment ────────────────────────────────────── */}
      <Section
        title="Stack deployment"
        subtitle="Every protocol contract on Sepolia. Same script as mainnet (Deploy.s.sol + DeployBurnExtension + DeployMevSteppedFees + DeployProtocolFeeStack), just with chain-aware infra constants."
      >
        {CONTRACTS.map((c) => (
          <KV key={c.label} k={c.label} v={<ShortAddr addr={c.addr!} />} />
        ))}
        <div className="border-t border-zinc-800 mt-4 pt-4">
          <div className="text-sm text-zinc-300 mb-2">Deploy txs:</div>
          <ol className="space-y-1">
            {DEPLOY_TXS.map((t) => (
              <li key={t.hash} className="grid grid-cols-12 gap-3 text-sm py-1">
                <div className="col-span-7 text-zinc-300">{t.name}</div>
                <div className="col-span-5 text-right">
                  <ShortTx hash={t.hash} />
                </div>
              </li>
            ))}
          </ol>
        </div>
      </Section>

      <footer className="text-xs text-zinc-500 pt-4">
        Pre-mainnet rehearsal · Sepolia · {new Date().toISOString().slice(0, 10)}
      </footer>
    </div>
  );
}

/**
 * The only trust signal on a token: it was announced by a factory that is in the deployment registry
 * (token discovery reads logs of those factories only). It says nothing about the token's creator,
 * name or intent. The token's own `isVerified()` flag is set by its admin and is not shown as trust.
 */
export default function OfficialBadge({ version }: { version: 1 | 2 }) {
  return (
    <span
      className="px-1.5 py-0.5 text-[10px] rounded bg-zinc-800 text-zinc-300 border border-zinc-700"
      title="Launched by an artcoins factory listed in the deployment registry. This does not vouch for the token or its creator."
    >
      artcoins factory v{version}
    </span>
  );
}

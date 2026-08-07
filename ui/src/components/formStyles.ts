/**
 * Shared form-control class strings, previously copy-pasted as local
 * `inputClass`/`labelClass`/`selectClass` constants in TokenConfigForm,
 * PoolConfigForm, RewardsForm, ExtensionsForm, AntiSniperForm, and
 * SwapWidget. Where a component needs a deliberately different look (e.g.
 * SwapWidget's larger padding/text), compose on top of these rather than
 * forking the string, e.g. `` `${inputClass} py-2.5 text-base` ``.
 */

export const inputClass =
  'w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white placeholder-zinc-500 focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500';

export const labelClass = 'block text-sm font-medium text-zinc-300 mb-1.5';

/** Same as `inputClass` but without `placeholder-zinc-500` (selects have no placeholder). */
export const selectClass =
  'w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500';

const multisigPlugins = new WeakSet();
/** Registers the built-in multisig plugin for transport capability detection. */
export function multisig(plugin) {
    multisigPlugins.add(plugin);
    return plugin;
}
export function isMultisig(plugin) {
    return multisigPlugins.has(plugin);
}
//# sourceMappingURL=plugin.js.map
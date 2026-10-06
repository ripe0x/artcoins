"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.multisig = multisig;
exports.isMultisig = isMultisig;
const multisigPlugins = new WeakSet();
function multisig(plugin) {
    multisigPlugins.add(plugin);
    return plugin;
}
function isMultisig(plugin) {
    return multisigPlugins.has(plugin);
}
//# sourceMappingURL=plugin.js.map
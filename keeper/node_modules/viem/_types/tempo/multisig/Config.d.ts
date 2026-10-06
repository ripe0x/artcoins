import * as Address from 'ox/Address';
import type * as Hex from 'ox/Hex';
import { MultisigConfig } from 'ox/tempo';
import type * as Store from '../Store.js';
/** Reads a cached multisig config. */
export declare function read(store: Store.Store, options: read.Options): Promise<MultisigConfig.Config | null>;
export declare namespace read {
    /** Parameters for {@link read}. */
    type Options = {
        /** Multisig account address. */
        address: Address.Address;
        /** Config commitment observed onchain. */
        commitment: Hex.Hex;
    };
}
/** Writes a validated multisig config. */
export declare function write(store: Store.Store, options: write.Options): Promise<void>;
export declare namespace write {
    /** Parameters for {@link write}. */
    type Options = {
        /** Multisig account address. */
        address: Address.Address;
        /** Config commitment used for lookup. */
        commitment: Hex.Hex;
        /** Complete config. */
        config: MultisigConfig.Config;
    };
}
//# sourceMappingURL=Config.d.ts.map
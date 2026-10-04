# Native pairing verification

Aether uses idevice v0.1.68 at commit `d32c8189c51c2789496b0768039419c3705498c3`, with the checked-in patch. The patch prevents tunnel connections from silently falling back to pair-setup, preserves authentication rejection if cleanup fails, and distinguishes authentication TLVs from transient pairing errors. Explicit pairing APIs remain available.

Before the first Xcode build, install Rust from https://rustup.rs and run:

```sh
./IDeviceKitten/Native/build.sh
```

The script checks the source archive SHA-256 and builds the iPhone, Intel/Apple Silicon simulator, macOS, and Mac Catalyst slices. Generated binaries and build caches are ignored by Git. Subsequent Xcode builds use the local XCFramework. Run the script again after changing the native patch.

Native regression tests run as part of this script. Only explicit authentication rejection may invalidate a saved record; transport errors and busy/backoff responses must retain it.

# Native pairing verification

Aether uses idevice v0.1.68 at commit `d32c8189c51c2789496b0768039419c3705498c3`, with the checked-in pairing-verification, AFC-write, diagnostics and TLS-stream patches. The patch prevents tunnel connections from silently falling back to pair-setup, preserves authentication rejection if cleanup fails, and distinguishes authentication TLVs from transient pairing errors. Explicit pairing APIs remain available.

Before the first Xcode build, install Rust from https://rustup.rs and run:

```sh
./IDeviceKitten/Native/build.sh
```

The script checks the source archive SHA-256 and builds the iPhone, Intel/Apple Silicon simulator, macOS, and Mac Catalyst slices. Generated binaries and build caches are ignored by Git. Subsequent Xcode builds use the local XCFramework. Run the script again after changing the native patch.

Native regression tests run as part of this script. Only explicit authentication rejection may invalidate a saved record; transport errors and busy/backoff responses must retain it.

## AFC upload writes

`afc-large-writes.patch` increases only write packets to 4 MiB, matching the Swift upload buffer. Reads keep their original 1 MiB limit. Every write still awaits a status response, and native errors abort the upload. Tests exercise two full packets plus a partial tail, payload integrity and an error acknowledgement that stops subsequent writes. Physical device throughput and compatibility must be measured; a fourfold reduction in requests is not a fourfold speed guarantee.


## Opt-in transfer diagnostics

`afc-transfer-diagnostics.patch` adds a separate profiled FFI write entry point used only when Debug Logs is enabled. It keeps packet sizes/order and status checking intact, returns cumulative timing/counter data even after a native error, and records no payload contents. The generated C structure mirrors Rust's `repr(C)` layout. Native duplex tests verify payload integrity, delayed-response attribution, and error handling. See `docs/install-transfer-diagnostics.md` for field definitions and measurement limits.

## Hardware AES

ARM Apple slices enable RustCrypto aes 0.8's `aes_armv8` backend at build time. The pinned cpufeatures implementation recognizes AES support on Apple ARM64; Intel slices retain their existing AES-NI runtime detection. Caller Rust flags are preserved. This changes the implementation of encryption, not the negotiated TLS cipher or protocol. Run the full native build when changing these flags; Xcode consumes the resulting XCFramework.

## TLS stream correctness and record costs

`tls-stream-optimization.patch` makes `poll_write` accept each plaintext chunk once, retains at most one encrypted record, and drains that record before accepting more data. Flush/shutdown drain outstanding bytes. A transport returning Pending must never cause the previous chunk to be encrypted and sent twice. Regression tests exercise both negotiated cipher suites, repeated Pending/partial writes, sequence numbers, flush/shutdown, zero/error writes and cached MAC correctness.

Write records reuse their allocation, AES key schedule and pre-keyed HMAC state. Protocol, cipher suites, record sizes and MAC authentication remain unchanged. Apple ARM64 enables sha2 0.10.9's `asm` feature: its SHA-512/SHA-384 backend checks CPU support at runtime and keeps the software fallback. Intel targets retain their existing backend. The pinned lockfile adds only sha2-asm 0.6.4 and its existing cc dependency.

## Continuous payload progress

`afc-upload-progress.patch` adds `afc_file_write_with_progress` on top of the existing 4 MiB writer. It reports payload bytes accepted by the socket transport, excludes AFC headers, and reserves each packet's last byte until its status reply succeeds. It keeps packet sizes, ordering, reply validation and hardware TLS unchanged. Swift receives updates at most four times per second and coalesces delivery. A blocked socket or reply produces no artificial advancement. The duplex tests cover progress inside packets, partial tails, monotonicity and failed acknowledgements that cannot report completion.

## Self-install command handoff

`self-install-handoff.patch` adds an independent FFI hook after the Install command has been fully written and flushed, before waiting for installation-service responses. Aether uses it only when installing over itself to request backgrounding without depending on percentage progress. A sent command is not proof of acceptance or success. The original install API and percentage callback remain available. Duplex tests withhold all responses until handoff, verify transmission failures never hand off, and preserve daemon errors after transmission. Swift tests retire stale/cancelled handoffs and keep progress independent.

## Bounded RSD recovery

`rsd-connection-timeout.patch` bounds native saved-pairing tunnel establishment and RSD service connection/check-in to two seconds each. The timeout drops the Rust connection future itself, so a silent service cannot indefinitely retain Swift's shared RSD lock after its four-second UI watchdog expires. Established service operations (AFC payload writes, install completion, icon reads and log streams) are not covered by this connection timeout. In-app VPN start/stop is delivered before stale RSD cleanup; startup still completes cleanup before probing the new transport. Native tests cover a stalled connect followed by a successful retry, a silent check-in that releases its stream, partial-resource cleanup and preservation of genuine service errors.

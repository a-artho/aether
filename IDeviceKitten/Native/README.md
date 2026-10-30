# Native pairing verification

Aether uses idevice v0.1.68 at commit `d32c8189c51c2789496b0768039419c3705498c3`, with the checked-in pairing-verification, AFC-write, diagnostics, TLS-stream and local-transport patches. The transitive TCP stack is pinned separately to jktcp v0.1.8 (`7df57dc59b47ec72fb5dc251fbe9344b0647246b`). The patch prevents tunnel connections from silently falling back to pair-setup, preserves authentication rejection if cleanup fails, and distinguishes authentication TLVs from transient pairing errors. Explicit pairing APIs remain available.

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

`self-install-handoff.patch` reports when the Install command has been fully written and flushed, without waiting for installation_proxy progress or a reply. LocalDevVPN self-installs retain their existing post-flush suspension. In-App VPN self-installs keep the background task and VPN alive for four seconds after the flush, then request tunnel shutdown, wait for confirmed disconnection, and only then end the task and suspend. Regular installs do not trigger either self-update handoff.

## Bounded RSD recovery

`rsd-connection-timeout.patch` bounds native saved-pairing tunnel establishment and RSD service connection/check-in to two seconds each. The timeout drops the Rust connection future itself, so a silent service cannot indefinitely retain Swift's shared RSD lock after its four-second UI watchdog expires. Established service operations (AFC payload writes, install completion, icon reads and log streams) are not covered by this connection timeout. In-app VPN start/stop is delivered before stale RSD cleanup; startup still completes cleanup before probing the new transport. Native tests cover a stalled connect followed by a successful retry, a silent check-in that releases its stream, partial-resource cleanup and preservation of genuine service errors.

## Local transport optimization

`local-transport-optimization.patch` constructs AFC write headers and payload in one preallocated wire buffer, reusing it across packets in a call. The ordinary writer and both progress variants use the same implementation. Passing a null metrics pointer to `afc_file_write_with_progress` selects lightweight progress; detailed packet/poll timing and runtime profiling run only with a metrics output. Swift passes that output only when Debug Logs is enabled. Switching logging off during an upload stops its diagnostic capture, hashing and observers at the next write boundary; progress continues. A native write already in flight finishes with its selected instrumentation mode. The separate `afc_file_write_diagnostics` entry point still requires a metrics output.

`jktcp-transport-optimization.patch` transfers owned channel buffers into `Bytes` queues and splits shared slices for segments/retransmission. The initial AsyncWrite borrowed-slice-to-owned-channel copy remains necessary. Data packets are built directly in a reusable transport buffer; checksum calculation reads the existing TCP bytes without allocating a copy. Queue consumption and sequence/unacked tracking happen before awaiting the transport. Accepted bytes and the write offset are retained until the underlying flush completes, including cancellation while TLS owns an outstanding record. Zero/error writes propagate. The network CDTunnel socket enables TCP_NODELAY.

Bounded IP batching is experimental and disabled by default. Set `AETHER_NATIVE_BATCH_IP_PACKETS=1` when building to enable up to 16 KiB of complete packets per burst on the network TLS tunnel. A single packet larger than that is sent intact. A short tail or window stall flushes immediately, with no batching timer; control packets continue to flush immediately. Packet sizes and the 1 MiB send window are unchanged. Validate both tunnel providers, cancellation, background behavior and physical-device compatibility before using this flag in release builds.

Run native tests without Xcode or cross-target installation:

```sh
AETHER_NATIVE_TEST_ONLY=1 ./IDeviceKitten/Native/build.sh
```

This downloads and checksum-verifies both pinned archives, reapplies every patch to pristine sources, runs the existing native suites plus jktcp tests with/without pcap, and tests the FFI metrics/progress paths. Two manual privileged TUN tests and the construction microbenchmark are ignored by default. Run the latter explicitly from the generated `aether-jktcp` directory:

```sh
CARGO_PROFILE_RELEASE_OPT_LEVEL=z CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
CARGO_PROFILE_RELEASE_LTO=true cargo test --locked --release --no-default-features \
aether_bulk_construction_benchmark -- --ignored --nocapture --test-threads=1
```

Set `AETHER_BENCH_BATCH_BYTES=16384` for the batching microbenchmark. It measures host packet construction and transport-write counts with immediate synthetic ACKs, excluding TLS, the VPN, device AFC and disk work; its speedups are not installation-throughput claims. See `docs/audits/2026-10-30-local-transport.md` for the source review and validation results. Rebuild the XCFramework with full Xcode before testing the app on iOS.

The same setting now controls native console logging in debug and release builds. `HeartbeatManager` reads the saved preference instead of unconditionally starting the Rust logger in debug builds, and `DebugLogManager` forwards subsequent toggle changes. Disabled startup creates no native logging worker. After enabling once, switching off reloads tracing's global filter to OFF, including its cached callsites; disabled event fields are not evaluated. Native and Swift regression checks cover off → on → off → on transitions.

## Additional speed experiments (default off)

The follow-up pipeline investigation adds two independent native build flags:

| Environment flag | Network TLS tunnel change |
| --- | --- |
| `AETHER_NATIVE_MSS_8K=1` | Cap complete inner TCP/IP packets at 8 KiB, matching upstream idevice commit `edf25870`; IPv6 TCP payload MSS is at most 8,132 bytes. |
| `AETHER_NATIVE_LARGE_SEND_WINDOW=1` | Raise the adapter's own send-window cap from 1 MiB to 4 MiB; the peer's advertised receive window still limits transmission. |

Use one at a time before combinations, rebuilding the XCFramework for each variant. The existing `AETHER_NATIVE_BATCH_IP_PACKETS=1` flag remains experimental. `AETHER_NATIVE_IOS_ONLY=1` can limit a device-only experiment to the iOS slice. These settings affect the network tunnel used by both local providers, not server-mode HTTP or USB.

A separate Swift compilation condition, `AETHER_EXPERIMENTAL_TUNNEL_MTU_8192`, sets the In-App VPN extension's outer interface MTU to 8,192 bytes. Add it to that target's Active Compilation Conditions to test. It does not change the inner CDTunnel MTU and cannot configure an external LocalDevVPN app. Normal builds leave the outer MTU unset as before.

`InstallationProxy` now drains the autorelease pool around each synchronous FileHandle read. This bounds temporary Foundation read-buffer retention while the worker blocks in native writes, without changing payload bytes or AFC packet sizes. The host reproduction verifies the complete payload SHA-256 after each pool drains.

See `docs/audits/2026-10-30-pipeline-speed.md` for the whole-pipeline investigation, dependency review, synthetic ACK/window measurements, rejected packet-boundary prototype and device test order. No on-device throughput improvement is claimed from the host measurements.

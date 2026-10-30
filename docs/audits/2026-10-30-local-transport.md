# Aether local transport: upstream review and implementation

Current implementation update: [dynamic packet sizing](2026-10-30-dynamic-packet-sizing.md) replaces the fixed-MSS experiment with default-on upstream-derived probing on local network tunnels. The IP packet-coalescing experiment described below has been removed. The measurements below describe the earlier implementation.

30 October 2026. Reviewed the supplied investigation against Aether's actual native patches, the pinned idevice source, current idevice upstream, current jktcp upstream, and the relevant installed dependency source.

The first implementation removes repeated payload/packet allocations, makes detailed native profiling opt in, and repairs two remaining cancellation cases. Experimental packet batching is implemented but disabled by default. Device throughput remains unmeasured.

## Source baseline and actual route

Aether pins idevice v0.1.68 at `d32c8189c51c2789496b0768039419c3705498c3`. Its lockfile originally selected jktcp 0.1.7. Current idevice master was `89702099f4d7552f704f93b4526756abda319ceb`; it already requests jktcp 0.1.8. Current jktcp master/tag v0.1.8 was `7df57dc59b47ec72fb5dc251fbe9344b0647246b`. The implementation retains Aether's idevice pin and existing patches, and pins/patches jktcp independently.

The local RSD upload route is:

`Swift FileHandle (4 MiB) → blocking Rust FFI → AFC Write → jktcp StreamHandle → channel → TCP adapter → IP packets → existing TLS-PSK implementation → network socket → selected VPN transport → device AFC`

The jktcp changes apply to software TCP adapters. The experimental batching flag is enabled only at the network TLS tunnel construction point, not at the USB or direct socket constructors. Packaging, server-mode HTTP uploads, signing and installation_proxy behavior are unchanged.

Primary sources: [pinned idevice manifest](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/idevice/Cargo.toml), [current idevice manifest](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/Cargo.toml), [network tunnel constructor](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/ffi/src/tunnel_provider.rs).

## What the preliminary investigation got right, and what needed qualification

| Finding | Verified result | Action |
|---|---|---|
| AFC payload copied before being copied again into serialized wire data | Confirmed in Aether's patched writer | Construct directly in one preallocated, reusable wire buffer |
| 64 KiB borrowed socket writes copied into owned channel messages | Confirmed; the background task needs owned memory | Retain this necessary copy, then transfer ownership through subsequent layers |
| Adapter copies channel bytes into VecDeque, then allocates/copies every segment | Confirmed in jktcp 0.1.8 too | Queue owned Bytes and split shared slices for segments and retransmission |
| TCP checksum duplicates every segment | Confirmed in 0.1.8 | Calculate directly over slices on either side of the checksum field, including odd tails |
| Separate TCP and IP construction duplicates payload | Confirmed | Append data packet headers/payload directly into the reusable transport buffer |
| Detailed profiling runs with logging disabled | Confirmed in current Swift: it always supplies metrics to the profiled progress function | Null output selects lightweight progress; Debug Logs supplies the metrics pointer |
| Every tunnel has roughly 1,220-byte MSS | Not established | Aether requests MTU 16,000; negotiated MTU determines actual MSS and record overhead |
| A larger send window will improve speed | Possible, not established | Preserve the 1 MiB cap and peer-advertised window |
| jktcp 0.1.8 fully solves cancelled writes | Its outbox fixes partial IP framing, but two cancellation cases remain | Upgrade and repair both cases with regression tests |

The iterator-based VecDeque operations definitely copy bytes, but their syntax alone does not establish inefficient byte-at-a-time machine code. Measurements are needed for the CPU claim. Similarly, fewer AFC requests, fewer allocations or fewer TLS records do not establish a proportional installation speedup.

Sources: [jktcp handle/channel ownership](https://github.com/jkcoxson/jktcp/blob/7df57dc59b47ec72fb5dc251fbe9344b0647246b/src/handle.rs), [TCP state/buffering](https://github.com/jkcoxson/jktcp/blob/7df57dc59b47ec72fb5dc251fbe9344b0647246b/src/adapter.rs), [packet/checksum construction](https://github.com/jkcoxson/jktcp/blob/7df57dc59b47ec72fb5dc251fbe9344b0647246b/src/packets.rs), [CDTunnel MTU and framing](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/idevice/src/tunnel.rs).

## Changes now in the repository

`IDeviceKitten/Native/jktcp-transport-optimization.patch` moves the channel's existing Vec allocation into Bytes. Segment slices and retransmission storage share that allocation. The borrowed AsyncWrite input still must be copied once before it outlives the caller. Data packet creation now writes directly into a reusable contiguous outbox. Control and retransmission packets retain their existing constructors; they benefit from the allocation-free checksum but are not the bulk hot path.

Queue consumption, sequence advancement and unacknowledged-segment tracking all happen before the transport await. A cancellation can no longer leave already-queued payload in the unsent input queue. The outbox and offset remain intact until the underlying flush completes, so cancellation after TLS accepts plaintext resumes correctly. Errors and zero writes propagate. The new cancellation tests were also injected into pristine upstream 0.1.8: both fail there and pass with Aether's patch.

`IDeviceKitten/Native/local-transport-optimization.patch` unifies the AFC write paths. Each call allocates capacity for at most one 4 MiB packet plus its 48-byte header; subsequent packets in that call reuse it. It preserves sequential AFC replies, status validation, 64 KiB socket subdivisions and the existing final-byte progress reservation. No payload is published as fully complete before its AFC reply succeeds. The network tunnel socket enables TCP_NODELAY to avoid Nagle delays for small service messages.

Swift now passes a metrics pointer only with Debug Logs enabled. The previous unconditional debug-build Rust console logger initialization is removed. Heartbeat startup reads the saved preference, and DebugLogManager forwards toggle changes to a reloadable native tracing filter. Disabled startup creates no logging worker; subsequent disabling suppresses native events and their field evaluation. Active uploads stop diagnostic clocks/counters, hashing and lifecycle/network observers at the next write boundary; an already-running native call completes in its selected mode. A stopped capture is not resumed halfway through the payload when logging is enabled again. Lightweight progress keeps its existing callback throttling; diagnostic per-poll clocks/counters and FFI queue/worker/return timings are absent from that path. With profiling enabled, `copySeconds` is zero and `serializeSeconds` includes the single payload copy into the wire buffer. The diagnostic ABI and separate diagnostics function are preserved.

`build.sh` downloads and SHA-256 verifies both immutable source archives, applies the existing patches plus the two new patches, and uses a path override in the locked dependency graph. It supports native tests without Xcode or cross-target installation. Default release optimization remains upstream's size-oriented `opt-level="z"`; hardware AES, cached crypto state, SHA acceleration, cipher suites, MTU negotiation and send-window settings are preserved.

Dependency checks: [Bytes split_to](https://docs.rs/bytes/1.11.1/bytes/struct.Bytes.html#method.split_to) supports shared constant-time slicing, and [Tokio's write cancellation contract](https://docs.rs/tokio/1.50.0/tokio/io/trait.AsyncWriteExt.html#method.write) supports persisting each successful write's offset. The pinned AES 0.8.4/cpufeatures 0.2.17 source confirms Aether already opts into the Apple ARM64 AES backend. No crypto-library migration was needed.

## Experimental batching

`AETHER_NATIVE_BATCH_IP_PACKETS=1` enables the FFI's `aether-tunnel-batching` feature. Complete data packets are accumulated up to 16 KiB and flushed immediately at a burst boundary, window stall, or short tail. Control packets flush immediately. There is no batching timer. A packet larger than the batch target is sent intact. Persistent offsets preserve framing during partial writes and cancellation.

The protocol tests verify concatenated packet framing and write counts. This remains disabled by default because the Apple peer, VPN implementations, foreground/background transitions and device cancellation behavior have not been exercised. At a negotiated MTU near 16,000, each data packet already nearly fills one TLS plaintext record, leaving substantially less opportunity than the preliminary 1,220-byte-MSS example.

## Validation

The final checked-in native test command succeeded from freshly extracted, checksum-verified sources:

```sh
AETHER_NATIVE_TEST_ONLY=1 ./IDeviceKitten/Native/build.sh
```

It passed saved-pairing/verification tests, seven AFC tests, six TLS tests covering both ciphers, self-install handoff tests, RSD timeout tests, nineteen jktcp tests under each pcap configuration, both jktcp documentation examples under each configuration, and the FFI test across metrics on/off and success/error replies. Manual privileged TUN tests and the explicit construction benchmark remain ignored by default. The optional FFI batching feature also compiled and passed its FFI test. The native logging test passed disabled-startup and off/on/off/on transitions, including an assertion that disabled event fields are not evaluated.

New checks cover ownership/pointer sharing, independent IPv4/TCP checksums, odd/even payload sizes and options, sequence wraparound, partial/Pending writes, cancellation, a pending final flush, immediate control writes behind partial data, bounded bursts, window-limited short tails and zero/error writes. AFC testing includes empty and one-byte writes, full packets plus partial tails, nonuniform payloads, progress monotonicity and failed acknowledgements with profiling both enabled and disabled.

Swift parsing passed for the complete modified file. The changed call also type-checked against the generated native C header. The existing operation-progress, installation-progress, log-history and regression-entrypoint checks passed. The log-history check now also executes the production Swift toggle bridge and active-upload shutoff helper. The native logging bridge type-checked against its generated C declaration. Full iOS app compilation and XCFramework packaging were not possible: this Mac has Command Line Tools but no full Xcode. No replacement iOS binary has been produced.

## Host construction measurement

Measured on Apple M1, Rust 1.99.1, with `opt-level=z`, one codegen unit and LTO. The same ignored harness was injected into pristine upstream jktcp 0.1.8 and run against the patched version. Each observation constructs 64 MiB of TCP/IP output in 64 KiB writes, with a sink transport and synthetic immediate cumulative ACKs. Five observations per condition; medians below. Raw observations are in `transport-construction-benchmark.csv`.

| MSS | Upstream 0.1.8 | Optimized, batching off | Experimental batching | Transport writes, upstream → batched |
|---|---:|---:|---:|---:|
| 1,220 bytes | 248.410 ms | 31.685 ms | 34.593 ms | 55,296 → 5,120 |
| 15,940 bytes | 224.968 ms | 23.547 ms | 23.505 ms | 5,120 → 5,120 |

These results support a reduction in host packet-construction CPU/memory overhead. They exclude TLS encryption, real network/VPN backpressure, device ACK timing, AFC service/disk work, FFI dispatch, Swift and packaging. The harness uses borrowed queue_send, so it does not separately measure the handle's ownership-transfer improvement. The absolute saving is roughly 0.2 seconds per 64 MiB on this host fixture; it does not predict device installation time. Batching reduces small-segment transport calls but is slightly slower here without TLS costs; this is another reason to keep it experimental.

Reproduce the patched construction benchmark after the native test build, from the generated `aether-jktcp` directory:

```sh
CARGO_PROFILE_RELEASE_OPT_LEVEL=z CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
CARGO_PROFILE_RELEASE_LTO=true cargo test --locked --release --no-default-features \
aether_bulk_construction_benchmark -- --ignored --nocapture --test-threads=1
```

Set `AETHER_BENCH_BATCH_BYTES=16384` to measure its batching path. The benchmark is included in the checked-in jktcp patch.

## Device work that remains

Build the XCFramework and app with full Xcode, then compare the previous implementation and the optimized default with the same payload, compression setting and tunnel provider. Record negotiated MTU/MSS, payload size, upload duration, process CPU, memory, thermal state, lock/background transitions and errors. Use both In-App VPN and LocalDevVPN, including cancellation and self-update handoff. Run timing comparisons with logging disabled; use separate diagnostic runs for attribution. Keep the full payload digest where available to distinguish changes in the packaged artifact.

Only then compare the experimental batching build. Keep the 1 MiB send window fixed for that comparison; test a larger window separately only if outstanding-byte/ACK measurements establish a window limit. The adapter's channels and pending payload queue are still not a general-purpose bounded-backpressure design; Aether's sequential 4 MiB upload/reply cycle bounds its current single-upload submission pattern. A global queue budget would be a separate scheduling change requiring multi-stream starvation and stalled-peer tests.

## Whole-pipeline follow-up

The follow-up review in `2026-10-30-pipeline-speed.md` covers the provided pre-change log, complete AFC/jktcp/TLS localhost tests, current upstream's 8-KiB packet cap, the outer packet-tunnel MTU, window/ACK experiments and dependency updates. It adds opt-in tuning builds and a scoped FileHandle autorelease-pool fix. No new window or MTU tuning is enabled by default. A boundary-coalescing prototype regressed a delayed-ACK case and was excluded.

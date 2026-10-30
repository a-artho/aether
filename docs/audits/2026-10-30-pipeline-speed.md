# Aether local-mode pipeline: speed investigation

Current implementation update: [dynamic packet sizing](2026-10-30-dynamic-packet-sizing.md) replaces the fixed-MSS experiment with default-on upstream-derived probing on local network tunnels. The IP packet-coalescing experiment described below has been removed. The measurements below describe the earlier implementation.

30 October 2026. This follows the first transport patch and the pre-change log `Aether-Logs-1793318847.txt`. The primary question is upload speed, not just memory or allocation count.

The investigation found concrete tuning opportunities below AFC, an additional current-upstream packet-size change, and a reproducible Foundation buffer-retention problem. It also tested and rejected a packet-boundary optimization that regressed a delayed-ACK scenario. The exact cause of the phone's 11.21 MiB/s rate is not established by the existing log; the missing distinction is time spent behind the TCP/packet-flow feedback loop versus time spent in the device's AFC service.

## What the original log establishes

One successful In-App/RSD transfer uploads 273,782,895 bytes (261.10 MiB) in 23.285 seconds, averaging 11.21 MiB/s. There are 66 AFC write packets and 66 validated replies. Wire bytes exceed payload by exactly 66 × 48 bytes, matching AFC framing. Duplicate Diagnostics entries are not counted again.

Native write calls occupy 22.294 seconds. Their internal totals include 19.743 seconds awaiting AFC replies, 2.395 seconds flushing and 0.111 seconds copying/serializing AFC packets. Local file reads take 0.183 seconds and diagnostic SHA-256 takes 0.789 seconds. Upload interval rates stay near 11.3 MiB/s; this is a steady rate, with no large upload stalls visible. The separate native-install phase is 42.114 seconds.

The 19.743-second reply counter is not pure device response latency. StreamHandle accepts bytes into a channel; its flush waits for send-command processing, which can leave bytes queued behind the TCP send window. The subsequent AFC read waits while the remainder travels through the adapter, TLS, outer TCP, VPN and device service. The 4,243 socket-write polls are not a count of IP packets or TLS records.

Removing AFC serialization alone cannot save most of 23 seconds: its measured 0.111 seconds is about 0.5% of upload time. The jktcp/TLS adapter runs independently, so its costs are not isolated by those AFC copy timers. Whole-process app CPU around 28% of one core does not rule out CPU pressure in the separate VPN extension or device service.

## The actual local route

`Swift FileHandle → synchronous FFI → AFC Write → jktcp StreamHandle/channel → userspace TCP/IPv6 → custom TLS-PSK → kernel TCP/IPv4 → packet-tunnel reflection → device remoted/CDTunnel → AFC service → staging file`

Aether's In-App packet tunnel reads outer IP packets, swaps IPv4 source/destination addresses and reinjects them. LocalDevVPN uses the same basic reflection mechanism. The reported Wi-Fi path does not make this a Wi-Fi bandwidth test, and 11.21 MiB/s being approximately 94 Mbit/s does not establish a 100-Mbit physical link cap. There are two TCP layers and a userspace VPN forwarding path to consider.

There are also two distinct packet-size settings: the inner IPv6 CDTunnel MTU/MSS and the outer packet-tunnel interface MTU. Raising or capping one does not configure the other.

Sources: [network TLS tunnel construction](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/ffi/src/tunnel_provider.rs), [LocalDevVPN packet reflection](https://github.com/jkcoxson/LocalDevVPN/blob/main/TunnelProv/PacketTunnelProvider.swift), [Apple packet-tunnel MTU](https://developer.apple.com/documentation/networkextension/nepackettunnelnetworksettings/mtu).

## Speed findings and priorities

| Priority | Finding | Practical improvement and boundary |
| --- | --- | --- |
| 1 | The In-App VPN does not explicitly set its outer MTU. Every reflected outer packet passes through NetworkExtension packet-flow callbacks and potentially Data copy-on-write. Its process CPU and packet batch sizes are absent from this log. | Test a larger outer MTU, count packets/batch sizes, and measure extension CPU. This may reduce per-packet work; current evidence does not prove it is the limiter. |
| 2 | jktcp limits in-flight payload to the smaller of its 1 MiB cap and the peer-advertised window. ACK feedback governs replenishment. | Compare 1 MiB and 4 MiB caps. A larger cap helps only when Aether's own cap is restrictive; it cannot override a smaller peer window. |
| 3 | Current upstream idevice contains a packet-size fix missing from the first pass: complete TCP/IP packets are capped at 8 KiB. | Compare the upstream cap, which gives at most 8,132 bytes of IPv6 TCP payload, against Aether's existing negotiated-MTU behavior. The commit states no performance rationale, so it is not a proven speed fix. |
| 4 | TLS work scales with records, not only bytes. Small IP packets produce more CBC/HMAC operations, IVs, allocations and write transitions. | Keep bounded batching as a separate experiment. Its benefit depends on actual MSS and record sizes, and requires Apple-peer compatibility testing. |
| 5 | The previous outer socket did not set TCP_NODELAY. | The first patch enables it. Localhost tests do not show a consistent large gain, so it should not be presented as the established reason for the phone's rate. |
| 6 | AFC requests remain sequential, with one reply per up-to-4-MiB write. | Separate actual upload drain time from post-drain AFC reply time before designing pipelining. The existing reply timer alone cannot justify it. |

Current-upstream change: [edf2587, fix(tunnel): set MSS to 8192](https://github.com/jkcoxson/idevice/commit/edf25870f5107ffce074409ee4f230bdd7e73632). It applies the cap in both network and CoreDeviceProxy constructors. Aether's first patch deliberately retained its idevice pin, and had not incorporated this change. It is now available as an independent opt-in network-tunnel variant.

The window mechanism is capable of producing rates near the logged result without any CPU saturation. For illustration, 64 KiB replenished every roughly 5–6 ms is approximately 10–12 MiB/s; 1 MiB replenished every roughly 90 ms is also approximately 11 MiB/s. These are possible mechanisms, not measurements of the phone's RTT or window.

## Layered speed fixture and results

The new fixture uses actual Tokio localhost TCP sockets, jktcp connection/channel/ACK/window handling, the patched custom TLS-PSK stream, and AFC serialization/status validation. A synthetic peer validates every payload byte and acknowledges complete AFC requests. It uploads two 4-MiB payloads per observation. It does not perform real pairing, VPN forwarding, device disk writes or installation.

Three short observations per normal condition on Apple M1, Rust 1.99.1, native size-oriented release profile and ARM AES enabled. Results below are medians from a final serial run with no other investigation builds running. They are indicative host measurements, not phone speed predictions. The constrained socket-buffer stress cases have one observation each and are not included in this table.

| Fixture condition | Payload MiB/s |
| --- | ---: |
| Normal TLS, MSS 15,940, 1 MiB cap | 177.0 |
| MSS 8,132 (upstream cap) | 170.4 |
| MSS 1,220 | 121.3 |
| MSS 1,220, bounded batching | 133.8 |
| 5 ms cumulative ACK delay, 64 KiB cap | 8.0 |
| 5 ms cumulative ACK delay, 1 MiB cap | 107.1 |
| 5 ms cumulative ACK delay, 4 MiB cap | 190.3 |
| 40 ms cumulative ACK delay, 1 MiB cap | 21.1 |
| 40 ms cumulative ACK delay, 4 MiB cap | 89.5 |

Normal TLS throughput is well above the logged phone rate; the current patched stack has no universal 11-MiB/s ceiling. Delaying cumulative ACK feedback while shrinking the send window reproduces similarly low rates. With prompt ACKs, raising the window offers no clear consistent benefit; with delayed feedback, it can matter substantially. Batching helps the small-MSS host case, while the 8-KiB cap has little benefit in this loopback fixture. None of these results identifies the active limitation on iOS.

The model's ACK timer is a deliberately configured cumulative-feedback delay. It is not an emulation of every Darwin delayed-ACK policy. The large-window/4-MiB-request combination can also be cumulatively acknowledged by the synthetic AFC status reply; do not read its result as pure TCP RTT arithmetic.

Raw observations, including a separate dependency run and the rejected prototype, are in `pipeline-throughput-results.csv`. Packet counts include TCP packets carrying AFC data and the final close request; they do not include pure TCP ACKs, TLS records, or the outer VPN's IPv4 packets.

## Dependency review

The current upstream heads were rechecked: idevice `89702099f4d7552f704f93b4526756abda319ceb`; jktcp `7df57dc59b47ec72fb5dc251fbe9344b0647246b` (0.1.8).

| Component | Checked behavior and conclusion |
| --- | --- |
| idevice AFC | Current upload helpers still stage through AFC and installation_proxy. There is no implemented faster streaming-install replacement in the examined path. installcoordination_proxy contains an install-streaming TODO, not a drop-in uploader. |
| jktcp 0.1.8 | Sliding window, peer window scaling, queued channel writes, retransmission tracking and 250-ms maintenance fallback. ACK processing triggers immediate flushing; changing the timer to 1 ms is not justified as the main speed fix. |
| Tokio 1.50.0 → 1.54.1 | Inspected I/O, cooperative scheduling, channel handling and release changes. Ran 1.54.1 with its required mio/macros dependency updates in an isolated source/lockfile copy. Normal TLS remained fast and the small-window/delayed-feedback limit remained. The checked-in dependency lock stays unchanged. |
| bytes 1.11.1; latest 1.12.1 | Existing From<Vec> ownership and shared splitting already support the first patch. The newer release does not remove application-level copies or establish a fix for this rate. |
| futures 0.3.32; latest 0.3.34 | FuturesUnordered collects send-command results. This is not a network-throughput controller. The release changes reviewed do not establish a solution to the upload limit. |
| aes 0.8.4, cbc 0.1.2, hmac 0.12.1, sha2 0.10.9, cpufeatures 0.2.17 | The custom outer TLS uses these directly; swapping the rustls AWS-LC/ring provider does not replace this CBC/HMAC data path. Aether already enables ARM AES and the runtime-detected SHA-512/SHA-384 path. Newer AES/SHA major versions require a coordinated cipher/digest API migration and benchmarking, not a blind version bump. |
| Swift Foundation | The synchronous file-read/native-write loop retains autoreleased read buffers on the host until its pool drains. This was reproduced and fixed with a small scoped pool around each read. |
| SwiftNIO/Vapor/HTTP libraries | Present in workspace dependencies, but not on this local AFC/RSD bulk-send route. Updating them is not a targeted fix for this transfer. |

Primary references: [jktcp handle loop](https://github.com/jkcoxson/jktcp/blob/v0.1.8/src/handle.rs), [adapter window and ACK logic](https://github.com/jkcoxson/jktcp/blob/v0.1.8/src/adapter.rs), [Tokio changelog](https://github.com/tokio-rs/tokio/blob/master/tokio/CHANGELOG.md), [bytes changelog](https://github.com/tokio-rs/bytes/blob/master/CHANGELOG.md), [futures 0.3.34](https://github.com/rust-lang/futures-rs/releases/tag/0.3.34), [AES changelog](https://github.com/RustCrypto/block-ciphers/blob/master/aes/CHANGELOG.md), [SHA-2 changelog](https://github.com/RustCrypto/hashes/blob/master/sha2/CHANGELOG.md).

One useful detail: Tokio's bare TcpStream flush is a no-op. The expensive wait in Aether's AFC flush counter is the higher-level channel/adapter/TLS work, not an expensive kernel flush syscall for each AFC packet. TLS buffering and record draining still matter. [Tokio 1.50 source](https://docs.rs/tokio/1.50.0/src/tokio/net/tcp/stream.rs.html).

## Rejected boundary-coalescing prototype

The owned-buffer queue can leave short segments at message boundaries. A prototype filled segments across already-queued buffers while retaining shared slices on the contiguous path. Its correctness test covered payload ordering and send-window limits. It reduced packet count in a delayed-ACK case, but slowed that scenario from roughly 101–112 MiB/s in controls to roughly 67 MiB/s. Normal prompt-ACK cases were essentially unchanged. It is excluded from the production patch. The research diff is saved separately as `transport-boundary-coalescing-prototype.patch`.

This is why minimal copying, fewer packets and higher throughput must be checked separately: a packetization change also changes cumulative ACK/window replenishment patterns.

## Changes made available

The previous cancellation, ownership, packet-construction, hardware-crypto and logging fixes remain. This follow-up adds:

- A scoped autorelease pool around each FileHandle read in the upload worker. In the 256-MiB host reproduction, end-of-loop RSS changed from about 259 MiB without a pool to about 19 MiB with one; the complete SHA-256 matched the input in both cases. This supports a temporary-buffer retention diagnosis, not a proven device leak or a claimed large speedup.
- `AETHER_NATIVE_LARGE_SEND_WINDOW=1`: compile an experimental 4-MiB adapter cap for the network TLS tunnel.
- `AETHER_NATIVE_MSS_8K=1`: compile the upstream 8-KiB complete-packet cap for that tunnel.
- `AETHER_EXPERIMENTAL_TUNNEL_MTU_8192`: a Swift compilation condition for the In-App extension that sets its outer MTU to 8,192.
- A reproducible host pipeline fixture and raw measurements. The Tokio upgrade and boundary-coalescing prototype remain outside the checked-in dependency/default implementation.

All three new tuning controls default off. The inner variants affect the network TLS tunnel used by both local providers. The outer-MTU condition affects only Aether's own extension. Logging remains opt in; the new memory fix does not enable instrumentation.

## Exact device test order

1. Build the current default and upload the same packaged payload with logging off. Measure upload wall time, not total installation time. Keep app/version, compression, provider and foreground state fixed.
2. Compare the 4-MiB send-window build alone. A faster upload supports a self-imposed flight cap; no change may mean the peer window or another layer dominates.
3. Compare upstream's 8-KiB packet cap alone. Then compare it with bounded TLS batching if the Apple peer passes compatibility/cancellation tests.
4. Compare the In-App outer-MTU build alone. Record outer packet lengths, batch sizes, reflection failures and extension CPU before attributing an improvement to lower packet overhead.
5. Use separate opt-in diagnostic runs to record actual inner MSS, peer receive-window/scale, bytes in flight, window-stalled time, ACK gaps, TLS record sizes, outer socket blocking and time between actual payload drain and AFC status. These are not present in the original export, so it cannot uniquely select a bottleneck today.

For example, on a Mac with Xcode, from the repository root:

```sh
# Restore/build the normal native baseline:
AETHER_NATIVE_IOS_ONLY=1 ./IDeviceKitten/Native/build.sh

# Separate experiment, then rebuild the app:
AETHER_NATIVE_IOS_ONLY=1 AETHER_NATIVE_LARGE_SEND_WINDOW=1 ./IDeviceKitten/Native/build.sh

# Separate experiment, then rebuild the app:
AETHER_NATIVE_IOS_ONLY=1 AETHER_NATIVE_MSS_8K=1 ./IDeviceKitten/Native/build.sh
```

Set `AETHER_EXPERIMENTAL_TUNNEL_MTU_8192` in the AetherTunnel target's Active Compilation Conditions for the outer-interface experiment. Rebuild the ordinary configuration between variants; otherwise the most recently generated XCFramework remains selected. Keep the external LocalDevVPN implementation fixed when testing native variants.

## Reproduction and validation

The delivered `reproduce-pipeline.py` copies a source tree already prepared by Native/build.sh to a new scratch directory, adds the delivered Rust fixture, and runs the ignored release test. It does not replace the input tree or contact an iOS device. Keep it beside `pipeline_speed_bench.rs`.

```sh
# Prepare pinned, patched native sources and run native tests without Xcode:
AETHER_NATIVE_TEST_ONLY=1 ./IDeviceKitten/Native/build.sh

# From the directory containing the delivered probe files; supply the prepared
# idevice-d32c8189... directory as SOURCE and a new scratch directory as --work:
RUSTFLAGS='--cfg aes_armv8' python3 reproduce-pipeline.py SOURCE --work work/probe
```

The ARM flag above is for the Apple ARM64 host used here. Preserve appropriate flags for another host. `--cases tls,delay5ms_window64k,delay5ms_window1m` limits the probe. Every payload is synthetic 0x5a data; complete AFC responses and sequence ordering are validated. Failed/timeout cases fail the final fixture test rather than being counted as successful observations.

Validation passed: fresh checksum-verified native source build and all existing native suites; FFI tests with the three native experiment features enabled; logging-toggle/progress/history regressions; the full host pipeline matrix; a matched Tokio-update experiment; full-digest read-buffer reproduction; the delivered runner smoke test; Swift parsing and macOS SDK type-checking of the tunnel provider with and without its experimental condition. Full iOS packaging and device tests remain unavailable on this Mac because full Xcode is not installed.

For scale: doubling this upload rate would save roughly 11.6 seconds in the recorded attempt. It would leave the separate 42.1-second iOS installation phase. The current investigation is aimed at those upload seconds, with no claim that native installer internals have been accelerated.

# Dynamic local-network packet sizing

30 October 2026. This replaces the earlier fixed-MSS and IP-coalescing experiments. It changes the ordinary native build; no opt-in is required. It does not establish an iPhone throughput improvement.

## Upstream behavior carried over

The reference is pymobiledevice3's [merged integration PR #1779](https://github.com/doronz88/pymobiledevice3/pull/1779), pmd-pytcp's [probing-mode fixes in PR #5](https://github.com/doronz88/pmd-pytcp/pull/5), and these immutable implementations at `80628207dde459b305a262f98596328e405f32bd`:

- [PmtuSearch](https://github.com/doronz88/pmd-pytcp/blob/80628207dde459b305a262f98596328e405f32bd/packages/pmd_pytcp/pmd_pytcp/lib/plpmtud.py).
- [TCP ACK/retransmission adapter](https://github.com/doronz88/pmd-pytcp/blob/80628207dde459b305a262f98596328e405f32bd/packages/pmd_pytcp/pmd_pytcp/protocols/tcp/tcp__plpmtud_adapter.py).
- [pymobiledevice3 tunnel configuration](https://github.com/doronz88/pymobiledevice3/blob/d98fb4154855738101f39fb104bad988983aa373/pymobiledevice3/remote/userspace_tunnel.py#L75-L154).

Working IPv6 packets start at 1,400 bytes, or 1,340 bytes of TCP payload, additionally bounded by the peer MSS. Fresh regular data confirms base connectivity. The search uses an 8-byte-aligned binary midpoint; only one candidate probe is outstanding. A candidate needs three consecutive successful probe deliveries before becoming the working size. Probe failure resets the validation streak and narrows the search. The ceiling is the smallest of negotiated MTU, pymobiledevice3's 16,000-byte interface limit and peer MSS plus headers, not a hardcoded 8 KiB value.

Probes carry real application bytes and require sufficient queued data and receive-window credit. Their sequence ranges are recorded before the transport await. Cumulative ACKs validate them only after the ACK has been checked against actual sent sequence space. Overlapping retransmissions invalidate the original probe before a smaller repair can be ACKed. Unrelated repairs leave it alone. An RTO at a raised working size restores the safe seed and searches below the revoked size; late ACKs cannot restore it. Three consecutive failed probes put the search in its safe fallback/error state. The probe deadline is 1.5 seconds, the initial data RTO remains 200 ms with existing backoff, and completed/error searches can reopen after 600 seconds.

## jktcp integration

The new module and attribution are included in `jktcp-transport-optimization.patch`. It is a Rust adaptation of the referenced probing-mode logic, not an import of the entire Python stack. The generated package retains upstream jktcp's MIT notice, adds the GPL-3.0-or-later module notice/license, and declares both licenses.

jktcp still uses its own head retransmission machinery. It does not acquire pmd-pytcp's complete RACK/TLP, SACK, congestion-control or ICMP stack. A guarded three-duplicate-ACK repair accelerates probe-hole recovery; repeated old duplicate ACKs cannot repeatedly retransmit the same head before progress. Fixed-cap sending reserves sufficient credit for an eligible probe instead of endlessly filling the window with smaller packets. Short service writes and windows smaller than a candidate continue without waiting for a probe.

Outstanding payload uses shared `Bytes` slices. Repair resegments the live unacknowledged range at the current size without advancing send sequence space or counting those bytes twice in flight. Pending repair pieces survive cancellation and obey a smaller/zero receive window. A sent head can time out again while its unsent repair tail waits for credit. Partial ACKs trim only acknowledged bytes. SYN-ACK windows are unscaled; subsequent advertisements use the negotiated scale. Malformed TCP data offsets, out-of-range ACKs and ACKs from another peer port cannot validate probes. Maintenance uses remaining deadlines so unrelated traffic cannot continually postpone recovery.

The network TLS constructor in `ffi/src/tunnel_provider.rs` enables this behavior for both local providers. Other adapters keep static sizing unless explicitly enabled. The normal 1 MiB send cap, negotiated receive capability, outer VPN MTU, AFC 4 MiB framing, crypto suites and logging toggle are preserved.

## Packet boundaries and retired experiments

pymobiledevice3 documents [USB forwarding failures when inner packets are concatenated](https://github.com/doronz88/pymobiledevice3/blob/d98fb4154855738101f39fb104bad988983aa373/pymobiledevice3/remote/tunnel_service.py#L311-L327). The coalescing implementation and Cargo feature are removed. A control packet first finishes a pending partial write and flush, then starts its own write. New data and retransmissions also keep separate packet boundaries. This gives one inner packet per TLS plaintext record for the supported negotiated sizes in the functional tests; TCP beneath TLS remains a byte stream, so kernel read boundaries cannot be guaranteed.

The old `AETHER_NATIVE_BATCH_IP_PACKETS=1` and `AETHER_NATIVE_MSS_8K=1` settings now fail with an explicit build error. The separate larger-window and outer-VPN-MTU experiments remain disabled by default. The GitHub release workflow uses the ordinary native build and therefore includes dynamic sizing when these changes are committed and built.

## Validation and remaining device work

The build script extracts both checksum-verified source archives, applies the checked-in patches and runs the tests. Coverage includes:

- A 50-transition trace produced by the unmodified pinned Python search engine; Rust matches working size, candidate, phase, both search bounds, validation count and consecutive-loss count at every step.
- Three-ACK validation, failed validation streaks, probe expiry, periodic recovery, sequence wraparound, overlapping versus unrelated repair, safe-seed demotion and stale ACK rejection.
- Full payload delivery with 1,400-byte, 8,192-byte and 16,000-byte path limits, plus a limit that shrinks mid-transfer.
- Peer MSS/receive capability, partial/zero receive windows, partial ACKs, duplicate-ACK storms, retry limits, partial/Pending/zero/error writes and cancellation during retransmission/control writes.
- AFC payloads crossing the 4 MiB write boundary through the actual background adapter, localhost TCP sockets and both production TLS ciphers. The peer checks every payload byte, AFC sequence/status, authenticated TLS records and one inner packet per record while injecting oversize loss and path shrink.
- Existing pairing, AFC, TLS, installation handoff, timeout, FFI progress and logging suites; jktcp with and without pcap.

These are functional host checks, not new throughput-tuning experiments or measurements of Apple's forwarding implementation. Full Xcode is absent on this Mac, so it cannot produce or validate a replacement iOS XCFramework/IPA. Rebuild with full Xcode or the existing GitHub workflow, then compare the same payload on both local providers and check sustained transfers, cancellation and background/foreground behavior on an iPhone. The upstream USB throughput gain is not an Aether-local speed claim.

## Source-review follow-up: no tests rerun

The follow-up compared the current upstream engine and TCP adapter again. Their Git blob hashes still match the pinned reference (`0704273e2a9f614352ed88afd223d1d6baa96255` and `18a37a0709123e8fb21468188349cb177bcf6cb7` respectively). The corrections are in Aether's integration, rather than a changed upstream search algorithm.

| Finding | Correction |
| --- | --- |
| A pending repair tail can retain the larger size used before a later RTO demotes the working size. The earlier split alone did not constrain the tail when it eventually became writable. | Reapply the current MSS when emitting every pending repair piece, while retaining its sequence range, shared payload storage and pending count. |
| A zero receive window can leave queued data or repair pieces waiting indefinitely if the peer's reopening advertisement is lost. The simplified jktcp integration had no persist mechanism. | Adapt pmd-pytcp's [one-byte TCP persist policy](https://github.com/doronz88/pmd-pytcp/blob/80628207dde459b305a262f98596328e405f32bd/packages/pmd_pytcp/pmd_pytcp/protocols/tcp/session/tcp__session__tx.py#L630-L680): first probe at 1 s, doubling to 60 s. A fresh byte is consumed once and subsequent probes retransmit it. Persist does not exhaust ordinary data retries. Reopening clears persist and duplicate-ACK state and restarts ordinary timing; flow-control delay is not treated as evidence of an MTU black hole. |
| The inherited background driver discarded errors returned by ACK-triggered and maintenance-triggered flushes; send-message failures also needed consistent notification of other streams sharing the failed transport. | Propagate shared transport failures to every active stream and stop the driver. Fatal cleanup drops the transport instead of awaiting further FIN writes on it. |
| The network constructor accepted the returned MTU without pymobiledevice3's explicit 16,000-byte interface ceiling. Larger values could put one IP packet across multiple TLS records. | Bound the local network interface to `min(returned_mtu, 16000)`, matching upstream's documented interface limit and keeping it below the 16,384-byte TLS plaintext limit. |

Additional source regressions cover an old repair tail after a subsequent demotion and repeated one-byte persist probes without consuming the application byte twice. These cases were compiled but not executed. Compile-only checks passed for the stack with regression sources and pcap, and for the full native FFI configuration. Patch application and whitespace checks were performed. No test suite was rerun, as requested. The previously recorded runtime test results describe the implementation before these follow-up corrections; they must not be presented as execution evidence for the corrected code.

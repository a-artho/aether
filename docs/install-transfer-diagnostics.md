# Local install transfer diagnostics

These diagnostics are permanent and opt in through Settings → Debug Logs → Enable Logging. They appear under **Install Transfer** in Diagnostics and its export. There is no separate performance switch. Install and export packaging both honor the existing Archive & Compression setting (Default if unset). Compare runs using the same compression level. The local install path keeps its existing buffer size, priority and progress behavior for a comparable baseline.

Every attempt uses the installation generation as `transfer[UUID]`, also included in background expiration diagnostics. The initial entry records the app/version and selected tunnel provider. No IPA contents, pairing credentials or file paths are logged.

The upload records monotonic elapsed times, packaged payload bytes, successful written bytes, attempted Swift chunks, file-read time, total native `afc_file_write` duration, total time awaiting main-actor progress publication, and the longest write/progress wait. Samples are emitted at most once per five seconds, after a chunk completes. Counters and clock reads do not dispatch to the main actor. Log delivery is asynchronous and never awaited by the upload. Logging disabled creates no diagnostic object or lifecycle observers.

Phase boundaries distinguish setup, upload, AFC close, installation-proxy connection, native installation, and completion. Failed or cancelled attempts emit their partial counters when the worker unwinds. A blocked native write cannot emit a sample until it returns; no sample does not itself mean failure. If iOS kills the process, a final summary cannot be guaranteed.

Lifecycle entries record active/inactive/background state and protected-data availability changes, with thermal state and initial Low Power Mode. Protected-data unavailability is evidence about data protection, not an exact screen-lock timestamp: iOS may delay that notification or keep protected data available. A sample interval can span lifecycle changes; use the lifecycle timestamps rather than attributing the whole interval to the state at its end. Background expiration entries distinguish an actual continued-task expiration from the fallback timer.

`nativeWriteSeconds` includes the entire native call (transport, protocol responses, native scheduling and copies). `progressAwaitSeconds` includes main-actor scheduling, property publication, its synchronous subscribers and worker rescheduling after the await; it is not exclusively queue wait. These are non-overlapping, separately measured portions of the upload, not guesses based on total installation time. The residual upload wall time includes scheduling and other work. `MiBps` uses 1,048,576 bytes per MiB.

The native dependency is pinned in `IDeviceKitten/Native/build.sh` to idevice v0.1.68, commit `d32c8189c51c2789496b0768039419c3705498c3`. With `afc-large-writes.patch`, its `InnerFileDescriptor.write` uses up to 4 MiB per write packet, and each `send_packet` still awaits `client.read()` after sending. Reads remain limited to 1 MiB. With `afc-transfer-diagnostics.patch`, schema 2 additionally measures the internal costs described below.

For comparison, install the same app/version and use the same tunnel provider for a foreground run and a locked-phone run. Export Diagnostics after both attempts. Compare payload bytes, upload wall time, native-write versus progress-await totals, lifecycle boundaries and native-install duration. If needed, repeat with the other provider while keeping the payload unchanged.


## Schema 2: one complete capture

The existing logging toggle enables the profiled native entry point; logging disabled calls the original `afc_file_write`. Both paths preserve the 4 MiB packet size, 64 KiB socket subdivisions, sequential replies, validation, and cancellation boundaries. Profiling changes no transfer setting and introduces no retry or pipelining.

Native counters returned per Swift write are aggregated into the existing five-second samples and final summary:

- `runtimeQueueSeconds`: submitting the FFI work to its first execution on the Rust runtime. `runtimeReturnSeconds`: worker completion to return to the blocking FFI caller. `workerSeconds`: worker wall time.
- `copySeconds` and `serializeSeconds`: payload/header copies and construction of the wire packet.
- `socketWriteSeconds`: time writing the wire packet, including asynchronous waits, encryption, and scheduling. `flushSeconds`: subsequent flushing. `replySeconds`: waiting for and parsing/validating the AFC response. Failed calls retain completed and partial timing counters.
- `socketPollSeconds` / `maxSocketPollSeconds`: synchronous work inside socket write polls; includes whatever the underlying transport performs within those calls. These are nested within `socketWriteSeconds`, not additional time to add to it. Socket ready/pending poll counts and flush ready/pending poll counts indicate backpressure/wakeup activity, not TCP packet or retransmission counts.
- `nativePackets`, `validReplies`, and `wireBytes`: attempted packets, successful validated replies, and bytes accepted by the local writer. Accepted bytes are not independently acknowledged device disk writes. `maxReplySeconds`, `writeBuckets`, and `replyBuckets` summarize per-call latency with fixed bounds: <10 ms, <50 ms, <250 ms, <1 s, <3 s, >=3 s. Each upload call normally contains one 4 MiB packet.

Resource samples include process CPU delta, elapsed interval, CPU percentage (100% means one core), resident memory, thermal state and Low Power Mode. CPU/memory belong to Aether's whole process, including concurrent work; they do not measure LocalDevVPN's process or iOS's installation service. Network path logs identify interface types and expensive/constrained availability without recording addresses; the system's reported path does not establish the exact route of every tunnel packet.

The manager logs move/preparation and packaging duration, compression setting, provider and packaged size. The worker records the actual legacy/RSD connection family. SHA-256 is accumulated from the upload's existing read buffers with separate `hashSeconds` overhead, and emitted only for a fully successful upload. It reads no extra copy of the IPA. A different digest can result from signing/ZIP metadata as well as content changes; compare app/version, byte counts and compression too.

This capture separates local copying, runtime dispatch, socket sending/flush and response latency, alongside CPU/memory and lifecycle events. Awaited durations still include task rescheduling; response latency may include remote service/disk work. It cannot inspect VPN-internal queues, TCP retransmissions or remote CPU/disk costs. There are no timers or per-packet logs; notification-driven lifecycle/network entries supplement the bounded upload samples.


For the RSD/jktcp path, `socketWriteSeconds` measures acceptance into the adapter's send queue. Its `poll_flush` waits for queued send commands to be handled; a command can finish with bytes still buffered behind the TCP send window. Consequently `replySeconds` can include draining outstanding IPA bytes through the tunnel before the AFC response arrives. It must not be interpreted as pure per-request round-trip overhead, nor as time that pipelining would necessarily eliminate. The process CPU sample also includes this independently running adapter task.


## Packaging and repeat installs

Packaging uses a bounded 256 KiB input buffer and checks each archive open/write/close result. Cancellation is checked between input chunks and files; incomplete output is removed. Install and export use the configured compression level. Progress publication is capped to one update per 125 ms, plus completion.

Install packaging can reuse one completed IPA persisted in Caches. Its key includes sorted relative names, file modes/timestamps, file contents, link targets and compression. Directory timestamps are normalized because cloning into a fresh work directory can change them without changing app content. A checksum also verifies the cached IPA before cloning it into the private install directory. Changes, corruption or unavailable cache storage rebuild the package; exports always build fresh. Cache hashing is bounded in memory but adds a complete input read on a miss and input/package reads on a hit, so measure end-to-end packaging time rather than assuming free reuse. Cache hit/miss is logged with the existing logging toggle. No timer or background cache maintenance is added.

## Archive extraction path aliases

Normal imports, downloads and direct updates share SafeIPAArchive. Foundation can resolve an existing aliased output directory while leaving a not-yet-created child in the alias spelling. Comparing their strings incorrectly rejects a safe child. Extraction now walks relative archive components from an open root-directory descriptor with mkdirat/openat and O_NOFOLLOW, creates each file exclusively and sets permissions on its descriptor. Archive traversal/link checks, byte limits, CRC validation, cancellation and failure cleanup remain in place. Regression tests cover aliased parents and a parent replaced with a symlink during extraction, in addition to malformed archives.


## Native download execution and presentation

Background URLSession owns file transfers. A foreground download, resume, or restart submits a native continued-processing task before awaiting queue persistence. That task owns the system progress UI through download and import. There is no custom download Live Activity extension or foreground/background presentation handoff. Legacy ActivityKit attributes remain only to dismiss activities created by older builds.

Every execution attempt gets a unique scheduler identifier. Late delivery after cancellation/completion is finished using that attempt's completion state, without attaching to a retry. Progress uses one million units, so changes smaller than one percent remain measurable; network publication is throttled to once per second and completion. Extraction reports its existing bounded progress updates. Native progress represents the existing weighted download/import operation, and success is reported only after import commits.

A native expiration (including cancellation from its UI) pauses the network transfer and stores resume data; it does not leave a download running behind a failed task display. Non-resumable servers require Restart. Processing interruption retains the staged IPA for recovery. Denied submissions and restored background completions can use finite UIKit execution time, without creating another progress UI; iOS does not guarantee grants or continuous locked-screen updates. Cancellation during persistence rechecks transfer identity and phase before resuming any URLSession task.

Signing logs include phase duration, native/fallback execution ownership, and interruptions. Native signing's boolean return is checked even if failure occurs before its completion callback. No signing-key data is logged or file protection weakened.

Regression tests exercise production methods with controlled scheduler/network/native dependencies, including background progress callbacks, quick backgrounding, resume-position preservation, cancellation during persistence, late callback isolation, processing interruption, and native signing failures. They do not prove physical-device execution grants or Lock Screen rendering; those require a real locked-phone run.

## Update discovery without automatic installation

Available updates retain the source app row and details view. Their normal cloud-download control starts an ordinary download, with shared pause/resume/retry progress. Completion imports the app into Library for manual signing and installation. There is no Update intent, automatic signing gate, certificate/team override, signing recovery transaction or download-to-install task adoption. Old saved queue records may contain an `automaticUpdate` JSON field; decoding ignores that retired field and the next persisted snapshot omits it. Download identity, resume data and staged/imported input continue to use the existing recovery path.

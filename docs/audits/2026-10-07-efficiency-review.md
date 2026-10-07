# Aether efficiency review — 7 October 2026

This is a code-based review of the current working tree. It is not a device performance capture. The opportunities below have observable code evidence; their latency, CPU, battery, and memory savings have not been measured. No additional optimization changes or release were made as part of this review.

## Six previously reported issues corrected

- Library deletion now resolves the database record by UUID and signed/imported type, including when the caller supplies a value snapshot after signing.
- Forced tunnel shutdown supersedes a connecting transition. Pending embedded startup checks ownership before starting or reporting completion, including its configuration-repair path. Stale LocalDevVPN callbacks cannot cancel the newer transition.
- Successful uninstall invalidates an in-flight installed-app refresh before removing the row, so pre-uninstall results cannot restore it.
- Modern source screenshots decode string URLs, URL objects, mixed arrays, and iPhone/iPad groups. Detail pages prefer device-appropriate screenshots and retain the legacy fallback.
- Certificate highlighting follows the same stable UUID preference as signing, with the existing index fallback preserved.
- Export filenames include the operation UUID so simultaneous exports with identical app names and versions cannot collide.

Validation: production-method probes exercise real Core Data snapshot deletion, retained signed/unrelated records, active-operation protection, forced disconnect, interrupted tunnel startup, stale tunnel completion, uninstall/refresh ownership, certificate selection after insertion, mixed screenshot formats, and export filename uniqueness. Existing release Swift and Mach-O checks pass, and changed Swift files pass syntax parsing. Full app build and iPhone runtime verification remain unperformed: this host has Command Line Tools, not Xcode.

## Further findings and recommended order

### 1. Fix the icon cache-hit race

Evidence: `Aether/Views/Common/FRAppIconView.swift:91`. A cache hit assigns the new image and returns before cancelling the old render task. That old task can finish and overwrite the new image. This can also waste rendering after the requested appearance changes.

Recommendation: cancel/retire the previous request before handling a cache hit, and guard publication with the requested icon identity. Test a delayed old render followed by a cached new appearance. This is a correctness fix with an efficiency benefit, not a speculative speed tweak.

### 2. Bound catalog memory and remove obsolete source entries

Evidence: `Aether/Backend/Observable/SourceRepositoryService.swift:34` retains both normalized manifest bytes and decoded models in an unbounded URL-keyed dictionary. `Storage+Sources.swift:108` deletes the database source without evicting that service entry. The list projection and prepared-list caches are bounded by counts, not catalog size, and can retain additional references to old catalog graphs.

Recommendation: evict removed sources across the service/list/update indexes, and use a size-aware memory budget with disk restoration for inactive sources. Preserve active views and shared in-flight fetches. Swift arrays use shared storage; this is not a claim that every row makes a deep copy of the entire repository.

### 3. Reuse completed packages for reinstall and retry

Evidence: `AppInstallationManager.swift:409–425` creates a new private payload snapshot and archives it for every transport installation. `ArchiveHandler.archive()` enumerates and recompresses the app each time. An unchanged signed app is packaged again when reinstalled or retried.

Recommendation: consider a bounded disk package cache keyed by the library artifact identity/revision and compression setting. Publish only fully completed packages, pin them while in use, and invalidate on artifact replacement/deletion. Do not reintroduce full-file hashing on every lookup merely to validate this cache. This improves preparation and retries; it does not reduce the network transfer time for a first installation.

### 4. Reduce copies in AFC packet construction without altering its protocol

Evidence: `IDeviceKitten/Native/afc-large-writes.patch` still converts a payload slice into an owned vector; the diagnostic path also serializes that payload into a wire buffer (`afc-transfer-diagnostics.patch:95–109`). Swift reads another bounded 4 MiB buffer before calling the native writer.

Recommendation: investigate reusable packet buffers or borrowed payload serialization that preserves framing, sequence numbers, ordering, and acknowledgement checks. Keep the current 4 MiB limit until measurements justify changing it. Use existing copy/serialize/socket/reply diagnostics to establish whether this cost matters. No evidence here supports blindly skipping acknowledgements or parallelizing writes on one AFC connection.

### 5. Reduce repeated installed-app reloads on foreground return

Evidence: `AetherApp.swift:49` refreshes installed apps on every foreground transition; `InstalledAppsStore.refreshOnForeground()` performs a full refresh whenever connected. Returning from a helper app can therefore browse the device and fetch fallback profiles even when the installed-app set has not changed.

Recommendation: use a short freshness policy plus explicit invalidation after install, uninstall, pairing/device changes, and manual refresh. Keep loading on initial connection and force-refresh controls. Device changes outside Aether require eventual revalidation, so this cannot become an indefinite cache.

### 6. Reduce repeated description searches

Evidence: `SourceAppListStore.swift:128–138` scans several fields on every query, including both raw and localized descriptions. It already does this off the main actor and checks cancellation.

Recommendation: derive reusable search fields once per catalog revision, preserving localization and matching behavior; consider a small debounce if runtime typing traces show repeated wasted scans. Measure the memory trade-off before retaining another normalized copy of every long description. Actor isolation protects UI responsiveness but does not eliminate CPU work.

### 7. Avoid inspecting the same import archive twice unnecessarily

Evidence: `AppFileHandler.prepare():51–64` inspects the source archive, clones/copies it into private staging, clears the inspection, then scans the staged archive again. This repeats central-directory work; the clone itself is already optimized for APFS.

Recommendation: where source stability can be established, reuse the inspection for the verified private snapshot. Retain a fallback for externally mutable inputs and preserve space/error handling. Do not remove snapshotting merely to save a cheap clone.

### 8. Keep diagnostics optional and distinguish their cost

Evidence: `InstallationTransferDiagnostics.recordPayload()` hashes every uploaded byte when debug logging is enabled. It also collects native timings and network/lifecycle events. The installer does not construct these diagnostics when logging is disabled.

Recommendation: retain the useful logs as requested, but separate lightweight stage/resource timing from optional full-payload fingerprinting if measurements show hashing overhead. Benchmark with logging both on and off. No claim is made that diagnostics are the current transfer bottleneck.

## Existing decisions worth preserving

- Native background URLSession owns download transport; Aether does not need to stay running merely to download bytes.
- Import processing, signing, packaging, and device installation still require app execution time. Completion of a background download is not completion of these later stages.
- Native ARM64 builds explicitly enable the AES ARMv8 backend. The earlier software-AES configuration mistake is not present in the reviewed build script.
- TLS record buffers and AES/HMAC schedules are reused; do not weaken or remove negotiated encryption for a presumed speed gain.
- Packaging streams through a bounded 256 KiB buffer, honors compression settings, and supports cancellation.
- Progress delivery is coalesced/throttled; installation progress polling is 300 ms rather than a busy loop.
- Catalog decoding/list preparation run away from the main actor; identical response bodies preserve decoded identities, and HTTP 304 does not rewrite the full disk catalog.
- Icon request deduplication, bounded image caches, and a reused SpringBoard connection already exist. The connection closes after an idle delay.
- Queue completion/failure releases its execution lifetime and server audio requester. I found no unconditional idle audio loop in that path. This does not establish zero background CPU: retained VPN connections, spoofing, and diagnostics can still perform intentional work.

## Device validation needed before promising gains

Use a Release build on the same phone and app payload. Compare first install and unchanged reinstall, with logging disabled and enabled. Record packaging duration, compressed bytes, AFC copy/serialization time, socket-write time, acknowledgement wait, installation duration, peak resident memory, and thermal state. Compare foreground, background-unlocked, and locked runs separately. For UI, use the same large sources and capture typing and scrolling plus foreground-return reloads. Internet download time and local tunnel upload time must be measured separately.

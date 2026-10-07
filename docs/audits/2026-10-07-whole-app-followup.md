# Whole-app follow-up audit — 7 October 2026

Read-only production-code review of the current working tree, including the pending loading, cache, import, icon, and transport changes. No production fixes were made during this review. Findings below describe code behavior; runtime timing and callback ordering have not been measured on an iPhone in this audit.

## Correctness priorities

### 1. Restored downloads can lose early callbacks

`DownloadManager.swift:500` asynchronously enumerates background session tasks, then dispatches another main-queue block before attaching them to saved download records. The delegate methods at lines 945, 1000, and 1072 find a record by transfer identifier but also require exact `download.task` identity. Before restoration attaches the task, that property is nil and those callbacks return. A completion delivered in that interval would not preserve its temporary downloaded file. This is a code-level race; its frequency and actual callback order need a cold-relaunch device test.

Fix direction: reconcile a legitimate restored attempt before processing its callbacks, while retaining protection against stale callbacks from retries. Do not simply remove the task identity checks.

### 2. Lightweight app browsing accepts incomplete decoded results

`InstallationAppProxy.swift:58` accepts any nonempty decoded array whose remaining entries have identifiers. `decodeApps` at line 85 uses `compactMap` to skip null or undecodable entries. Consequently, a browse returning ten entries with one decode failure can be accepted as nine entries without activating the full Lookup fallback.

Fix direction: return decode completeness alongside the array and use the compatibility fallback when the lightweight response loses entries. Distinguish a partial full Lookup result from an authoritative complete list.

### 3. Library search does not filter Downloads or Exports

`LibraryView.swift:58–78` filters Signed and Imported only. Its sections render every download and export at lines 99–118, and any such entry suppresses the no-results placeholder regardless of the query. This makes the same search field behave differently across sections.

Fix direction: consistently filter all searchable Library sections and derive the empty result state from those filtered collections.

### 4. Deletion reports success even when persistence fails

`Storage+Shared.swift:26` suppresses filesystem deletion errors and ignores the error returned by `saveContext`. It can report successful deletion while files remain or after files have been removed but the database save failed. The active-artifact protection also excludes exports, whose initial snapshot copy can still require the original files.

Fix direction: include active exports in artifact ownership; handle and log deletion/save failures explicitly, with a recoverable ordering rather than reporting success unconditionally.

### 5. Description expansion uses the wrong measurement

`ExpandableText.swift:112` measures an already line-limited copy of the text, compares it with font line height while ignoring added line spacing, and checks only on appearance. This cannot reliably determine truncation and does not respond to width or Dynamic Type changes.

Fix direction: compare constrained and unconstrained rendered sizes and recompute when their sizes change.

## Efficiency and latency priorities

### 6. Cancelled catalog consumers keep starting work

`SourcesViewModel.swift:136–204` lacks cancellation checkpoints around restoration and successive fetch batches; its generic error handler also treats cancellation as a source failure. `SourceRepositoryService.fetch` awaits a shared unstructured task, so cancellation of a view consumer does not automatically stop it. Shared flights should survive for other consumers, but a cancelled consumer should stop initiating later batches and publishing its own results.

`InstallationAppProxy.fetchApps` and `provisioningProfiles` likewise await detached workers without propagating cancellation. Existing generation checks protect the UI but do not stop redundant native work. Add cooperative checks at safe boundaries; cancellation cannot instantly interrupt every blocking native call.

### 7. Connected status waits for the initial app browse

The new connection reuse avoids an extra handshake, but `DeviceConnectionManager.swift:638` asks the verification operation to browse apps, and only publishes Connected after it returns. `Heartbeat+checks.swift:46` performs the browse before returning successful verification. A slow browse or full Lookup fallback therefore delays connection readiness in the UI.

Fix direction: publish authenticated transport readiness first, then finish enumeration using the same owned connection. Preserve pairing rejection handling and generation checks. Device measurements should compare both connection-ready time and first-row time; reducing one must not unnecessarily worsen the other.

### 8. Display descriptions still do repeated work on the UI thread

`SourceAppsCellView.swift:40,99` sanitizes complete descriptions when its SwiftUI body is evaluated. `ExpandableText` repeats emoji cleanup too. Preparing search fields off the main actor does not eliminate this display-side work. Large descriptions can therefore create extra main-thread work during row updates.

Fix direction: prepare the display strings alongside catalog projections, keyed by raw content and display policy. Keep the cache bounded. The expected scrolling improvement needs device profiling.

### 9. Catalog memory has multiple independent owners

The repository service's raw-data bound is not a whole-app catalog memory bound: decoded repositories, prepared lists, projections, and the update index retain their own objects. `InstalledAppUpdateCatalog.swift:42` releases obsolete index entries only when a later lookup rebuilds its signature. If no lookup occurs after source deletion, the old candidates remain retained. Source list rows also retain repository catalogs through their source value, extending catalog lifetimes even where only repository metadata is required.

Fix direction: explicitly invalidate the update index on source deletion and reduce row source values to metadata where practical. Measure total retained memory before choosing further cache limits; shared Swift arrays do not imply a separate full array allocation per row.

## Local packaging and payload transfer

The previously removed install package cache remains removed. Hardware-backed encryption and coalesced progress are already in the current path. Sequential AFC acknowledgements and the transport's 1 MiB outstanding-data window are not, by themselves, evidence of a defect. Further transfer speed changes should follow a breakdown of compression time, acknowledged throughput, CPU, and retransmission behavior.

A concrete remaining optimization opportunity is reducing buffer copies between Swift chunks, Rust ownership, AFC serialization, and transport buffers. Another is overlapping safe connection preparation with packaging. Neither has a measured benefit yet, and changing packet size or bypassing acknowledgements is not justified by this audit. Compression is a CPU-versus-upload-size tradeoff, not an automatic speed improvement.

`docs/install-transfer-diagnostics.md` still describes a reusable package cache and should be corrected when changes are implemented.

## Verification and limits

The five focused audit, efficiency, device-loading, installed-loading, and release regression scripts passed during this review. They exercise the recent changes but do not prove background delegate ordering, actual native response compatibility, or iPhone performance. The host currently lacks Xcode/iOS SDK and XCTest, so no full iOS build or device profile was run.

Previously excluded waiting-job wording and server handoff findings were not reintroduced. Security hardening was outside this review. This report prioritizes actionable findings and does not claim that a static audit proves the absence of other bugs.

## Remediation completed in the working tree

All nine actionable findings above now have targeted changes:

- Restored transfer identities can adopt early callbacks synchronously. The asynchronous restoration pass excludes new transfers and superseded retries, preserving the save-before-resume barrier.
- Lightweight decoding requires a complete response before it is accepted. Full Lookup also reports incomplete/invalid results rather than silently replacing the visible list with partial data.
- Every Library section uses the search filter, with name and bundle-identifier matching; the no-results state derives from those same filtered sections.
- Deletion stages files with a same-directory rename and restores them plus the database transaction on save failure. Export source ownership persists until its worker exits, including after Cancel removes its row.
- Expanded descriptions compare constrained and unconstrained geometry, including line spacing and subsequent width/Dynamic Type changes.
- Cancelled catalog consumers stop future batches and do not publish failure state. Detached native reads propagate cancellation and check safe boundaries. Navigation avoids repeating disk-cache restoration on a miss.
- Authenticated transport readiness publishes independently of the initial browse; the app-list loader awaits the same browse result. A separate verification token prevents late callbacks undoing disconnects. Readiness and browse duration remain logged separately.
- Cleaned bodies and subtitles share a bounded, thread-safe display cache warmed by catalog actors. Cache misses remain safe for other callers.
- Prepared rows retain repository metadata instead of whole app/news catalogs. Source deletion invalidates the update index immediately and tombstones stale contexts.

The obsolete package-cache diagnostic paragraph was corrected. No AFC packet sizing, acknowledgement, or encryption behavior was changed; those were measurement-dependent opportunities rather than validated defects.

Validation: six focused regression scripts passed, including new restoration, cancellation, partial-browse, deletion rollback, source-index invalidation, search, and connection ownership cases. Changed Swift files passed parser checks. Full XCTest/iOS build and real-device latency, background-relaunch, and Dynamic Type rendering remain unverified on this host because Xcode/iOS SDK are unavailable. No release or push was performed.

## Release preflight follow-up

Two complete GitHub build logs exposed missing production logging imports/result type annotations in the native reader and a missing Library no-results binding. These are corrected. The expanded native preflight now compiles actual app/profile models and detached reader methods against OSLog and a mock C ABI, exercising valid/malformed profile responses and pairing failures. Library preflight compiles the actual section-selection prelude. The connection readiness callback also passes Swift 6 type checking with warnings treated as errors; its existing verification-generation guards remain intact.

All six focused local suites pass. The existing release test entry point now runs the five expanded suites after XCTest, so these checks execute on GitHub without changing workflow permissions. Full iOS build validation remains required; local parser/fixture checks are not a substitute for it.

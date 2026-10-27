# Aether regression checks

Focused checks runnable with macOS Command Line Tools:

```sh
python3 Tests/Regression/run-release-checks.py
python3 Tests/Regression/run-audit-fix-checks.py
python3 Tests/Regression/run-efficiency-checks.py
python3 Tests/Regression/run-device-loading-checks.py
python3 Tests/Regression/run-installed-loading-checks.py
python3 Tests/Regression/run-whole-app-checks.py
python3 Tests/Regression/run-foreground-recovery-checks.py
```

Efficiency checks exercise catalog deletion during a request, stale projection prevention, search semantics, cached-icon/render ownership, lightweight browse with binary plist decoding through a mock C ABI, pairing rejection, RSD discovery/reuse/retry ownership, progressive installed-row loading, and explicit versus foreground refresh. Device transport mocks do not verify iPhone latency or firmware behaviour.

The whole-app checks cover restored-task adoption before enumeration, stale callback rejection, fresh-task persistence barriers, catalogue cancellation, native-worker cancellation, and Library search matching. The audit checks cover deletion rollback and active export ownership with real Core Data, tunnel transition ownership with transport doubles, uninstall/refresh invalidation, certificate identity, modern screenshot decoding, and concurrent export naming.

Foreground recovery checks copy the production lifecycle, reconciliation, and explicit-action verification methods. Controlled suspension points cover unlocking during disconnect, stale connected state, delayed lifecycle events, superseded profile/transport checks, repeated activation, and manual cancellation. Recovery waits are event-driven and bounded; checks also cover reuse of a freshly verified transport before VPN/profile work. They run with strict Swift 6 checks; real VPN and lock/unlock behavior still require an iPhone.

The exact regression gate used by both the release workflow and the main/PR
regression workflow is runnable locally. It does not create or publish a release:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/Regression/run-release-gate.sh
```

The gate runs the release checks and then `run.sh`, which creates an isolated Swift package, copies the production archive, installation monitor, cancellation relay, and file-clone implementation, and generates fixtures. The package manifest here is a template for that isolated package. Set `AETHER_ZIPFOUNDATION_CHECKOUT` to an existing ZIPFoundation 0.9.20 checkout and `AETHER_ZIP_CHECKOUT` to an existing Zip 2.1.2 checkout to avoid fetching dependencies again. These options change dependency locations, not which tests run. Every standalone `run-*-checks.py` must be registered in the runner; the entry-point check rejects missing or duplicate entries.

### Startup activation and self-update recovery

`run-foreground-recovery-checks.py` verifies that cold construction cannot query
LocalDevVPN even if UIKit initially reports Active. Actual activation starts the
handoff once, and a genuinely missing provider remains actionable afterward.
`run-refresh-verification-checks.py` covers Library callers awaiting that first
activation, cancellation/backgrounding while waiting, shared verification,
single recovery, and stale reply rejection. Both run in the release gate.

Self-update checks exercise version/build evidence, one-shot command-sent
delivery without percentage responses, and retiring queued backgrounding after
completion or cancellation. `run-self-update-queue-checks.py` executes the actual
queue initializer and persistence method with isolated defaults: confirmed
replacement uses normal completion; unconfirmed sent same-build reinstall restores
Reinstall without completion-driven deletion; unrelated/interrupted jobs keep
Retry/Cancel; subsequent queued jobs remain persisted. Native callbacks,
artifact lookup and completion side effects are controlled substitutes. Whether
iOS actually replaces a running app after suspension still requires an iPhone.

Lifecycle and operation tests copy the actual production method bodies at execution time and replace transport, native signing, persistence, and platform dependencies with controlled substitutes. These tests exercise races, failure propagation, and normal controls; they do not perform real device signing or installation. Archive tests use the actual pinned ZIPFoundation parser and filesystem writes.

For additional UIKit runtime checks, pass a booted iOS 26+ Simulator UUID:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/Regression/run-platform.sh SIMULATOR_UUID
```

This compiles the production installed-state, progress, and alert helpers into a small temporary simulator app. It checks known/unknown installation state, a nonblocking progress lookup, safe handling when no window exists, and ordinary alert presentation. It removes the test app after success. This runner does not download or install another app through Aether and does not change the connected iPhone.

### Aether signing identity

Run `python3 Tests/Regression/run-signing-identity-checks.py` to exercise the production profile-ID resolver, backend validation, and file-backed extension identifier rewrites. Covers malformed/wildcard profiles, expired profiles, changed queued certificates, manual-ID precedence, stale identifiers on externally renamed Aether copies, namespace boundaries, option conflicts, and preserving the existing plugin behavior when the toggle is off. Full iOS signing and tunnel behavior still require an iPhone build.

Signing and transfer progress checks: `run-operation-progress-checks.py` exercises the production coalescers and terminal-state guards. `run-native-signing-progress-checks.py` signs a native fixture with and without progress, checks identical signature/resource output and SHA digests, and exercises large resource hashing plus isolated thread-local scopes. It requires Clang and Homebrew OpenSSL 3. Native AFC progress tests run with the existing native build checks.

Follow-up correctness checks: `python3 Tests/Regression/run-followup-audit-checks.py` exercises reset/pairing ownership, uninstall exclusion, immediate external-import rows, execution acquisition, private-source retry, interruption, and cancellation using production methods and real file coordination.

Background execution audit: `generate-background-tests.py`, `generate-import-lifecycle-tests.py`, and `generate-correction-tests.py` exercise pending/native/fallback ownership, immediate expiration signalling, late delivery, foreground fallback expiry, deferred background processing, serial-gate execution acquisition, queue growth, stage progress, and durable local-import staging. They use the production lifecycle methods with deterministic platform/file-stage doubles; actual iOS grant timing, locked-device execution, and resource-pressure behavior still need physical-device validation. `run-followup-audit-checks.py` also exercises the real file-provider copy into recoverable staging.

Signed-row handoff: `python3 Tests/Regression/run-unified-handoff-checks.py` exercises the production row projection when signing completes before fetched signed records arrive, including operation retirement, re-signing, revealed originals, and preventing deleted snapshots from reappearing.

### Focused tunnel-flow handoff

Run `python3 Tests/Regression/run-tunnel-flow-suite.py` for repeated local lifecycle/cellular harness checks with retained logs and a per-suite watchdog. See [TUNNEL-FLOW-HANDOFF.md](TUNNEL-FLOW-HANDOFF.md) for coverage, limits, and instructions for a lower-cost execution model. This does not build or install Aether.

Native RSD establishment recovery is covered by `rsd_connection_timeout_tests` in the native build: stalled connect → timeout → successful retry, silent service check-in and resource disposal. The connection-lifecycle harness additionally holds RSD cleanup pending while asserting that in-app VPN startup proceeds, and verifies cancellation prevents late cleanup from reviving that start.

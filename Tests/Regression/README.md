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

From the repository root, with Xcode selected:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/Regression/run.sh
```

The runner creates an isolated Swift package, copies the production archive, installation monitor, cancellation relay, and file-clone implementation, and generates fixtures. The package manifest here is a template for that isolated package. Set `AETHER_ZIPFOUNDATION_CHECKOUT` to an existing ZIPFoundation 0.9.20 checkout to avoid fetching the dependency again.

Lifecycle and operation tests copy the actual production method bodies at execution time and replace transport, native signing, persistence, and platform dependencies with controlled substitutes. These tests exercise races, failure propagation, and normal controls; they do not perform real device signing or installation. Archive tests use the actual pinned ZIPFoundation parser and filesystem writes.

For additional UIKit runtime checks, pass a booted iOS 26+ Simulator UUID:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/Regression/run-platform.sh SIMULATOR_UUID
```

This compiles the production installed-state, progress, and alert helpers into a small temporary simulator app. It checks known/unknown installation state, a nonblocking progress lookup, safe handling when no window exists, and ordinary alert presentation. It removes the test app after success. This runner does not download or install another app through Aether and does not change the connected iPhone.

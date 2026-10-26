# Local tunnel-flow testing handoff

Run from `/Users/artho/Documents/ChatGPT/Aether`:

```sh
python3 Tests/Regression/run-tunnel-flow-suite.py
```

Requires macOS and Swift Command Line Tools. No iPhone, simulator, app build, GitHub build, release, or additional Python packages. The runner compiles small standalone harnesses, not Aether. It runs ten suites three times in fresh processes, retains every log and a JSON summary outside the repository, and kills a hung suite after 90 seconds. It continues after failures so one problem does not hide others. An interrupted run retains its partial report. For additional scheduling stress, use `--repeat 10`. Repetition is not exhaustive proof of every scheduling order.

## Instructions for the executing model

Run the command above. Do not modify production files, test assertions, timeouts, or fixtures. Do not build/install Aether, commit, push, or release. Do not discard existing changes. Report only the result count and report path on success. On failure, report the suite/pass, exact first error/assertion, and log path; distinguish compilation/fixture errors, watchdog timeouts, and assertion failures. Stop for review rather than guessing a fix. If a repeated run fails intermittently, preserve both the passing and failing logs. Do not claim real-device validation.

## Existing production-code coverage

The suites extract current production declarations when run and substitute controlled system services. A production method/signature change may require a fixture update; do not silently substitute a rewritten model of the intended behavior.

| Suite | Coverage |
| --- | --- |
| callbacks | Completion, cancellation, stale generations and repeated completion |
| connection-lifecycle | Profile approval, delayed preparation/start, background idle shutdown, protected operations, idle-off behavior, LocalDevVPN handoff, timeout, late preparation, old reconciliation, VPN-before-cellular ordering, disabling automatic connection, explicit ownership and Retry |
| foreground-races | Foreground/background ordering, disconnect in flight, superseded profile/transport checks, activation coalescing, explicit actions and fresh verification reuse |
| refresh-verification | Shared verification results, one recovery, automatic-off policy, prerequisites, caller cancellation, stop/start ordering and stale generations |
| cellular-lifecycle | Missing Shortcuts/helper, lost callbacks, callback grace interrupted by background, restore debt, stale verification, manual guidance, terminal failure preservation and explicit rearming |
| cellular-verification-and-placeholders | Shared verification deadline, blocked native reply, cancellation, transient route settling, permanent/pairing rejection, no app browse before restoring data, native lock cancellation, actionable manual guidance and prerequisite/error priority |
| idle-vpn-stop | Profile loading, pending stop, finite background lease and expiration |
| resource-recovery | VPN ownership, restore debt, failed spoof operations and resource cleanup |
| installed-loading | Bounded app reads, disconnect cancellation, late results, profile fallback, service errors and failed-transport verification |
| library-startup | Initial hydration, live insertion/deletion, duplicate snapshots and transaction isolation |

Some waits are shortened in harnesses while preserving the production control flow. The outer watchdog is a test-run safety limit, not an app timeout. Assertions check logical state and ownership, not pixel-perfect animations or iPhone latency. Tests use fixture-specific preferences; they do not alter the iPhone's settings. Not every test is a full integration through every production component: read each fixture before drawing stronger conclusions.

## Remaining device-only coverage

These harnesses cannot validate iOS suspension, native VPN routing, actual Shortcuts callbacks, cellular route settlement, LocalDevVPN availability/URL handoffs, or visual animation quality. Later test both providers, automatic connection on/off, idle disconnect on/off, Wi-Fi/cellular/offline, and background/lock/return at each stage. Also test missing/rejected pairing, absent/denied VPN profile, missing LocalDevVPN, missing helper, restoration failure and network/provider changes mid-attempt. A no-VPN debug build cannot validate the In-App VPN path. Do not provision or install anything as part of this handoff.

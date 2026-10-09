# Build warning cleanup

This pass follows the baseline in `ios26-cleanup-warnings.md` (240 application warning locations). The minimum supported OS and strict concurrency diagnostics remain unchanged.

## Changes

- Main-actor ownership for storage, signing options, haptics and the local install server. File extraction, signing and packaging remain on workers.
- Immutable, checked-Sendable native app/pairing/log values and recursive Codable snapshots. Worker signing helpers receive explicit options snapshots.
- Main-actor completion/progress callbacks; certificate revocation callbacks retain an identifier and look up the current managed object before writing.
- Explicit thread-safe cache owners, locked packet-provider lifecycle state, and one-way NetworkExtension manager handoffs. Observer destruction respects actor ownership.
- The server builds UIKit response assets on the main actor and serves immutable snapshots. Its payload streaming, range support and progress behavior are preserved.
- Current SwiftUI change/navigation APIs and MapKit location APIs. Icon rendering receives the view's display scale and appearance rather than reading the global screen on a worker.
- Removed an orphan asset and obsolete library search path.

## Verification

The first successful fresh iPhone build is [run 37866043461](https://github.com/a-artho/aether/actions/runs/37866043461), at `5c476fc`. It passed all 83 XCTest regressions, the focused executable checks, native pairing/transfer checks, the iPhone build and unsigned-package validation.

Application source warnings: **240 → 0**. This includes the tunnel extension, deprecated APIs, asset and linker-path warnings. No global warning suppression or relaxed concurrency setting was added.

Remaining diagnostics are external to the application source:

- The pinned `idevice` Rust dependency reports 12 release-build warnings for unused internal helpers, types or fields. Its selected-feature test builds also report an unused `RsdProvider` import and an unused `send_raw_profiled` method. These are not Swift concurrency warnings; upstream feature/API code has not been removed simply to quiet them.
- Apple's metadata processor emits “Metadata extraction skipped. No AppIntents.framework dependency found” for the app/extension. Neither target implements App Intents; linking an unused framework solely to hide that notice would serve no functional purpose.

The final plist-number preservation refinement passed the same complete validation in [run 37866842852](https://github.com/a-artho/aether/actions/runs/37866842852), at `92f5d78`, again with zero application source warnings. Both Codable containers also pass local Swift 6 complete-concurrency checks with warnings treated as errors.

Release publishing is disabled for these validation runs.

New executable checks cover recursive Codable snapshot isolation and delayed tunnel callbacks across cancellation/restart. Existing regression checks cover queue restoration, cancellation, foreground recovery, icon races, signing publication, server range/conditional responses, payload progress and unsigned package structure.

# Loading optimizations — 7 October 2026

Implemented the six tunnel/list-loading optimizations and the additional icon, catalog, search, and archive-inspection fixes.

- Initial pairing verification can reuse its Installation Proxy connection for a lightweight app browse. Confirmed sideloaded rows appear before profile fallback; existing rows remain stable during subsequent refreshes.
- Initial app metadata uses narrowed Browse attributes and binary plist decoding, with full Lookup fallback. Full information loads on demand when opening the information sheet.
- RSD retries distinguish recoverable transport/service errors from authentication or permanent errors. Retry delays occur outside the shared lock; known ports are tried before progressive Bonjour discovery.
- VPN configuration and recent foreground list loads are reused, while explicit refreshes and configuration changes invalidate them.
- Icon requests use the known pairing scope. Cancelled or superseded renderers cannot overwrite newer images.
- Deleted sources evict catalog/projection caches and invalidate in-flight results. Memory catalog retention is bounded.
- Description searches scan distinct stored fields once. Unchanged staged archives reuse inspection; changed source files trigger staged-file inspection, using refreshed resource metadata.

## Package caching

Removed at the user's request. There is no retained compressed-IPA cache for retries or reinstalls. Such a cache would occupy disk, rather than retain entire IPAs in RAM; retries continue to package afresh.

## Validation

Focused cache/search/icon/archive-inspection, native ABI/pairing/RSD, installed-loading/foreground, previous audit-fix, and release-format checks passed. Discovery also typechecked against the host's Network framework. Fixture checks use controlled native stand-ins; they do not establish real-device speed or firmware behavior.

The full XCTest suite and iPhone build could not run on this host because Xcode's XCTest framework and iOS SDK are unavailable. Real-device timing, browse attribute compatibility, and UI behavior remain to be verified. No release was made.

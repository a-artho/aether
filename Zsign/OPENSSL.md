# OpenSSL for Aether signing

Run `make openssl` before opening/building Aether in Xcode. `make iphoneos`,
`make maccatalyst`, and the GitHub release workflow run this step automatically.
The first build requires full Xcode and downloads the official source archive.
Later builds reuse the XCFramework when the script and toolchain are unchanged.

`build-openssl.sh` pins OpenSSL **3.5.9 LTS** and verifies the official release
archive's SHA-256. The binary is built locally; no third-party prebuilt binary
is used. The old OpenSSL 3.3.3 Swift package has been removed.

The generated `OpenSSL.xcframework` contains static `libcrypto` slices for iOS,
both iOS Simulator architectures, macOS, and Mac Catalyst. These are Aether's
supported build destinations. Generated binaries and build products are ignored
by Git. The script copies the upstream Apache 2.0 license into the XCFramework.

The configuration uses `no-shared no-module`, retaining the default provider and
building the **legacy provider into libcrypto**. Aether imports older PKCS#12
files that can require RC2; a build that expects an external `legacy.dylib` would
break these imports on iOS. Each slice is checked for the built-in provider.
Existing provider loading, certificate handling, and signing passes are retained.
Before publishing the XCFramework, the script runs a host check that creates and
parses AES and legacy RC2 PKCS#12 files, rejects an incorrect password, and signs
and verifies CMS data using a generated test identity.

For a host-only compile/link check with Command Line Tools:

```sh
bash Zsign/build-openssl.sh --host-only
```

This produces a host library under `.openssl-build`; it does not generate or
replace the production XCFramework. To change the source version, update both
the version and verified archive hash in the script and rebuild all slices.

Sources: [OpenSSL 3.5.9 release](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9),
[support policy](https://openssl-library.org/policies/releasestrat/).

# Aether regression checks

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

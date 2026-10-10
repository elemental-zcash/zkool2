# Zkool native mobile proof of concept

SwiftUI first, with a shared Rust API that can also generate Kotlin bindings for
Jetpack Compose and TypeScript/JSI bindings for React Native Turbo Modules.
The existing Flutter application remains the main application.

## What is implemented

- `rust/`: a UniFFI adapter over `rlz`, with async Swift/Kotlin-compatible methods.
- `ios/`: a SwiftUI application using encrypted SQLCipher storage, account import,
  account balances, synchronization/cancellation, and explicit Sapling parameter download.
- `build-apple.py`: Swift binding generation and device/simulator XCFramework packaging.
- `tests/SwiftSmoke.swift`: a host integration check through the actual generated FFI.

The adapter calls Juniper's existing GraphQL queries and mutations **in process**.
It does not start the GraphQL CLI, open a listening port, or require JWTs. The app
has full wallet privileges. `execute` takes a standard JSON GraphQL request
(`query`, optional `variables` and `operationName`) and returns the standard JSON
response. Resolver/validation failures are returned in `errors`; configuration,
JSON decoding, and native failures throw `WalletError`. Typed `accounts` and
`synchronizeAccount` helpers check GraphQL errors and preserve decimal balances as strings.

`graphql-core` contains the reusable schema. The existing `graphql` feature still
includes the CLI's HTTP/WebSocket/auth dependencies. The native crate disables
Flutter and Nym default features and does not enable Ledger USB transport.

## Run the SwiftUI app

Requirements: macOS with **full Xcode selected**, Rust, Python 3, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The app targets iOS 16+.

From the `zkool2` workspace:

```bash
# If needed, select your full Xcode installation:
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
brew install xcodegen
python3 native/build-apple.py
open native/ios/ZkoolPOC.xcodeproj
```

Choose a simulator and run the `ZkoolPOC` scheme. Set a development team in Xcode
for a physical device. `--simulator-only` skips the device slice (Apple Silicon
simulators only). Re-run the build script after Rust API changes.

Open a wallet with a password and a lightwalletd URL matching the chosen network.
Use the same password on later launches. Network-specific files live in the app's
Application Support directory, which is excluded from device backups. Import a
seed phrase or viewing key and its birthday height, then sync the account. Import
uses the existing GraphQL `createAccount` resolver, which contacts lightwalletd
even when an explicit birthday is supplied. Regtest requires a reachable server;
the iOS app follows the platform's default HTTPS policy.

Passwords and imported keys are not persisted in preferences or logged by the
prototype, and their input fields clear after successful operations. Swift strings
do not provide guaranteed memory zeroization. Password recovery/Keychain, account
export, receive-address display, send confirmation, background sync, and a full
wallet UX remain future work. Keep a separate recovery backup; this prototype
does not supply one.

## Verify the binding on macOS without an iOS SDK

```bash
cargo test --locked -p zkool-native --lib
python3 native/build-apple.py --bindings-only
swiftc -parse-as-library \
  -Xcc -fmodule-map-file=native/ios/Generated/ZkoolNativeFFI.modulemap \
  -I native/ios/Generated -L target/debug -lzkool_native \
  -Xlinker -rpath -Xlinker "$PWD/target/debug" \
  native/ios/Generated/ZkoolNative.swift native/tests/SwiftSmoke.swift \
  -o /tmp/zkool-swift-smoke
/tmp/zkool-swift-smoke
```

The Rust test exercises an encrypted temporary database, failed-open retries,
configuration validation, account reads, a GraphQL mutation, query errors, and the
single-wallet guard without a network connection.
The Swift smoke test verifies generated constructors, async calls, and typed errors.
The host checks do not validate iOS cross-compilation or SwiftUI rendering.

## Lifecycle and current limits

The wallet core has process-global data directory, connection pool, sync, FROST,
and subscription state. `Wallet.open` therefore permits **one successful open per
process**. Retain the handle for the app lifetime; restart the app to change wallets.
A failed open can be retried, but the initialized data directory cannot change.
Do not embed this adapter alongside a separately initialized Flutter/CLI wallet
in the same process. Async calls enter UniFFI's Tokio runtime; wallet operations
are serialized, while cancellation can run during synchronization. The adapter
creates fresh GraphQL data loaders for every request to avoid stale cached reads.

`execute` supports queries and mutations. GraphQL subscriptions, mempool monitoring,
and native event streams are not implemented in this PoC. No parameter download
or network connection is initiated by `Wallet.open`. Parameter download is an
explicit action, using the app's writable data directory.

## Compose and React Native follow-up

The same compiled crate supports Kotlin generation:

```bash
cargo run --locked -p zkool-native --features bindgen --bin zkool-bindgen -- \
  generate --library target/debug/libzkool_native.dylib --metadata-no-deps --language kotlin \
  --config native/rust/uniffi.toml --out-dir native/android/generated
```

An Android app would still need NDK builds, ABI packaging, the UniFFI Kotlin/JNA
runtime dependencies, and a Compose UI. There is no Android app in this change.

[UniFFI for React Native](https://github.com/jhugman/uniffi-bindgen-react-native)
can generate TypeScript/JSI and Turbo Module installation code from these same
exports. There is no React Native package in this SwiftUI-first change. UniFFI
was chosen over [Craby](https://github.com/leegeunhyeok/craby) because its
[Swift and Kotlin bindings](https://mozilla.github.io/uniffi-rs/latest/)
fit the native-app direction without tying the Rust API to a TypeScript spec.

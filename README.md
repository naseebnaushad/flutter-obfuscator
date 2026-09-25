# flutter_obfuscator

Build-time obfuscation for Flutter apps aimed at VAPT engagements: it
encrypts hardcoded secrets (API keys, tokens) and sensitive bundled assets
so they don't show up in plaintext under static analysis (`strings`, grep,
unzipping the APK/IPA, JADX-style extraction).

Flutter's own `--obfuscate --split-debug-info` only renames Dart symbols;
it does nothing about a `const apiKey = "..."` sitting in the compiled
snapshot, or a `assets/config.json` full of internal endpoints bundled
verbatim into the app. This tool targets that gap.

## What it does (v1)

1. **Secret scanning** — walks `lib/**/*.dart`, finds `const`/`final`
   String field declarations whose name matches a secret-like pattern
   (`apiKey`, `authToken`, `clientSecret`, ...) or that carry a
   configured annotation, and whose value has enough entropy to plausibly
   be a real secret (filters out `"Loading..."`-style false positives).
2. **Encryption** — encrypts each matched value with AES-256-GCM and
   rewrites the declaration to `SecretVault.get('<id>')`.
3. **Asset encryption** — encrypts files matched by your `assets:` globs
   *in place* (same logical asset path, so `pubspec.yaml` never needs to
   change) and rewrites `rootBundle.load`/`loadString` call sites to go
   through the generated `AssetVault`.
4. **Flutter's own obfuscation** — optionally runs
   `flutter build <target> --obfuscate --split-debug-info=...` for you on
   top of the above.
5. **Verification** — optionally unpacks the built artifact and confirms
   none of the original plaintext secret values are still present.

## What it does (v2, opt-in)

Set `key_strategy: native_channel` in `obfuscator.yaml` and the vault key
moves out of the Dart snapshot entirely:

6. **Native key generation** — generates a Kotlin object
   (`ObfKeyMaterial`/`ObfuscatorKeyPlugin.kt`, split/XORed the same way as
   v1) on Android and a Swift equivalent
   (`ObfKeyMaterial`/`ObfuscatorKeyPlugin.swift`) on iOS, each exposing the
   key over a `flutter_obfuscator/key` MethodChannel.
7. **Entry-point wiring** — injects the plugin registration into
   `MainActivity.kt` (`flutterEngine.plugins.add(ObfuscatorKeyPlugin())`)
   and `AppDelegate.swift` (right after
   `GeneratedPluginRegistrant.register(with: self)`), marked with
   `BEGIN/END FLUTTER_OBFUSCATOR KEY CHANNEL` comments so re-running is
   idempotent. Only the standard `flutter create` shapes are patched —
   anything else (Java `MainActivity`, a hand-written `AppDelegate.swift`
   without the usual registrant call, missing android/ios directories) is
   reported as **skipped** in the run summary with manual-wiring
   instructions, never silently left half-wired.
8. **Dart side** — `SecretVault`/`AssetVault` call
   `NativeKeyChannel.fetchKey()` instead of reconstructing the key from
   Dart constants.

Why this matters: Flutter reverse-engineering tools that dump the Dart
AOT snapshot (the standard way secrets get pulled out of a Flutter app)
have nothing to find anymore — the key was never in the snapshot. It now
has to come from the native binary/DEX instead, a different, generally
harder extraction path. It's still the same split/XOR obfuscation
technique as v1, just relocated — see **Known limitations** below for
what this still doesn't solve.

All of this runs against a **staged copy** of your project
(`<project>/build/obfuscated` by default) so your working tree is never
touched, unless you explicitly ask for `apply` (in-place).

## Usage

```bash
dart pub global activate --source path .   # or path-dependency it in your CI

flutter_obfuscator build --project /path/to/app
# -> writes the obfuscated copy to /path/to/app/build/obfuscated

flutter_obfuscator build --project /path/to/app --build apk --verify
# -> also runs `flutter build apk --obfuscate --split-debug-info=...`
#    in the staged copy, then greps the APK for plaintext leaks

flutter_obfuscator apply --project /path/to/app
# -> rewrites the project IN PLACE. Commit or stash first.
```

Add `await SecretVault.init();` once in `main()`, before `runApp()` — the
generated vault decrypts everything up front so `SecretVault.get(id)` is a
synchronous lookup everywhere else:

```dart
Future<void> main() async {
  await SecretVault.init();
  runApp(const MyApp());
}
```

## Configuration (`obfuscator.yaml`)

Optional; sensible defaults are used if absent.

```yaml
secrets:
  patterns:               # regexes matched against variable names
    - 'api[_-]?key'
    - 'token'
    - 'secret'
    - 'password'
  annotations: ['Secret'] # e.g. @Secret() String x = "...";
  min_entropy: 3.0        # filters out low-entropy false positives
  exclude_files:
    - '**/*.g.dart'
    - '**/*.freezed.dart'

assets:
  include:
    - 'assets/config/**'
  exclude:
    - 'assets/config/public_readme.md'

key_strategy: dart_split # or 'native_channel' (v2, see above)
```

## Known limitations (read this before a VAPT sign-off)

- **Static-only.** This defeats `strings`/grep/JADX-style extraction —
  the finding a VAPT report typically calls out. It does **not** stop a
  motivated attacker with Frida or another dynamic instrumentation tool
  hooking `SecretVault.get`/`AssetVault.load` at runtime, or hooking the
  AES-GCM call itself. That needs root/jailbreak detection, anti-tampering,
  and certificate pinning as separate controls.
- **Key material is still in the Dart snapshot by default (v1,
  `key_strategy: dart_split`).** The AES key is split into several
  XORed, misleadingly-named constants (`_obf_key_material.g.dart`)
  instead of one plaintext constant. That raises the bar over a single
  grep-able key, but a determined reverse engineer with a decompiler can
  still reconstruct it.
- **v2 (`key_strategy: native_channel`) moves the key out of the Dart
  snapshot, not out of the app.** It's the same split/XOR technique,
  just implemented in Kotlin/Swift instead of Dart, fetched over a
  MethodChannel. That defeats Dart-snapshot-aware extraction tools
  (blutter-style dumpers), but the key is still recoverable by
  decompiling the native binary/DEX (JADX on Android, a Mach-O
  disassembler on iOS), and a Frida hook on the MethodChannel call or on
  `SecretVault.get`/`AssetVault.load` still gets the plaintext at
  runtime either way. It only auto-wires the standard `flutter create`
  `MainActivity.kt`/`AppDelegate.swift` shapes — anything else is
  reported as skipped, not silently broken.
- **Only variable declarations are auto-transformed.** A bare string
  literal used inline (not assigned to a `const`/`final` field) is not
  rewritten — refactor it into a named constant first (good practice
  anyway) so the scanner can find it.
- **Only single-variable declarations.** `const a = 1, b = 2;` is
  reported as skipped rather than partially rewritten; split such
  declarations if either side needs obfuscating.
- **Asset call-site rewriting only matches literal-argument calls** —
  `rootBundle.loadString('assets/x.json')`, not a call built from a
  variable or interpolation. Unmatched encrypted assets are listed in the
  run summary so you can fix those call sites by hand.

## Development

```bash
dart pub get
dart analyze
dart test
```

`example/sample_app` is a minimal (non-runnable, no real `flutter` SDK
needed) fixture used to smoke-test the CLI end to end:

```bash
dart run bin/flutter_obfuscator.dart build \
  --project example/sample_app --output /tmp/sample_out
```

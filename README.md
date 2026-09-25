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
```

## Known limitations (read this before a VAPT sign-off)

- **Static-only.** This defeats `strings`/grep/JADX-style extraction —
  the finding a VAPT report typically calls out. It does **not** stop a
  motivated attacker with Frida or another dynamic instrumentation tool
  hooking `SecretVault.get`/`AssetVault.load` at runtime, or hooking the
  AES-GCM call itself. That needs root/jailbreak detection, anti-tampering,
  and certificate pinning as separate controls.
- **Key material is still in the Dart snapshot (v1).** The AES key is
  split into several XORed, misleadingly-named constants
  (`_obf_key_material.g.dart`) instead of one plaintext constant. That
  raises the bar over a single grep-able key, but a determined reverse
  engineer with a decompiler can still reconstruct it. **v2** moves this
  key material into native code (Kotlin/Swift) behind a platform channel,
  which is not implemented yet.
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

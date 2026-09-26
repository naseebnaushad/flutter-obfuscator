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
   It also flags a value against an innocuous-looking name (v7, on by
   default) — see below.
2. **Encryption** — encrypts each matched value with AES-256-GCM and
   rewrites the declaration to `SecretVault.get('<id>')`.
3. **Asset encryption** — encrypts files matched by your `assets:` globs
   *in place* (same logical asset path, so `pubspec.yaml` never needs to
   change) and rewrites `rootBundle.load`/`loadString` call sites to go
   through the generated `AssetVault`. If you don't configure any
   `assets.include` globs, it auto-detects sensitive-looking bundled
   assets from `pubspec.yaml` instead of encrypting nothing (v7, on by
   default) — see below.
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

## What it does (v3 + v6, opt-in)

Set `key_strategy: native_ndk` instead and the key moves out of Kotlin/DEX
(Android) and Swift (iOS) entirely into compiled C:

9. **NDK/JNI key store** — generates a small CMake project under
   `android/app/src/main/cpp/flutter_obfuscator/` (`obfuscator_key.cpp` +
   `CMakeLists.txt`) holding the same split/XOR key material, this time
   as C arrays in a `.so`. `ObfuscatorKeyPlugin.kt` becomes a thin
   `external fun nativeMaterializeKey(): ByteArray` + `System.loadLibrary`
   shell around it; the JNI binding is wired up via `RegisterNatives` in
   `JNI_OnLoad` (not the mangled `Java_pkg_Class_method` naming
   convention) so it works regardless of underscores in your package
   name.
10. **Gradle wiring** — injects an `externalNativeBuild { cmake { ... } }`
    block into `android/app/build.gradle` (or `.kts`), marked and
    idempotent the same way as the v2 injections. Android Gradle Plugin
    only supports one CMake project per module, so if your project
    already configures `externalNativeBuild`, this is left alone and
    reported as skipped — merge the generated `CMakeLists.txt` by hand.
11. **iOS: compiled C key store (v6)** — generates a local CocoaPods pod
    under `ios/FlutterObfuscatorKeyNative/` (`obfuscator_key.c` +
    `obfuscator_key.h`, no Objective-C classes) holding the same
    split/XOR key material and a `sysctl`-based `P_TRACED` check, built
    as a static framework (`s.static_framework = true` in the generated
    podspec) so the generated `ObfuscatorKeyPlugin.swift` can
    `import FlutterObfuscatorKeyNative` without requiring
    `use_frameworks!` project-wide. Wired in with one idempotent,
    marker-based line added to `ios/Podfile` (`pod
    'FlutterObfuscatorKeyNative', :path => ...`) rather than hand-editing
    `project.pbxproj` — run `pod install` (or just `flutter build ios`,
    which does it for you) afterward.

Why this matters, and why it's a different jump on each platform: Kotlin
compiles to DEX, and JADX decompiles DEX back to near-original Kotlin/Java
source in seconds — the v2 Android key material is genuinely easy to read
once someone opens the APK in a decompiler. A stripped `.so` requires
actual disassembly (`objdump`, Ghidra, IDA) instead, which is a real jump
in effort, and still requires the NDK to be installed to build. Swift
already compiles to native machine code, so there's no equivalent
bytecode-vs-native jump on iOS — what plain, `static`-internal C with
hidden symbol visibility buys there instead is denying a decompiler the
rich Swift metadata (mangled type/method names, reflection info) and
Objective-C selector/class-name strings it otherwise leans on to
reconstruct near-source pseudocode, leaving only an anonymous stripped
function. Both are still findable by someone willing to do that work —
see **Known limitations**.

## What it does (v4, opt-in)

Set `tamper_detection.enabled: true` in `obfuscator.yaml` and a generated
`TamperGuard` gates every `SecretVault.init()` / `AssetVault.load()` call:

12. **Root/jailbreak/Frida heuristics** — before decrypting anything,
    `TamperGuard.scan()` checks for common root binaries and Magisk paths
    (Android), jailbreak paths like Cydia/MobileSubstrate (iOS), a
    listening default frida-server port (27042/27043), a
    `/data/local/tmp/re.frida.server` binary, and `frida`/`xposed`/
    `substrate` strings in `/proc/self/maps`.
13. **Native reinforcement, when a native `key_strategy` is set** —
    `ObfuscatorKeyPlugin` (Kotlin/v2, C++/v3, Swift/v2, C/v6) grows an
    `isTraced()` check: Android reads `TracerPid` from `/proc/self/status`,
    iOS reads the `P_TRACED` flag via `sysctl`. Either is nonzero/set the
    moment a debugger or ptrace-based tool (Frida included) attaches to
    the process, and it's checked from native code rather than Dart, so
    it's one step further from a Frida script hooking a Dart-visible
    function.
14. **Gate behavior** — `tamper_detection.mode: block` (the default) makes
    `SecretVault.init()`/`AssetVault.load()` throw
    `TamperDetectedException` instead of decrypting when any signal
    fires; `mode: log` prints a warning and decrypts anyway (useful while
    tuning for false positives on real devices before switching to
    `block`).

Why this matters, and why it isn't as strong as it sounds: every prior
version (v1-v3) still calls `SecretVault.get()`/`AssetVault.load()` at
some point, and hooking *that* call with Frida gets the plaintext
regardless of where the key lived — v4 is the first version that actually
tries to notice the tool doing the hooking, rather than just hiding the
key better. But the checks themselves run in Dart or are reached over the
same MethodChannel as the key fetch, so they're reachable by the same
class of tool they're trying to catch: a reverse engineer can read
`tamper_guard.g.dart` (it isn't obfuscated — it's the thing deciding
whether to trust the environment) and write a Frida script that stubs out
`TamperGuard.scan()`, `NativeKeyChannel.isTraced()`, or the native
`isTraced`/`nativeIsTraced` function directly, before ever touching the
key logic. Treat this as raising the cost of a casual/automated scan, not
as a defense against a targeted attacker — see **Known limitations**.

## What it does (v5, opt-in)

Set `certificate_pinning.enabled: true` in `obfuscator.yaml` (with manually
supplied pins — this tool never fetches a server's certificate for you) and
two independent layers get generated:

15. **`PinnedHttpClient` (Dart, cross-platform)** — a `dart:io` `HttpClient`
    factory at `lib/flutter_obfuscator/pinned_http_client.g.dart` that
    checks the connecting host's leaf certificate against configured
    SHA-256 SPKI (`SubjectPublicKeyInfo`) pins before letting a connection
    through. It isn't wired into your code automatically — swap
    `PinnedHttpClient.create()` in wherever you build your own HTTP client
    (`dart:io` directly, `IOClient(PinnedHttpClient.create())` for
    `package:http`, an `IOHttpClientAdapter` for `package:dio`); Flutter
    apps reach the network through too many shapes (`dart:io`,
    `package:http`, `package:dio`, GraphQL, WebSockets, WebViews) for this
    tool to reliably find and rewrite every call site the way it does for
    encrypted assets.
16. **`network_security_config.xml` (Android, declarative)** — a
    `<pin-set>` per host generated at
    `android/app/src/main/res/xml/network_security_config.xml`, wired into
    `AndroidManifest.xml` via `android:networkSecurityConfig`. This one
    needs no Dart code change: Android enforces it for
    `HttpsURLConnection`, OkHttp, and `WebView` traffic alike, so it also
    covers plugins and WebViews that never go through your own HTTP
    client. Only one such config can be active per app, so a manifest that
    already sets `android:networkSecurityConfig` is left alone and
    reported as skipped, same pattern as v3's `externalNativeBuild` skip.
    **There's no iOS equivalent** — App Transport Security has no
    declarative SPKI pin-set without a third-party library (e.g.
    TrustKit), so iOS relies on `PinnedHttpClient` alone.

Both layers pin the same SHA-256 SPKI values, computed the same way as
`openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst
-sha256 -binary | base64` and what Android's `<pin-set>` expects natively.
List a primary pin plus at least one backup per host — an SPKI pin survives
a certificate renewal that reuses the same keypair, but a keypair change
still needs a new pin, and locking every installed copy of the app out on a
routine rotation is the classic pinning failure mode.

Why this matters: without pinning, a device with any attacker-controlled or
compromised trusted root installed (a malicious CA, a corporate MITM proxy,
a device the user was tricked into trusting) can transparently intercept
this app's HTTPS traffic — the standard MITM attack a VAPT engagement is
supposed to flag. Pinning makes that interception fail even when the
attacker's certificate is otherwise valid and system-trusted.

## What it does (v7, on by default)

v1's secret/asset detection only fires when you name things helpfully or
list assets explicitly. v7 broadens both without any config needed:

17. **Known-credential-format matching (secrets)** — every string literal
    is also checked against a set of well-known hardcoded-credential
    shapes (AWS access key IDs, Google API keys, Google OAuth client IDs,
    Stripe live secret keys, GitHub tokens, Slack tokens, JWTs, PEM
    private key blocks). A match is encrypted regardless of the variable's
    name or the value's entropy — `final mapsUrl =
    'https://.../AIzaSy...'` gets caught even though neither `mapsUrl` nor
    a URL string trips the name-pattern/entropy check on their own. Turn
    it off with `secrets.detect_known_formats: false`.
18. **Pubspec-driven asset auto-detection** — when `assets.include` is
    left empty, sensitive-looking files (`.json`, `.xml`, `.yaml`,
    `.plist`, `.env`, `.cfg`/`.conf`, and certificate/key extensions like
    `.pem`/`.key`/`.p12`/`.cer`/`.crt`/`.der`) declared under your own
    `pubspec.yaml`'s `flutter: assets:` list are auto-included, instead of
    nothing being encrypted until you hand-write globs. Image/font/audio/
    video assets are excluded by default — they're rarely where a secret
    lives and encrypting large binaries on every build has no security
    payoff. Turn it off with `assets.auto_detect: false`, or set
    `assets.include` yourself to bypass auto-detection entirely.

Why this matters: v1's detection depends on the developer naming a
variable in a way that signals "this is a secret," and on assets being
explicitly listed for encryption. Real hardcoded credentials routinely
don't announce themselves that way — a Google Maps key concatenated into
a URL, a service-account JSON shipped as a bundled asset because "it's
just config" — and previously those slipped through untouched. v7 doesn't
change how anything is encrypted; it only widens what gets *found*.

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
  detect_known_formats: true # v7: flag AWS/Google/Stripe/GitHub/Slack keys,
                              # JWTs, PEM blocks regardless of name/entropy

assets:
  include:                  # leave empty to use v7 auto-detection instead
    - 'assets/config/**'
  exclude:
    - 'assets/config/public_readme.md'
  auto_detect: true          # v7: only used when `include` above is empty

key_strategy: dart_split # 'dart_split' (v1) | 'native_channel' (v2) | 'native_ndk' (v3 Android + v6 iOS)

tamper_detection:         # v4, opt-in, default disabled
  enabled: false
  mode: block              # 'block' (default) | 'log'

certificate_pinning:      # v5, opt-in, default disabled
  enabled: false
  unpinned_hosts: block    # 'block' (default) | 'allow' — see Known limitations
  pins:
    - host: api.example.com
      spki_sha256:
        - 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' # primary
        - 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' # backup, for rotation
```

## Known limitations (read this before a VAPT sign-off)

- **Static-only by default (v1-v3).** v1-v3 defeat `strings`/grep/
  JADX-style extraction — the finding a VAPT report typically calls out.
  On their own they do **not** stop a motivated attacker with Frida or
  another dynamic instrumentation tool hooking `SecretVault.get`/
  `AssetVault.load` at runtime, or hooking the AES-GCM call itself. v4 and
  v5 (below) are limited steps at addressing this; a real RASP/
  anti-tampering product is still a separate control this tool does not
  provide.
- **v4 (`tamper_detection`) is a heuristic speed bump, not a wall.**
  Every check it runs (root/jailbreak file paths, the default frida-server
  port, `/proc/self/maps`, `TracerPid`/`P_TRACED`) is either public
  knowledge a real root/Frida setup can hide (renamed `su`, port other
  than 27042, `frida-server` run with `--no-pause` after detaching, or
  survived via `LD_PRELOAD` unlink tricks), or is itself reachable by a
  Frida script that patches `TamperGuard.scan()` — or the native
  `isTraced`/`nativeIsTraced` function it calls into — into always
  returning "clean" before the real checks ever run. It is meant to catch
  a default, un-hidden Frida/Magisk setup during a quick static or dynamic
  pass, not to withstand someone specifically evading it. `mode: log`
  exists to let you validate it doesn't false-positive on real devices
  before ever setting `mode: block` in a shipped build.
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
- **`key_strategy: native_ndk` (v3 Android, v6 iOS) is a real jump in
  reverse-engineering effort, not a wall.** On Android it raises the bar
  from "decompile DEX with JADX" to "disassemble a stripped `.so`" for
  the key material specifically. On iOS, where Swift already compiles to
  native machine code, the jump is narrower: moving to plain C with
  hidden symbol visibility denies a decompiler the Swift metadata and
  Objective-C selector strings it would otherwise use, but doesn't add a
  bytecode-vs-native gap the way the Android change does. On both
  platforms the key is still physically present in the binary for
  someone willing to disassemble it, and a Frida hook on the
  MethodChannel call or `SecretVault.get`/`AssetVault.load` still
  defeats it at runtime regardless of where the key lives. It requires
  the Android NDK to be installed to build (a normal `flutter build apk`
  doesn't need it) and only supports one CMake native build per module
  on Android (a project that already uses `externalNativeBuild` is left
  alone and reported as skipped); on iOS it requires CocoaPods and a
  `pod install` (or `flutter build ios`, which runs it for you) after
  generation, and only auto-wires a Podfile with the standard
  `flutter create` `target 'Runner' do` block — anything else is
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
- **v7's known-format matching is a fixed list, not a general secret
  detector.** It catches specific, well-documented credential shapes
  (AWS/Google/Stripe/GitHub/Slack, JWTs, PEM blocks) exactly, and nothing
  outside that list unless it also matches a name pattern or trips the
  entropy check — an internal service's own custom token format, for
  example, still relies on v1's name/entropy detection or an explicit
  `@Secret()` annotation. Likewise, v7's asset auto-detection only ever
  looks at what `pubspec.yaml` itself declares as a Flutter asset and only
  by file extension — an asset directory listed with a nested subfolder
  Flutter doesn't recurse into, or a sensitive file with an unlisted
  extension, still needs an explicit `assets.include` glob.
- **v5 (`certificate_pinning`) doesn't wire itself into your HTTP calls.**
  `PinnedHttpClient` is generated, not adopted for you — any request made
  through a client you didn't swap in (a plugin's own internal `HttpClient`,
  a third-party SDK, a WebView not covered by the Android layer) still
  goes through normal, unpinned validation. And a Frida script that hooks
  `badCertificateCallback` directly, or Android's `NetworkSecurityConfig`/
  OkHttp `CertificatePinner` at the class level, bypasses this outright —
  this is, in fact, the single most common "SSL pinning bypass" script in
  circulation, not a hypothetical. Pair it with v4 tamper detection for
  some defense in depth; treat neither as sufficient alone against a
  targeted attacker.
- **`certificate_pinning.unpinned_hosts: allow` is not "normal HTTPS
  validation."** Enforcing pinning from `dart:io` requires disabling the
  platform's trusted-root store for `PinnedHttpClient` entirely (otherwise
  a certificate that chains to any system-trusted root — including a
  malicious or compromised CA — would pass silently, defeating the point
  of pinning). One consequence: for a host with no configured pin, `allow`
  can only mean "accept any certificate whose validity window covers
  now" — there is no supported way to re-run real chain validation from
  inside that callback once trusted roots are disabled. If a host needs
  real validation, pin it, or route it through a separate, unpinned
  `HttpClient`/`Dio()` instead.
- **No iOS equivalent of the Android `network_security_config.xml`
  layer.** iOS App Transport Security has no declarative SPKI pin-set
  without pulling in a third-party library (e.g. TrustKit), which this
  tool doesn't do. iOS gets pinning only where you've adopted
  `PinnedHttpClient` yourself.
- **Pin rotation and expiry are your responsibility.** This tool doesn't
  fetch or refresh pins — you supply them in `obfuscator.yaml` and re-run
  flutter_obfuscator before a pinned certificate expires or is rotated.
  Listing a primary pin plus a backup for the next certificate avoids
  locking out every installed copy of the app on a routine renewal.

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

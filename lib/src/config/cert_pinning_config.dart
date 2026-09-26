/// What [PinnedHttpClient] (the generated runtime client) does with a host
/// that has no configured pins.
enum UnpinnedHostPolicy {
  /// Reject the connection. Safer default: forces every host you talk to
  /// through `PinnedHttpClient` to be explicitly pinned.
  block,

  /// Accept the connection with only a basic expiry check on the leaf
  /// certificate — see the "Known limitations" note in the README and the
  /// doc comment on the generated client: because pinning here requires
  /// disabling the platform's trusted root store for the whole client,
  /// "allow" does **not** mean "fall back to normal HTTPS validation" —
  /// there is no supported way to do that from `dart:io` once trusted
  /// roots are disabled. Use this only for hosts you're prepared to trust
  /// with no real chain validation, or route them through a separate,
  /// unpinned `HttpClient` instead.
  allow;

  static UnpinnedHostPolicy parse(String? value) {
    switch (value) {
      case null:
      case 'block':
        return UnpinnedHostPolicy.block;
      case 'allow':
        return UnpinnedHostPolicy.allow;
      default:
        throw FormatException(
          'Unknown certificate_pinning.unpinned_hosts "$value" (expected '
          '"block" or "allow")',
        );
    }
  }
}

/// One host's set of pinned SHA-256 SPKI (SubjectPublicKeyInfo) hashes
/// (base64), from `certificate_pinning.pins` in `obfuscator.yaml`. Same
/// format as `openssl x509 -pubkey | openssl pkey -pubin -outform der |
/// openssl dgst -sha256 -binary | base64`, and what Android's
/// `network_security_config.xml` `<pin-set>` expects natively — both
/// generated layers pin the same values.
///
/// List two or more: a primary pin plus at least one backup for the next
/// certificate you'll rotate to, so a routine renewal doesn't lock out
/// every installed copy of the app (SPKI pins survive a renewal that
/// reuses the same keypair; only a keypair change needs a new pin).
class HostPins {
  const HostPins({required this.host, required this.spkiSha256});

  final String host;
  final List<String> spkiSha256;
}

/// Parsed `certificate_pinning:` section of `obfuscator.yaml` (v5, opt-in).
class CertPinningConfig {
  const CertPinningConfig({
    required this.enabled,
    required this.unpinnedHostPolicy,
    required this.hosts,
  });

  final bool enabled;
  final UnpinnedHostPolicy unpinnedHostPolicy;
  final List<HostPins> hosts;

  factory CertPinningConfig.disabled() => const CertPinningConfig(
        enabled: false,
        unpinnedHostPolicy: UnpinnedHostPolicy.block,
        hosts: [],
      );
}

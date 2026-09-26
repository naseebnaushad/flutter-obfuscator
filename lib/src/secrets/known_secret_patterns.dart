/// Well-known hardcoded-credential shapes, matched against a string
/// literal's *value* rather than the variable name it's assigned to.
///
/// The name-pattern + entropy check in [SecretScanner] misses real
/// credentials sitting behind an innocuous name (`final url = 'https://
/// api.example.com/v1?key=AIzaSy...'`, `const cfg = 'sk_live_...'`). These
/// patterns are specific enough (fixed prefixes, fixed lengths) that a
/// match is treated as a secret regardless of the variable's name or the
/// value's Shannon entropy.
class KnownSecretPattern {
  const KnownSecretPattern(this.name, this.pattern);

  final String name;
  final RegExp pattern;
}

final List<KnownSecretPattern> knownSecretPatterns = [
  KnownSecretPattern('AWS Access Key ID', RegExp(r'AKIA[0-9A-Z]{16}')),
  KnownSecretPattern('Google API Key', RegExp(r'AIza[0-9A-Za-z_\-]{35}')),
  KnownSecretPattern(
    'Google OAuth Client ID',
    RegExp(r'[0-9]+-[0-9A-Za-z_]{32}\.apps\.googleusercontent\.com'),
  ),
  KnownSecretPattern(
      'Stripe Live Secret Key', RegExp(r'sk_live_[0-9a-zA-Z]{16,}')),
  KnownSecretPattern('GitHub Token', RegExp(r'gh[pousr]_[0-9A-Za-z]{36,}')),
  KnownSecretPattern('Slack Token', RegExp(r'xox[baprs]-[0-9A-Za-z-]{10,}')),
  KnownSecretPattern(
    'JSON Web Token',
    RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*'),
  ),
  KnownSecretPattern(
    'PEM Private Key',
    RegExp(r'-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'),
  ),
];

/// Returns the name of the first known secret format [value] matches, or
/// `null` if it doesn't look like any of them.
String? matchKnownSecretFormat(String value) {
  for (final candidate in knownSecretPatterns) {
    if (candidate.pattern.hasMatch(value)) return candidate.name;
  }
  return null;
}

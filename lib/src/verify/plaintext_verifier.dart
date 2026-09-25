import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One plaintext-leak check result for a single secret.
class VerificationResult {
  VerificationResult({
    required this.id,
    required this.variableName,
    required this.leaked,
    this.leakedIn,
  });

  final String id;
  final String variableName;
  final bool leaked;

  /// The archive entry name the plaintext was found in, if [leaked].
  final String? leakedIn;
}

/// Post-build sanity check: unpacks the built APK/AAB/IPA and greps its
/// contents for the original plaintext secret values, to confirm the
/// obfuscation pass actually removed them rather than just trusting the
/// transform blindly.
class PlaintextVerifier {
  /// [secrets] maps secret id -> {variableName, plainText}.
  static List<VerificationResult> verify({
    required String artifactPath,
    required List<({String id, String variableName, String plainText})> secrets,
  }) {
    final bytes = File(artifactPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);

    final results = <VerificationResult>[];
    for (final secret in secrets) {
      if (secret.plainText.isEmpty) {
        results.add(VerificationResult(
          id: secret.id,
          variableName: secret.variableName,
          leaked: false,
        ));
        continue;
      }
      final needle = utf8.encode(secret.plainText);
      String? foundIn;
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final content = entry.content;
        if (content is! List<int>) continue;
        if (_containsSubsequence(Uint8List.fromList(content), needle)) {
          foundIn = entry.name;
          break;
        }
      }
      results.add(VerificationResult(
        id: secret.id,
        variableName: secret.variableName,
        leaked: foundIn != null,
        leakedIn: foundIn,
      ));
    }
    return results;
  }

  static bool _containsSubsequence(Uint8List haystack, List<int> needle) {
    if (needle.isEmpty || needle.length > haystack.length) return false;
    final first = needle[0];
    final limit = haystack.length - needle.length;
    for (var i = 0; i <= limit; i++) {
      if (haystack[i] != first) continue;
      var matched = true;
      for (var j = 1; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }
}

import 'dart:io';

import '../secrets/secret_finding.dart';
import '../assets/asset_finding.dart';
import '../native/native_injection_result.dart';
import '../verify/plaintext_verifier.dart';

/// Prints a human-readable summary of what an obfuscation run did, so
/// the output isn't "trust me, it worked."
class Report {
  static void printSummary({
    required List<SecretFinding> secrets,
    required List<SkippedCandidate> skippedSecrets,
    required List<AssetFinding> assets,
    required Set<String> unrewrittenAssetPaths,
    List<NativeInjectionResult> nativeKeyChannelResults = const [],
  }) {
    stdout.writeln('');
    stdout.writeln('flutter_obfuscator summary');
    stdout.writeln('==========================');
    stdout.writeln('Secrets encrypted: ${secrets.length}');
    for (final s in secrets) {
      stdout.writeln('  - ${s.variableName} (${s.filePath}) -> id ${s.id}');
    }
    if (skippedSecrets.isNotEmpty) {
      stdout.writeln('Secret-like declarations skipped: '
          '${skippedSecrets.length} (review these manually)');
      for (final s in skippedSecrets) {
        stdout.writeln('  - ${s.variableName} (${s.filePath}): ${s.reason}');
      }
    }
    stdout.writeln('');
    stdout.writeln('Assets encrypted: ${assets.length}');
    for (final a in assets) {
      stdout.writeln('  - ${a.relativePath} (${a.originalByteLength} bytes)');
    }
    if (unrewrittenAssetPaths.isNotEmpty) {
      stdout.writeln(
          'Encrypted assets with no matching rootBundle call site found '
          '(update these call sites by hand to use AssetVault):');
      for (final path in unrewrittenAssetPaths) {
        stdout.writeln('  - $path');
      }
    }
    if (nativeKeyChannelResults.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln('Native key channel (v2):');
      for (final r in nativeKeyChannelResults) {
        if (r.applied) {
          stdout.writeln('  - ${r.platform}: wired into ${r.entryPointPath}');
        } else {
          stdout.writeln('  - ${r.platform}: NOT wired — ${r.reason}');
        }
      }
    }
    stdout.writeln('');
  }

  static void printVerification(List<VerificationResult> results) {
    stdout.writeln('Plaintext leak verification');
    stdout.writeln('============================');
    var leaks = 0;
    for (final r in results) {
      if (r.leaked) {
        leaks++;
        stdout.writeln('  FAIL  ${r.variableName} (id ${r.id}) still found '
            'in plaintext inside ${r.leakedIn}');
      } else {
        stdout.writeln('  PASS  ${r.variableName} (id ${r.id})');
      }
    }
    stdout.writeln('');
    if (leaks == 0) {
      stdout.writeln('All ${results.length} secret(s) confirmed absent from '
          'the built artifact in plaintext.');
    } else {
      stdout.writeln('$leaks of ${results.length} secret(s) STILL LEAKED. '
          'Investigate before shipping this build.');
    }
  }
}

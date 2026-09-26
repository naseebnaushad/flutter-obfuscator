import 'dart:io';

import 'package:path/path.dart' as p;

import 'assets/asset_call_rewriter.dart';
import 'assets/asset_encryptor.dart';
import 'assets/asset_vault_generator.dart';
import 'build/flutter_build_runner.dart';
import 'config/obfuscator_config.dart';
import 'crypto/key_material.dart';
import 'crypto/key_split_plan.dart';
import 'crypto/key_strategy.dart';
import 'crypto/native_key_channel_generator.dart';
import 'native/android_native_key_generator.dart';
import 'native/android_ndk_key_generator.dart';
import 'native/android_network_security_config_generator.dart';
import 'native/ios_native_key_generator.dart';
import 'native/ios_ndk_key_generator.dart';
import 'native/native_injection_result.dart';
import 'pinning/pinned_http_client_generator.dart';
import 'report/report.dart';
import 'secrets/secret_scanner.dart';
import 'secrets/secret_vault_generator.dart';
import 'staging/project_stager.dart';
import 'tamper/tamper_guard_generator.dart';
import 'verify/plaintext_verifier.dart';

class PipelineResult {
  PipelineResult({required this.stagedProjectRoot, required this.exitCode});
  final String stagedProjectRoot;
  final int exitCode;
}

/// Runs the full obfuscation pipeline against a staged copy of the
/// project: scan+encrypt secrets, encrypt matched assets, rewrite call
/// sites, generate the runtime vaults, wire the `cryptography`
/// dependency, and optionally invoke `flutter build` and the plaintext
/// verifier.
class Pipeline {
  static Future<PipelineResult> run({
    required String sourceRoot,
    required String stagingRoot,
    required ObfuscatorConfig config,
    String? buildTarget,
    String? splitDebugInfoDir,
    bool verify = false,
  }) async {
    stdout.writeln('Staging project from $sourceRoot -> $stagingRoot');
    final packageName = ProjectStager.stage(
      sourceRoot: sourceRoot,
      stagingRoot: stagingRoot,
    );

    final keyBytes = generateKeyBytes();
    final keyMaterial = config.keyStrategy == KeyStrategy.dartSplit
        ? VaultKeyMaterial.generate(keyBytes: keyBytes)
        : null;

    stdout.writeln('Scanning lib/ for hardcoded secrets...');
    final scanner = SecretScanner(config, keyBytes, packageName);
    await scanner.scanDirectory(p.join(stagingRoot, 'lib'));

    stdout.writeln('Encrypting matched assets...');
    final assetEncryptor = AssetEncryptor(keyBytes);
    await assetEncryptor.encryptDirectory(
      projectRoot: stagingRoot,
      includeGlobs: config.assetIncludes,
      excludeGlobs: config.assetExcludes,
    );

    final encryptedAssetPaths =
        assetEncryptor.findings.map((f) => f.relativePath).toSet();
    final unrewritten = AssetCallRewriter.rewriteDirectory(
      libDir: p.join(stagingRoot, 'lib'),
      encryptedAssetPaths: encryptedAssetPaths,
      packageName: packageName,
    );

    if (config.tamperDetection.enabled) {
      stdout.writeln('Wiring tamper detection (TamperGuard)...');
      TamperGuardGenerator.write(
        projectRoot: stagingRoot,
        keyStrategy: config.keyStrategy,
      );
    }

    SecretVaultGenerator.write(
      projectRoot: stagingRoot,
      findings: scanner.findings,
      keyStrategy: config.keyStrategy,
      keyMaterial: keyMaterial,
      tamperConfig: config.tamperDetection,
    );
    if (assetEncryptor.findings.isNotEmpty) {
      AssetVaultGenerator.write(
        projectRoot: stagingRoot,
        keyStrategy: config.keyStrategy,
        tamperConfig: config.tamperDetection,
      );
    }

    var nativeResults = const <NativeInjectionResult>[];
    if (config.keyStrategy.usesNativeChannel) {
      stdout.writeln('Wiring native key channel...');
      NativeKeyChannelGenerator.write(projectRoot: stagingRoot);
      final isNdk = config.keyStrategy == KeyStrategy.nativeNdk;
      final androidResult = isNdk
          ? AndroidNdkKeyGenerator.generate(
              projectRoot: stagingRoot,
              keyBytes: keyBytes,
            )
          : AndroidNativeKeyGenerator.generate(
              projectRoot: stagingRoot,
              keyBytes: keyBytes,
            );
      final iosResult = isNdk
          ? IosNdkKeyGenerator.generate(
              projectRoot: stagingRoot,
              keyBytes: keyBytes,
            )
          : IosNativeKeyGenerator.generate(
              projectRoot: stagingRoot,
              keyBytes: keyBytes,
            );
      nativeResults = [androidResult, iosResult];
    }

    ProjectStager.ensureRuntimeDependency(stagingRoot);

    NativeInjectionResult? androidNetworkSecurityResult;
    if (config.certPinning.enabled) {
      stdout.writeln('Wiring certificate pinning (PinnedHttpClient)...');
      ProjectStager.ensureCryptoDependency(stagingRoot);
      PinnedHttpClientGenerator.write(
        projectRoot: stagingRoot,
        config: config.certPinning,
      );
      androidNetworkSecurityResult =
          AndroidNetworkSecurityConfigGenerator.generate(
        projectRoot: stagingRoot,
        config: config.certPinning,
      );
    }

    Report.printSummary(
      secrets: scanner.findings,
      skippedSecrets: scanner.skipped,
      assets: assetEncryptor.findings,
      unrewrittenAssetPaths: unrewritten,
      nativeKeyChannelResults: nativeResults,
      tamperDetectionEnabled: config.tamperDetection.enabled,
      tamperDetectionMode: config.tamperDetection.mode,
      certPinningEnabled: config.certPinning.enabled,
      certPinningHostCount: config.certPinning.hosts.length,
      androidNetworkSecurityConfigResult: androidNetworkSecurityResult,
    );

    var exitCode = 0;
    if (buildTarget != null) {
      exitCode = await FlutterBuildRunner.build(
        projectRoot: stagingRoot,
        target: buildTarget,
        splitDebugInfoDir:
            splitDebugInfoDir ?? p.join(stagingRoot, 'debug-symbols'),
      );

      if (exitCode == 0 && verify) {
        final artifactPath = _findBuiltArtifact(stagingRoot, buildTarget);
        if (artifactPath == null) {
          stdout
              .writeln('Could not locate a built artifact to verify for target '
                  '"$buildTarget" — skipping plaintext verification.');
        } else {
          final results = PlaintextVerifier.verify(
            artifactPath: artifactPath,
            secrets: scanner.findings
                .map((f) => (
                      id: f.id,
                      variableName: f.variableName,
                      plainText: f.plainText,
                    ))
                .toList(),
          );
          Report.printVerification(results);
        }
      }
    }

    return PipelineResult(stagedProjectRoot: stagingRoot, exitCode: exitCode);
  }

  static String? _findBuiltArtifact(String projectRoot, String target) {
    final candidates = <String>[];
    switch (target) {
      case 'apk':
        candidates
            .add(p.join(projectRoot, 'build', 'app', 'outputs', 'flutter-apk'));
        break;
      case 'appbundle':
        candidates.add(p.join(
            projectRoot, 'build', 'app', 'outputs', 'bundle', 'release'));
        break;
      case 'ipa':
        candidates.add(p.join(projectRoot, 'build', 'ios', 'ipa'));
        break;
    }
    for (final dir in candidates) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      final match = d
          .listSync()
          .whereType<File>()
          .where((f) =>
              f.path.endsWith('.apk') ||
              f.path.endsWith('.aab') ||
              f.path.endsWith('.ipa'))
          .toList();
      if (match.isNotEmpty) return match.first.path;
    }
    return null;
  }
}

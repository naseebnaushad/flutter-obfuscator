import 'dart:io';

import 'package:flutter_obfuscator/src/cli/runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end coverage of the CLI -> Pipeline -> generators wiring — the
/// orchestration layer itself, as opposed to any single generator/scanner
/// in isolation (each of which already has its own unit tests).
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cli_runner_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Directory createFixtureProject(String root) {
    final dir = Directory(root)..createSync(recursive: true);
    File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: sample_app
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
''');
    File(p.join(root, 'lib', 'main.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
const String apiKey = 'sk_live_abcdef1234567890_totally_secret';

void main() {
  print(apiKey);
}
''');
    return dir;
  }

  test('build: stages a copy, encrypts the secret, and leaves the source untouched',
      () async {
    final projectRoot = p.join(tempDir.path, 'project');
    createFixtureProject(projectRoot);
    final outputRoot = p.join(tempDir.path, 'out');

    final exitCode = await runCli([
      'build',
      '--project',
      projectRoot,
      '--output',
      outputRoot,
    ]);

    expect(exitCode, 0);

    final stagedMain =
        File(p.join(outputRoot, 'lib', 'main.dart')).readAsStringSync();
    expect(stagedMain, isNot(contains('sk_live_abcdef1234567890_totally_secret')));
    expect(stagedMain, contains('SecretVault.get('));

    expect(
      File(p.join(outputRoot, 'lib', 'flutter_obfuscator', 'secret_vault.g.dart'))
          .existsSync(),
      isTrue,
    );

    // The original project's source is never touched by `build`.
    final sourceMain =
        File(p.join(projectRoot, 'lib', 'main.dart')).readAsStringSync();
    expect(sourceMain, contains('sk_live_abcdef1234567890_totally_secret'));
  });

  test('apply: rewrites the project in place', () async {
    final projectRoot = p.join(tempDir.path, 'project');
    createFixtureProject(projectRoot);

    final exitCode = await runCli(['apply', '--project', projectRoot]);

    expect(exitCode, 0);
    final mainSource =
        File(p.join(projectRoot, 'lib', 'main.dart')).readAsStringSync();
    expect(mainSource, isNot(contains('sk_live_abcdef1234567890_totally_secret')));
    expect(mainSource, contains('SecretVault.get('));
  });

  test('build respects obfuscator.yaml at the given --config path', () async {
    final projectRoot = p.join(tempDir.path, 'project');
    createFixtureProject(projectRoot);
    File(p.join(projectRoot, 'obfuscator.yaml')).writeAsStringSync('''
identifiers:
  enabled: true
''');
    File(p.join(projectRoot, 'lib', 'main.dart')).writeAsStringSync('''
class _Helper {
  int _value = 1;
}

void main() {
  print(_Helper()._value);
}
''');
    final outputRoot = p.join(tempDir.path, 'out');

    final exitCode = await runCli([
      'build',
      '--project',
      projectRoot,
      '--output',
      outputRoot,
    ]);

    expect(exitCode, 0);
    final stagedMain =
        File(p.join(outputRoot, 'lib', 'main.dart')).readAsStringSync();
    expect(stagedMain, isNot(contains('_Helper')));
  });

  test('returns exit code 1 when --project has no pubspec.yaml', () async {
    final projectRoot = p.join(tempDir.path, 'not_a_project');
    Directory(projectRoot).createSync(recursive: true);

    final exitCode = await runCli(['build', '--project', projectRoot]);

    expect(exitCode, 1);
  });

  test('returns exit code 64 for an unknown command', () async {
    final projectRoot = p.join(tempDir.path, 'project');
    createFixtureProject(projectRoot);

    final exitCode =
        await runCli(['bogus-command', '--project', projectRoot]);

    expect(exitCode, 64);
  });

  test('--help prints usage and returns exit code 0 without touching the project',
      () async {
    final exitCode = await runCli(['--help']);
    expect(exitCode, 0);
  });

  test('no arguments prints usage and returns exit code 0', () async {
    final exitCode = await runCli([]);
    expect(exitCode, 0);
  });

  test('build defaults --output to <project>/build/obfuscated', () async {
    final projectRoot = p.join(tempDir.path, 'project');
    createFixtureProject(projectRoot);

    final exitCode = await runCli(['build', '--project', projectRoot]);

    expect(exitCode, 0);
    expect(
      File(p.join(projectRoot, 'build', 'obfuscated', 'lib', 'main.dart'))
          .existsSync(),
      isTrue,
    );
  });
}

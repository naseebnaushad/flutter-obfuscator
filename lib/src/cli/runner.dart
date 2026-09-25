import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../config/obfuscator_config.dart';
import '../pipeline.dart';

Future<int> runCli(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('project',
        abbr: 'p',
        defaultsTo: '.',
        help: 'Path to the Flutter project to obfuscate.')
    ..addOption('output',
        abbr: 'o',
        help: 'Staging directory for the obfuscated copy. '
            'Defaults to <project>/build/obfuscated.')
    ..addOption('config',
        abbr: 'c',
        defaultsTo: 'obfuscator.yaml',
        help: 'Path to obfuscator.yaml, relative to --project.')
    ..addOption('build',
        abbr: 'b',
        allowed: ['apk', 'appbundle', 'ipa'],
        help: 'Also run `flutter build <target> --obfuscate '
            '--split-debug-info=...` in the staged copy.')
    ..addFlag('verify',
        defaultsTo: false,
        help: 'After --build, scan the built artifact for plaintext '
            'leaks of the secrets that were obfuscated.')
    ..addFlag('help', abbr: 'h', negatable: false);

  late ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    return 64;
  }

  if (args['help'] as bool || args.rest.isEmpty) {
    _printUsage(parser);
    return 0;
  }

  final command = args.rest.first;
  if (command != 'build' && command != 'apply') {
    stderr.writeln('Unknown command "$command". Expected "build" or "apply".');
    _printUsage(parser);
    return 64;
  }

  final projectRoot = p.normalize(p.absolute(args['project'] as String));
  if (!File(p.join(projectRoot, 'pubspec.yaml')).existsSync()) {
    stderr.writeln('No pubspec.yaml found in $projectRoot.');
    return 1;
  }

  final configPath = p.join(projectRoot, args['config'] as String);
  final config = ObfuscatorConfig.load(configPath);

  final stagingRoot = command == 'apply'
      ? projectRoot
      : (args['output'] as String?) ??
          p.join(projectRoot, 'build', 'obfuscated');

  if (command == 'apply') {
    stdout.writeln(
        'WARNING: --apply rewrites the project in place at $projectRoot. '
        'Make sure your working tree is committed/stashed first.');
  }

  final result = await Pipeline.run(
    sourceRoot: projectRoot,
    stagingRoot: stagingRoot,
    config: config,
    buildTarget: args['build'] as String?,
    verify: args['verify'] as bool,
  );

  return result.exitCode;
}

void _printUsage(ArgParser parser) {
  stdout.writeln('''
flutter_obfuscator - encrypts hardcoded secrets and sensitive bundled
assets in a Flutter project so they aren't visible in plaintext under
static analysis (strings/grep/JADX-style extraction) during VAPT.

Usage:
  flutter_obfuscator build [options]   Stage a copy of the project (default:
                                        <project>/build/obfuscated), apply
                                        obfuscation there, optionally build.
  flutter_obfuscator apply [options]   Apply obfuscation IN PLACE on
                                        --project. Commit/stash first.

Options:
${parser.usage}

Note: this defeats static analysis of secrets/assets. It does not defend
against a dynamic attacker using Frida or similar runtime instrumentation.
Native key storage (v2) is not yet implemented.
''');
}

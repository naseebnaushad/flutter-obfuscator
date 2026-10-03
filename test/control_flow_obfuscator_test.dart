import 'dart:io';

import 'package:flutter_obfuscator/src/obfuscate/control_flow_obfuscator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir =
        Directory.systemTemp.createTempSync('flutter_obfuscator_cf_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File writeFile(String relativePath, String content) {
    final file = File(p.join(tempDir.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  test('wraps an if condition with an opaque-false disjunct', () {
    final file = writeFile('lib/a.dart', '''
void check(int n) {
  if (n > 0) {
    print('positive');
  }
}
''');

    final obfuscator = ControlFlowObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    final rewritten = file.readAsStringSync();
    expect(obfuscator.obfuscatedFiles, hasLength(1));
    expect(obfuscator.obfuscatedFiles.single.injectedCount, 1);
    expect(rewritten, contains('(n > 0) || ('));
    // The appended disjunct is an always-false parity check.
    expect(RegExp(r'\|\| \(\d+ % 2 == [01]\)').hasMatch(rewritten), isTrue);
  });

  test('rewrites every if in an if/else-if/else chain independently', () {
    final file = writeFile('lib/b.dart', '''
String classify(int n) {
  if (n < 0) {
    return 'neg';
  } else if (n == 0) {
    return 'zero';
  } else {
    return 'pos';
  }
}
''');

    final obfuscator = ControlFlowObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    expect(obfuscator.obfuscatedFiles.single.injectedCount, 2);
    final rewritten = file.readAsStringSync();
    expect(rewritten, contains('(n < 0) || ('));
    expect(rewritten, contains('(n == 0) || ('));
  });

  test('leaves an if-case pattern match untouched', () {
    final file = writeFile('lib/c.dart', '''
void describe(Object o) {
  if (o case int n) {
    print(n);
  }
}
''');
    final original = file.readAsStringSync();

    final obfuscator = ControlFlowObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    expect(obfuscator.obfuscatedFiles, isEmpty);
    expect(file.readAsStringSync(), original);
  });

  test('leaves a file with no if statements unchanged', () {
    final file = writeFile('lib/plain.dart', '''
int square(int n) => n * n;
''');
    final original = file.readAsStringSync();

    final obfuscator = ControlFlowObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    expect(file.readAsStringSync(), original);
    expect(obfuscator.obfuscatedFiles, isEmpty);
  });

  test('respects the exclude globs (e.g. generated .g.dart files)', () {
    final generated = writeFile('lib/vault.g.dart', '''
void check(int n) {
  if (n > 0) {
    print('positive');
  }
}
''');

    ControlFlowObfuscator().obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const ['**/*.g.dart'],
    );

    expect(generated.readAsStringSync(), contains('if (n > 0) {'));
  });

  test('is behavior-preserving: obfuscated output matches the original',
      () async {
    final dartExecutable = Platform.resolvedExecutable;
    final file = writeFile('script.dart', '''
void main() {
  for (final n in [-3, -1, 0, 1, 4]) {
    if (n < 0) {
      print('neg:\$n');
    } else if (n == 0) {
      print('zero:\$n');
    } else if (n.isEven) {
      print('even:\$n');
    } else {
      print('odd:\$n');
    }
  }
}
''');

    final before = await Process.run(dartExecutable, ['run', file.path]);
    expect(before.exitCode, 0);

    final obfuscator = ControlFlowObfuscator();
    obfuscator.obfuscateDirectory(
      tempDir.path,
      excludeGlobs: const [],
    );
    expect(obfuscator.obfuscatedFiles.single.injectedCount, 3);

    final after = await Process.run(dartExecutable, ['run', file.path]);
    expect(after.exitCode, 0, reason: after.stderr.toString());
    expect(after.stdout, before.stdout);
  });
}

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

  test('wraps a bare if (no else) branch body with an opaque-true guard', () {
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
    // The original condition is untouched.
    expect(rewritten, contains('if (n > 0) {'));
    expect(rewritten, contains("print('positive');"));
    expect(RegExp(r'\{ if \(\d+ % 2 == [01]\) \{').hasMatch(rewritten), isTrue);
  });

  test('wraps both the then and else branch bodies', () {
    final file = writeFile('lib/b.dart', '''
String classify(int n) {
  if (n < 0) {
    return 'neg';
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
    // Original conditions and branch content are fully intact.
    expect(rewritten, contains('if (n < 0) {'));
    expect(rewritten, contains("return 'neg';"));
    expect(rewritten, contains("return 'pos';"));
  });

  test('does not touch an if-case pattern match condition', () {
    final file = writeFile('lib/c.dart', '''
void describe(Object o) {
  if (o case int n) {
    print(n);
  }
}
''');

    final obfuscator = ControlFlowObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    final rewritten = file.readAsStringSync();
    // The condition/case clause is untouched; only the body gets wrapped.
    expect(rewritten, contains('if (o case int n) {'));
    expect(obfuscator.obfuscatedFiles.single.injectedCount, 1);
  });

  test('preserves null-check type promotion (the bug the v1 design had)',
      () async {
    final dartExecutable = Platform.resolvedExecutable;
    // This is exactly the shape that broke under the old condition-
    // rewriting design: wrapping `data != null` as
    // `(data != null) || (<always-false>)` destroys Dart's flow-typing
    // promotion of `data` from `int?` to `int`, so `use(data)` no longer
    // type-checks. Wrapping the branch body instead must leave this
    // untouched.
    final file = writeFile('lib/promo.dart', '''
int use(int n) => n * 2;

void main(List<String> args) {
  int? data = args.isEmpty ? null : int.parse(args.first);
  if (data != null) {
    print(use(data));
  }
}
''');

    final obfuscator = ControlFlowObfuscator();
    obfuscator.obfuscateDirectory(
      tempDir.path,
      excludeGlobs: const [],
    );
    expect(obfuscator.obfuscatedFiles.single.injectedCount, 1);

    final result = await Process.run(dartExecutable, ['analyze', file.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
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
    expect(obfuscator.obfuscatedFiles.single.injectedCount, greaterThan(0));

    final after = await Process.run(dartExecutable, ['run', file.path]);
    expect(after.exitCode, 0, reason: after.stderr.toString());
    expect(after.stdout, before.stdout);
  });
}

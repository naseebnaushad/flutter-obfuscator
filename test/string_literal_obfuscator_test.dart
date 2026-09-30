import 'dart:io';

import 'package:flutter_obfuscator/src/obfuscate/string_literal_obfuscator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir =
        Directory.systemTemp.createTempSync('flutter_obfuscator_str_test_');
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

  test('rewrites a plain runtime string literal into an obfS() call', () {
    final file = writeFile('lib/a.dart', '''
void greet() {
  print('hello there');
}
''');

    final obfuscator = StringLiteralObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
      minLength: 4,
      packageName: 'sample_app',
    );

    final rewritten = file.readAsStringSync();
    expect(rewritten, isNot(contains("'hello there'")));
    expect(rewritten, contains('obfS(0)'));
    expect(
        rewritten,
        contains(
            "import 'package:sample_app/flutter_obfuscator/strings.g.dart';"));
    expect(obfuscator.literalValues, ['hello there']);
  });

  test('leaves literals shorter than min_length untouched', () {
    final file = writeFile('lib/a.dart', '''
void greet() {
  print('hi');
}
''');

    final obfuscator = StringLiteralObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
      minLength: 4,
      packageName: 'sample_app',
    );

    expect(file.readAsStringSync(), contains("'hi'"));
    expect(obfuscator.obfuscatedFiles, isEmpty);
  });

  test('does not touch import/export/part directive strings', () {
    final file = writeFile('lib/a.dart', '''
import 'dart:convert';

void useIt() {
  print(jsonEncode({'greeting': 'hello there'}));
}
''');

    final obfuscator = StringLiteralObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
      minLength: 4,
      packageName: 'sample_app',
    );

    final rewritten = file.readAsStringSync();
    expect(rewritten, contains("import 'dart:convert';"));
    // The map key/value are eligible and get rewritten.
    expect(rewritten, isNot(contains("'greeting'")));
    expect(rewritten, isNot(contains("'hello there'")));
  });

  test('does not touch string literals in const contexts', () {
    final file = writeFile('lib/a.dart', '''
const String label = 'compile time constant';

class Foo {
  static const String other = 'also constant';
}

void useIt() {
  final runtime = 'this one gets rewritten';
  print(runtime);
}
''');

    final obfuscator = StringLiteralObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
      minLength: 4,
      packageName: 'sample_app',
    );

    final rewritten = file.readAsStringSync();
    expect(rewritten, contains("'compile time constant'"));
    expect(rewritten, contains("'also constant'"));
    expect(rewritten, isNot(contains("'this one gets rewritten'")));
  });

  test('does not touch annotation arguments', () {
    final file = writeFile('lib/a.dart', '''
@pragma('vm:entry-point')
void entryPoint() {
  print('runtime message here');
}
''');

    final obfuscator = StringLiteralObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
      minLength: 4,
      packageName: 'sample_app',
    );

    final rewritten = file.readAsStringSync();
    expect(rewritten, contains("@pragma('vm:entry-point')"));
    expect(rewritten, isNot(contains("'runtime message here'")));
  });

  test('does not touch interpolated strings', () {
    final file = writeFile('lib/a.dart', r'''
void greet(String name) {
  print('hello there $name');
}
''');

    final obfuscator = StringLiteralObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
      minLength: 4,
      packageName: 'sample_app',
    );

    expect(file.readAsStringSync(), contains(r"'hello there $name'"));
    expect(obfuscator.obfuscatedFiles, isEmpty);
  });

  test('deduplicates identical literals into one table entry', () {
    writeFile('lib/a.dart', '''
void a() => print('duplicate value');
''');
    writeFile('lib/b.dart', '''
void b() => print('duplicate value');
''');

    final obfuscator = StringLiteralObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
      minLength: 4,
      packageName: 'sample_app',
    );

    expect(obfuscator.literalValues, ['duplicate value']);
    final a = File(p.join(tempDir.path, 'lib', 'a.dart')).readAsStringSync();
    final b = File(p.join(tempDir.path, 'lib', 'b.dart')).readAsStringSync();
    expect(a, contains('obfS(0)'));
    expect(b, contains('obfS(0)'));
  });

  test('respects the exclude globs (e.g. generated .g.dart files)', () {
    final generated = writeFile('lib/flutter_obfuscator/vault.g.dart', '''
const String generatedMessage = 'do not touch this generated value';
''');

    StringLiteralObfuscator().obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const ['**/*.g.dart'],
      minLength: 4,
      packageName: 'sample_app',
    );

    expect(generated.readAsStringSync(),
        contains("'do not touch this generated value'"));
  });
}

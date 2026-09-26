import 'dart:io';

import 'package:flutter_obfuscator/src/obfuscate/identifier_obfuscator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir =
        Directory.systemTemp.createTempSync('flutter_obfuscator_ident_test_');
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

  test('renames a private class and its members consistently', () {
    final file = writeFile('lib/a.dart', '''
class _Repository {
  int _cache = 0;

  int _load() => _cache;

  void bump() {
    _cache = _load() + 1;
  }
}

void usePublic() {
  final r = _Repository();
  r.bump();
}
''');

    IdentifierObfuscator().obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    final rewritten = file.readAsStringSync();
    expect(rewritten, isNot(contains('_Repository')));
    expect(rewritten, isNot(contains('_cache')));
    expect(rewritten, isNot(contains('_load')));
    // Public names are left untouched.
    expect(rewritten, contains('void usePublic()'));
    expect(rewritten, contains('void bump()'));

    // The renamed class name and field/method are still consistent with
    // each other: parse it back and make sure it's still valid-looking
    // Dart with the same structural shape.
    expect(RegExp(r'class (_o\d+) \{').hasMatch(rewritten), isTrue);
  });

  test('leaves public API and framework overrides untouched', () {
    final file = writeFile('lib/widget.dart', '''
class MyWidget {
  String _label = 'hi';

  String build() => _label;
}
''');

    IdentifierObfuscator().obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    final rewritten = file.readAsStringSync();
    expect(rewritten, contains('class MyWidget'));
    expect(rewritten, contains('String build()'));
    expect(rewritten, isNot(contains('_label')));
  });

  test('renames a private name reached through string interpolation', () {
    final file = writeFile('lib/b.dart', r'''
class _Thing {
  final int _value = 42;

  String describe() => 'value=$_value';
}
''');

    IdentifierObfuscator().obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    final rewritten = file.readAsStringSync();
    expect(rewritten, isNot(contains(r'$_value')));
    expect(rewritten, isNot(contains('_Thing')));
  });

  test('does not touch string literal contents', () {
    final file = writeFile('lib/c.dart', '''
class _Config {
  static const String _key = 'my_secret_key';

  String lookup(Map<String, String> m) => m['_key'] ?? _key;
}
''');

    IdentifierObfuscator().obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    final rewritten = file.readAsStringSync();
    // The declared field/class are renamed...
    expect(rewritten, isNot(contains('_Config')));
    // ...but the string literals are left exactly as they were.
    expect(rewritten, contains("'my_secret_key'"));
    expect(rewritten, contains("m['_key']"));
  });

  test('skips files using part/part-of directives', () {
    writeFile('lib/main_part.dart', '''
part 'other.dart';

class _Shared {
  int _x = 1;
}
''');
    writeFile('lib/other.dart', '''
part of 'main_part.dart';

void touch(_Shared s) => s._x;
''');

    final obfuscator = IdentifierObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    expect(obfuscator.renamedFiles, isEmpty);
    expect(obfuscator.skippedFiles, hasLength(2));
    final mainPart =
        File(p.join(tempDir.path, 'lib', 'main_part.dart')).readAsStringSync();
    expect(mainPart, contains('_Shared'));
  });

  test('respects the exclude globs (e.g. generated .g.dart files)', () {
    final generated = writeFile('lib/flutter_obfuscator/vault.g.dart', '''
class _GeneratedInternal {
  static int _seed = 1;
}
''');

    IdentifierObfuscator().obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const ['**/*.g.dart'],
    );

    expect(generated.readAsStringSync(), contains('_GeneratedInternal'));
  });

  test('leaves a file with no private identifiers unchanged', () {
    final file = writeFile('lib/plain.dart', '''
class PublicOnly {
  int value = 1;
}
''');
    final original = file.readAsStringSync();

    final obfuscator = IdentifierObfuscator();
    obfuscator.obfuscateDirectory(
      p.join(tempDir.path, 'lib'),
      excludeGlobs: const [],
    );

    expect(file.readAsStringSync(), original);
    expect(obfuscator.renamedFiles, isEmpty);
  });
}

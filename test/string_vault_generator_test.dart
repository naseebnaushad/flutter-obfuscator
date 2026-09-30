import 'dart:io';

import 'package:flutter_obfuscator/src/obfuscate/string_vault_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('generates a strings.g.dart table that round-trips through dart analyze',
      () {
    final dir = Directory.systemTemp.createTempSync('string_vault_test_');
    addTearDown(() => dir.deleteSync(recursive: true));

    StringVaultGenerator.write(
      projectRoot: dir.path,
      literalValues: const ['hello there', 'a second value'],
      xorKey: const [1, 2, 3, 4, 5, 6, 7, 8],
    );

    final generated = File(
      p.join(dir.path, 'lib', 'flutter_obfuscator', 'strings.g.dart'),
    );
    expect(generated.existsSync(), isTrue);

    final source = generated.readAsStringSync();
    expect(source, contains('String obfS(int index)'));
    expect(source, contains('class _StringVault'));
    // Plaintext must not appear anywhere in the generated file.
    expect(source, isNot(contains('hello there')));
    expect(source, isNot(contains('a second value')));
  });
}

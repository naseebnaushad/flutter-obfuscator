import 'dart:io';

import 'package:flutter_obfuscator/src/staging/project_stager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('project_stager_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  void writePubspec(String projectRoot, {String name = 'sample_app'}) {
    Directory(projectRoot).createSync(recursive: true);
    File(p.join(projectRoot, 'pubspec.yaml')).writeAsStringSync('name: $name\n');
  }

  test('copies sourceRoot into a distinct stagingRoot', () {
    final sourceRoot = p.join(tempDir.path, 'source');
    writePubspec(sourceRoot);
    File(p.join(sourceRoot, 'lib.dart')).writeAsStringSync('// hi');

    final stagingRoot = p.join(tempDir.path, 'staged');
    final packageName =
        ProjectStager.stage(sourceRoot: sourceRoot, stagingRoot: stagingRoot);

    expect(packageName, 'sample_app');
    expect(File(p.join(stagingRoot, 'lib.dart')).existsSync(), isTrue);
    // Source untouched.
    expect(File(p.join(sourceRoot, 'lib.dart')).existsSync(), isTrue);
  });

  test('wipes an existing stagingRoot before copying', () {
    final sourceRoot = p.join(tempDir.path, 'source');
    writePubspec(sourceRoot);

    final stagingRoot = p.join(tempDir.path, 'staged');
    Directory(stagingRoot).createSync(recursive: true);
    File(p.join(stagingRoot, 'stale.txt')).writeAsStringSync('old');

    ProjectStager.stage(sourceRoot: sourceRoot, stagingRoot: stagingRoot);

    expect(File(p.join(stagingRoot, 'stale.txt')).existsSync(), isFalse);
  });

  test(
      'does not destroy the project when sourceRoot and stagingRoot are the '
      'same directory (apply command, in-place mode)', () {
    final projectRoot = p.join(tempDir.path, 'project');
    writePubspec(projectRoot);
    File(p.join(projectRoot, 'lib.dart')).writeAsStringSync('// hi');

    final packageName = ProjectStager.stage(
      sourceRoot: projectRoot,
      stagingRoot: projectRoot,
    );

    expect(packageName, 'sample_app');
    expect(File(p.join(projectRoot, 'lib.dart')).existsSync(), isTrue);
    expect(File(p.join(projectRoot, 'pubspec.yaml')).existsSync(), isTrue);
  });

  test('treats equivalent but differently-written paths as the same '
      'directory', () {
    final projectRoot = p.join(tempDir.path, 'project');
    writePubspec(projectRoot);
    File(p.join(projectRoot, 'lib.dart')).writeAsStringSync('// hi');

    // Same directory, written with a redundant "./" segment.
    final stagingRootAlt = p.join(tempDir.path, 'project', '.');

    ProjectStager.stage(sourceRoot: projectRoot, stagingRoot: stagingRootAlt);

    expect(File(p.join(projectRoot, 'lib.dart')).existsSync(), isTrue);
  });
}

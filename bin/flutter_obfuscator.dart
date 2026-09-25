import 'dart:io';

import 'package:flutter_obfuscator/src/cli/runner.dart';

Future<void> main(List<String> arguments) async {
  final code = await runCli(arguments);
  exit(code);
}

import 'package:flutter/services.dart' show rootBundle;

import 'config.dart';

Future<String> loadSecretsJson() async {
  return rootBundle.loadString('assets/config/secrets.json');
}

void main() {
  print('$kApiKey ${RemoteConfig.authToken} ${RemoteConfig.baseUrl}');
}

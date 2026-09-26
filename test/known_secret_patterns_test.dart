import 'package:flutter_obfuscator/src/secrets/known_secret_patterns.dart';
import 'package:test/test.dart';

void main() {
  // Values below are split with string concatenation so no single
  // contiguous credential-shaped literal sits in this file for a secret
  // scanner (GitHub push protection included) to flag — these are inert
  // fixture strings, never real credentials.

  test('recognizes an AWS access key id', () {
    const value = 'AKIA' 'IOSFODNN7' 'EXAMPLE';
    expect(matchKnownSecretFormat(value), 'AWS Access Key ID');
  });

  test('recognizes a Google API key', () {
    const value = 'AIza' 'SyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWQ';
    expect(matchKnownSecretFormat(value), 'Google API Key');
  });

  test('recognizes a Stripe live secret key', () {
    const value = 'sk_live_' '4eC39HqLyjWDarjtT1zdp7dc';
    expect(matchKnownSecretFormat(value), 'Stripe Live Secret Key');
  });

  test('recognizes a GitHub token', () {
    const value = 'ghp_' '16C7e42F292c6912E7710c838347Ae178B4a';
    expect(matchKnownSecretFormat(value), 'GitHub Token');
  });

  test('recognizes a JWT', () {
    const jwt = 'eyJhbGciOiJIUzI1NiJ9.'
        'eyJzdWIiOiIxIn0.'
        'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
    expect(matchKnownSecretFormat(jwt), 'JSON Web Token');
  });

  test('recognizes a PEM private key block', () {
    const value = '-----BEGIN RSA PRIVATE KEY-----' '\nMIIExAMPLE';
    expect(matchKnownSecretFormat(value), 'PEM Private Key');
  });

  test('does not flag an ordinary URL', () {
    expect(matchKnownSecretFormat('https://api.example.com/v1/users'), isNull);
  });
}

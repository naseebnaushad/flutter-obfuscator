import 'package:flutter_obfuscator/src/secrets/entropy.dart';
import 'package:test/test.dart';

void main() {
  test('low-entropy repeated string scores low', () {
    expect(shannonEntropy('aaaaaaaaaa'), lessThan(1.0));
  });

  test('a real-looking random token scores high', () {
    expect(
        shannonEntropy('zY8f2QpL9wR3kM7nT1vX5jH0cB6sD4gE'), greaterThan(3.5));
  });

  test('empty string has zero entropy', () {
    expect(shannonEntropy(''), 0);
  });
}

/// One bundled asset that was encrypted in place.
class AssetFinding {
  AssetFinding({
    required this.relativePath,
    required this.originalByteLength,
  });

  /// Path relative to the project root, e.g. `assets/config/api.json`.
  /// This is also the Flutter "logical" asset path used in
  /// `rootBundle.load(...)` calls, so encrypting in place (same path,
  /// container-wrapped bytes) means no pubspec.yaml changes are needed.
  final String relativePath;

  final int originalByteLength;
}

/// Outcome of trying to wire the native (Android/iOS) key channel into a
/// project's generated entry-point file (MainActivity / AppDelegate).
///
/// Injection is best-effort: if the entry-point file doesn't look like a
/// standard `flutter create` output, we skip it rather than risk
/// corrupting hand-modified native code, and surface [reason] so the run
/// summary can tell the user to wire it up by hand.
class NativeInjectionResult {
  NativeInjectionResult({
    required this.platform,
    required this.applied,
    this.entryPointPath,
    this.pluginFilePath,
    this.reason,
  });

  final String platform; // 'android' | 'ios'
  final bool applied;
  final String? entryPointPath;
  final String? pluginFilePath;
  final String? reason;
}

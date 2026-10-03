/// Parsed `control_flow:` section of `obfuscator.yaml` (v11, opt-in).
class ControlFlowConfig {
  const ControlFlowConfig({required this.enabled});

  final bool enabled;

  factory ControlFlowConfig.disabled() =>
      const ControlFlowConfig(enabled: false);
}

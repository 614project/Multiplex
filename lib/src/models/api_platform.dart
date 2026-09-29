/// The kind of server a project talks to.
enum ApiPlatform {
  webUi('WebUI', 'http://127.0.0.1:7860'),
  comfyUi('ComfyUI', 'http://127.0.0.1:8188');

  const ApiPlatform(this.label, this.defaultBaseUrl);

  /// Name used in project files and exports (kept compatible with WebuiMultiflex).
  final String label;
  final String defaultBaseUrl;

  bool get isWebUi => this == ApiPlatform.webUi;
  bool get isComfyUi => this == ApiPlatform.comfyUi;

  static ApiPlatform parse(String? value) {
    return value != null && value.trim().toLowerCase() == 'comfyui'
        ? ApiPlatform.comfyUi
        : ApiPlatform.webUi;
  }
}

/// WebUI generation strategies. ComfyUI always uses [standard].
abstract final class GenerationModes {
  static const standard = 'Standard';
  static const pollingProxySafe = 'Polling (Proxy Safe)';
  static const agentScheduler = 'Agent Scheduler';

  static const all = <String>[standard, pollingProxySafe, agentScheduler];

  static List<String> optionsFor(ApiPlatform platform) =>
      platform.isComfyUi ? const [standard] : all;

  static String normalizeForPlatform(ApiPlatform platform, String? mode) {
    if (platform.isComfyUi) {
      return standard;
    }

    return all.contains(mode) ? mode! : standard;
  }

  static String describe(String mode) => switch (mode) {
        pollingProxySafe =>
          'Polls progress while waiting and recovers the final preview if a proxy drops the response.',
        agentScheduler =>
          'Queues work through the Agent Scheduler extension and collects results as they finish.',
        _ => 'Sends txt2img directly and waits for the image.',
      };
}

abstract final class ComfyLoraLoaderTypes {
  static const loraLoader = 'LoraLoader';
  static const loraLoaderModelOnly = 'LoraLoaderModelOnly';

  static const all = <String>[loraLoader, loraLoaderModelOnly];

  static String normalize(String? value) {
    return value != null && value.toLowerCase() == loraLoaderModelOnly.toLowerCase()
        ? loraLoaderModelOnly
        : loraLoader;
  }
}

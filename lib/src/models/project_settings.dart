import '../core/json_read.dart';
import '../core/path_safety.dart';
import 'api_platform.dart';
import 'img2img.dart';
import 'lora_selection.dart';

/// Shared generation settings of a project. Values that mean "use the app default" are stored as
/// empty strings or zero, exactly like WebuiMultiflex did, so exports stay interchangeable.
class ProjectSettings {
  ProjectSettings({
    this.apiBaseUrl = '',
    this.platform = ApiPlatform.webUi,
    this.timeoutSeconds = 0,
    this.generationMode = '',
    this.clipSkip = 0,
    this.commonPrompt = '',
    this.negativePrompt = '',
    this.overrideGlobalCommonPrompt = false,
    this.globalCommonPromptOverride = '',
    this.overrideGlobalNegativePrompt = false,
    this.globalNegativePromptOverride = '',
    this.steps = 20,
    this.cfgScale = 7.0,
    this.width = 512,
    this.height = 512,
    this.samplerName = 'Euler a',
    this.scheduler = 'Automatic',
    this.checkpointModel = '',
    List<LoraSelection>? selectedLoras,
    this.comfyLoraLoaderType = ComfyLoraLoaderTypes.loraLoader,
    this.seed = -1,
    this.enableHiresFix = false,
    this.hiresScale = 2.0,
    this.hiresUpscaler = 'Latent',
    this.hiresSteps = 0,
    this.hiresDenoisingStrength = 0.7,
    this.hiresResizeWidth = 0,
    this.hiresResizeHeight = 0,
    this.generationType = GenerationType.txt2img,
    this.sourceImagePath = '',
    this.denoisingStrength = Img2ImgDefaults.denoisingStrength,
    this.resizeMode = Img2ImgResizeModes.justResize,
    this.useSourceImageSize = true,
  }) : selectedLoras = selectedLoras ?? <LoraSelection>[];

  String apiBaseUrl;
  ApiPlatform platform;

  /// 0 means "use the app default timeout".
  int timeoutSeconds;

  /// Empty means "use the app default generation mode".
  String generationMode;

  /// 0 means "use the app default CLIP skip".
  int clipSkip;
  String commonPrompt;
  String negativePrompt;
  bool overrideGlobalCommonPrompt;
  String globalCommonPromptOverride;
  bool overrideGlobalNegativePrompt;
  String globalNegativePromptOverride;
  int steps;
  double cfgScale;
  int width;
  int height;
  String samplerName;
  String scheduler;

  /// Empty means "use whatever the server currently has loaded" (WebUI) or "first checkpoint" (ComfyUI).
  String checkpointModel;
  List<LoraSelection> selectedLoras;
  String comfyLoraLoaderType;
  int seed;
  bool enableHiresFix;
  double hiresScale;
  String hiresUpscaler;
  int hiresSteps;
  double hiresDenoisingStrength;
  int hiresResizeWidth;
  int hiresResizeHeight;

  GenerationType generationType;

  /// The project's source image for img2img, relative to the project folder; empty when unset.
  /// Cells can use their own source image instead.
  String sourceImagePath;
  double denoisingStrength;
  String resizeMode;

  /// img2img output size follows each source image (rounded to a multiple of 8) instead of
  /// [width] × [height]. Cell size overrides still win.
  bool useSourceImageSize;

  bool get isImg2Img => generationType.isImg2Img;

  ProjectSettings copy() => ProjectSettings.fromJson(toJson());

  /// Clamps values into the ranges the generators accept.
  void normalize() {
    platform = ApiPlatform.parse(platform.label);
    apiBaseUrl = apiBaseUrl.trim();
    timeoutSeconds = timeoutSeconds < 0 ? 0 : timeoutSeconds;
    generationMode = generationMode.isEmpty ? '' : GenerationModes.normalizeForPlatform(platform, generationMode);
    if (platform.isComfyUi) {
      generationMode = GenerationModes.standard;
    }

    clipSkip = clipSkip < 1 ? 0 : clipSkip.clamp(1, 24);
    steps = steps < 1 ? 1 : steps;
    cfgScale = _finite(cfgScale, 7.0) < 1 ? 1 : _finite(cfgScale, 7.0);
    width = width < 64 ? 64 : width;
    height = height < 64 ? 64 : height;
    selectedLoras = LoraSelection.normalize(selectedLoras);
    comfyLoraLoaderType = ComfyLoraLoaderTypes.normalize(comfyLoraLoaderType);
    seed = seed < -1 ? -1 : seed;
    hiresScale = _finite(hiresScale, 2.0) < 1 ? 1 : _finite(hiresScale, 2.0);
    hiresSteps = hiresSteps < 0 ? 0 : hiresSteps;
    hiresDenoisingStrength = _finite(hiresDenoisingStrength, 0.7).clamp(0.0, 1.0).toDouble();
    hiresResizeWidth = hiresResizeWidth < 0 ? 0 : hiresResizeWidth;
    hiresResizeHeight = hiresResizeHeight < 0 ? 0 : hiresResizeHeight;
    // Project files can be imported from anywhere, so the source image must stay inside the project.
    sourceImagePath = PathSafety.isSafeRelativePath(sourceImagePath) ? sourceImagePath.replaceAll('\\', '/') : '';
    denoisingStrength = _finite(denoisingStrength, Img2ImgDefaults.denoisingStrength).clamp(0.0, 1.0).toDouble();
    resizeMode = Img2ImgResizeModes.normalize(resizeMode);
  }

  Map<String, Object?> toJson() => {
    'apiBaseUrl': apiBaseUrl,
    'platform': platform.label,
    'timeoutSeconds': timeoutSeconds,
    'generationMode': generationMode,
    'clipSkip': clipSkip,
    'commonPrompt': commonPrompt,
    'negativePrompt': negativePrompt,
    'overrideGlobalCommonPrompt': overrideGlobalCommonPrompt,
    'globalCommonPromptOverride': globalCommonPromptOverride,
    'overrideGlobalNegativePrompt': overrideGlobalNegativePrompt,
    'globalNegativePromptOverride': globalNegativePromptOverride,
    'steps': steps,
    'cfgScale': cfgScale,
    'width': width,
    'height': height,
    'samplerName': samplerName,
    'scheduler': scheduler,
    'checkpointModel': checkpointModel,
    'selectedLoras': selectedLoras.map((lora) => lora.toJson()).toList(),
    'comfyLoraLoaderType': comfyLoraLoaderType,
    'seed': seed,
    'enableHiresFix': enableHiresFix,
    'hiresScale': hiresScale,
    'hiresUpscaler': hiresUpscaler,
    'hiresSteps': hiresSteps,
    'hiresDenoisingStrength': hiresDenoisingStrength,
    'hiresResizeWidth': hiresResizeWidth,
    'hiresResizeHeight': hiresResizeHeight,
    'generationType': generationType.id,
    'sourceImagePath': sourceImagePath,
    'denoisingStrength': denoisingStrength,
    'resizeMode': resizeMode,
    'useSourceImageSize': useSourceImageSize,
  };

  /// Reads Multiplex project files as well as the `Settings` object of WebuiMultiflex exports.
  factory ProjectSettings.fromJson(Object? json) {
    final map = JsonRead.map(json) ?? const <String, Object?>{};
    final defaults = ProjectSettings();
    final settings = ProjectSettings(
      apiBaseUrl: JsonRead.string(map, 'apiBaseUrl') ?? defaults.apiBaseUrl,
      platform: ApiPlatform.parse(JsonRead.string(map, 'platform')),
      timeoutSeconds: JsonRead.integer(map, 'timeoutSeconds') ?? defaults.timeoutSeconds,
      generationMode: JsonRead.string(map, 'generationMode') ?? defaults.generationMode,
      clipSkip: JsonRead.integer(map, 'clipSkip') ?? defaults.clipSkip,
      commonPrompt: JsonRead.string(map, 'commonPrompt') ?? '',
      negativePrompt: JsonRead.string(map, 'negativePrompt') ?? '',
      overrideGlobalCommonPrompt: JsonRead.boolean(map, 'overrideGlobalCommonPrompt') ?? false,
      globalCommonPromptOverride: JsonRead.string(map, 'globalCommonPromptOverride') ?? '',
      overrideGlobalNegativePrompt: JsonRead.boolean(map, 'overrideGlobalNegativePrompt') ?? false,
      globalNegativePromptOverride: JsonRead.string(map, 'globalNegativePromptOverride') ?? '',
      steps: JsonRead.integer(map, 'steps') ?? defaults.steps,
      cfgScale: JsonRead.number(map, 'cfgScale')?.toDouble() ?? defaults.cfgScale,
      width: JsonRead.integer(map, 'width') ?? defaults.width,
      height: JsonRead.integer(map, 'height') ?? defaults.height,
      samplerName: _nonEmpty(JsonRead.string(map, 'samplerName'), defaults.samplerName),
      scheduler: _nonEmpty(JsonRead.string(map, 'scheduler'), defaults.scheduler),
      checkpointModel: JsonRead.string(map, 'checkpointModel') ?? '',
      selectedLoras: (JsonRead.list(JsonRead.value(map, 'selectedLoras')) ?? const [])
          .map(LoraSelection.fromJson)
          .whereType<LoraSelection>()
          .toList(),
      comfyLoraLoaderType: JsonRead.string(map, 'comfyLoraLoaderType') ?? defaults.comfyLoraLoaderType,
      seed: JsonRead.integer(map, 'seed') ?? defaults.seed,
      enableHiresFix: JsonRead.boolean(map, 'enableHiresFix') ?? false,
      hiresScale: JsonRead.number(map, 'hiresScale')?.toDouble() ?? defaults.hiresScale,
      hiresUpscaler: _nonEmpty(JsonRead.string(map, 'hiresUpscaler'), defaults.hiresUpscaler),
      hiresSteps: JsonRead.integer(map, 'hiresSteps') ?? 0,
      hiresDenoisingStrength:
          JsonRead.number(map, 'hiresDenoisingStrength')?.toDouble() ?? defaults.hiresDenoisingStrength,
      hiresResizeWidth: JsonRead.integer(map, 'hiresResizeWidth') ?? 0,
      hiresResizeHeight: JsonRead.integer(map, 'hiresResizeHeight') ?? 0,
      generationType: GenerationType.parse(JsonRead.string(map, 'generationType')),
      sourceImagePath: JsonRead.string(map, 'sourceImagePath') ?? '',
      denoisingStrength: JsonRead.number(map, 'denoisingStrength')?.toDouble() ?? defaults.denoisingStrength,
      resizeMode: JsonRead.string(map, 'resizeMode') ?? defaults.resizeMode,
      useSourceImageSize: JsonRead.boolean(map, 'useSourceImageSize') ?? defaults.useSourceImageSize,
    );
    settings.normalize();
    return settings;
  }

  static String _nonEmpty(String? value, String fallback) => value == null || value.trim().isEmpty ? fallback : value;

  static double _finite(double value, double fallback) => value.isNaN || value.isInfinite ? fallback : value;
}

import '../models/api_platform.dart';
import '../models/lora_selection.dart';
import '../models/project_data.dart';

/// Immutable copy of a cell taken when a job is queued, so later prompt edits only affect new jobs.
class CellSnapshot {
  const CellSnapshot({
    required this.id,
    required this.displayName,
    required this.prompt,
    this.overrideSteps,
    this.overrideCfgScale,
    this.overrideWidth,
    this.overrideHeight,
    this.overrideNegativePrompt = '',
  });

  factory CellSnapshot.fromData(CellData cell, String displayName) => CellSnapshot(
        id: cell.id,
        displayName: displayName,
        prompt: cell.prompt,
        overrideSteps: cell.overrideSteps,
        overrideCfgScale: cell.overrideCfgScale,
        overrideWidth: cell.overrideWidth,
        overrideHeight: cell.overrideHeight,
        overrideNegativePrompt: cell.overrideNegativePrompt,
      );

  final String id;
  final String displayName;
  final String prompt;
  final int? overrideSteps;
  final double? overrideCfgScale;
  final int? overrideWidth;
  final int? overrideHeight;
  final String overrideNegativePrompt;
}

/// Everything a queued job needs, resolved against the app defaults at the moment it was queued.
class GenerationContext {
  const GenerationContext({
    required this.projectId,
    required this.projectName,
    required this.apiBaseUrl,
    required this.platform,
    required this.timeout,
    required this.generationMode,
    required this.clipSkip,
    required this.globalCommonPrompt,
    required this.commonPrompt,
    required this.globalNegativePrompt,
    required this.negativePrompt,
    required this.steps,
    required this.cfgScale,
    required this.width,
    required this.height,
    required this.samplerName,
    required this.scheduler,
    required this.checkpointModel,
    required this.selectedLoras,
    required this.comfyLoraLoaderType,
    required this.seed,
    required this.enableHiresFix,
    required this.hiresScale,
    required this.hiresUpscaler,
    required this.hiresSteps,
    required this.hiresDenoisingStrength,
    required this.hiresResizeWidth,
    required this.hiresResizeHeight,
    required this.pollingRecoveryGraceSeconds,
    required this.repeatCount,
    required this.targets,
  });

  final String projectId;
  final String projectName;
  final String apiBaseUrl;
  final ApiPlatform platform;
  final Duration timeout;
  final String generationMode;
  final int clipSkip;
  final String globalCommonPrompt;
  final String commonPrompt;
  final String globalNegativePrompt;
  final String negativePrompt;
  final int steps;
  final double cfgScale;
  final int width;
  final int height;
  final String samplerName;
  final String scheduler;
  final String checkpointModel;
  final List<LoraSelection> selectedLoras;
  final String comfyLoraLoaderType;
  final int seed;
  final bool enableHiresFix;
  final double hiresScale;
  final String hiresUpscaler;
  final int hiresSteps;
  final double hiresDenoisingStrength;
  final int hiresResizeWidth;
  final int hiresResizeHeight;
  final int pollingRecoveryGraceSeconds;
  final int repeatCount;

  /// Cells in round-robin order: every selected cell once per round, [repeatCount] rounds.
  final List<CellSnapshot> targets;

  bool get isAgentSchedulerMode => platform.isWebUi && generationMode == GenerationModes.agentScheduler;
  bool get isPollingMode => platform.isWebUi && generationMode == GenerationModes.pollingProxySafe;

  static List<CellSnapshot> roundRobin(List<CellSnapshot> cells, int repeatCount) => [
        for (var round = 0; round < (repeatCount < 1 ? 1 : repeatCount); round++) ...cells,
      ];
}

/// One entry of a project's generation queue.
class GenerationJob {
  GenerationJob({
    required this.sequence,
    required this.context,
    required this.title,
    required this.description,
  })  : createdAt = DateTime.now(),
        totalImages = context.targets.length,
        cellCount = context.targets.map((cell) => cell.id).toSet().length;

  final int sequence;
  final GenerationContext context;
  final String title;
  final String description;
  final DateTime createdAt;
  final int totalImages;
  final int cellCount;
  int completedImages = 0;
  String status = 'Queued';

  /// Progress of the image currently being generated (0-1), when the server reports it.
  double? imageProgress;

  double get fraction {
    if (totalImages == 0) {
      return 0;
    }

    final partial = (imageProgress ?? 0).clamp(0.0, 1.0);
    return ((completedImages + partial) / totalImages).clamp(0.0, 1.0);
  }

  String get progressText => '$completedImages/$totalImages';

  static GenerationJob create(int sequence, GenerationContext context) {
    final cellCount = context.targets.map((cell) => cell.id).toSet().length;
    final firstName = context.targets.isEmpty ? 'Cell' : context.targets.first.displayName;
    final rounds = context.repeatCount;
    final images = context.targets.length;
    return GenerationJob(
      sequence: sequence,
      context: context,
      title: cellCount == 1 ? firstName : '$cellCount cells',
      description: '${context.platform.label} · $rounds round${rounds == 1 ? '' : 's'} · '
          '$images image${images == 1 ? '' : 's'}',
    );
  }
}

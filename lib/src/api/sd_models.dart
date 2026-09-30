import 'dart:convert';
import 'dart:typed_data';

import '../core/json_read.dart';
import '../models/api_platform.dart';
import '../models/img2img.dart';
import '../models/lora_selection.dart';

/// The source image of an img2img request.
class Img2ImgSource {
  const Img2ImgSource({required this.bytes, required this.width, required this.height, required this.fileName});

  final Uint8List bytes;
  final int width;
  final int height;

  /// Stable name of the stored source file; used for the ComfyUI upload.
  final String fileName;
}

/// Body of `POST /sdapi/v1/txt2img`, or of `/sdapi/v1/img2img` when [source] is set. The same request
/// is queued through Agent Scheduler and translated into a ComfyUI workflow. Null fields are omitted
/// from the JSON.
class GenerationRequest {
  GenerationRequest({
    this.prompt = '',
    this.negativePrompt,
    this.steps = 20,
    this.cfgScale = 7,
    this.width = 512,
    this.height = 512,
    this.samplerName,
    this.scheduler,
    this.seed = -1,
    this.forceTaskId,
    this.sdModelCheckpoint,
    this.clipStopAtLastLayers,
    this.enableHiresFix,
    this.hiresScale,
    this.hiresUpscaler,
    this.hiresSteps,
    this.hiresSamplerName,
    this.hiresScheduler,
    this.hiresDenoisingStrength,
    this.hiresResizeX,
    this.hiresResizeY,
    this.clipSkip = 1,
    this.selectedLoras = const [],
    this.comfyLoraLoaderType = ComfyLoraLoaderTypes.loraLoader,
    this.source,
    this.denoisingStrength = Img2ImgDefaults.denoisingStrength,
    this.resizeMode = Img2ImgResizeModes.justResize,
  });

  String prompt;
  String? negativePrompt;
  int steps;
  double cfgScale;
  int width;
  int height;
  String? samplerName;
  String? scheduler;
  int seed;
  String? forceTaskId;

  /// Sent through `override_settings.sd_model_checkpoint`.
  String? sdModelCheckpoint;

  /// Sent through `override_settings.CLIP_stop_at_last_layers`.
  int? clipStopAtLastLayers;
  bool? enableHiresFix;
  double? hiresScale;
  String? hiresUpscaler;
  int? hiresSteps;
  String? hiresSamplerName;
  String? hiresScheduler;
  double? hiresDenoisingStrength;
  int? hiresResizeX;
  int? hiresResizeY;

  // Not part of the WebUI payload; used when building a ComfyUI workflow.
  int clipSkip;
  List<LoraSelection> selectedLoras;
  String comfyLoraLoaderType;

  /// img2img source image; null for txt2img.
  Img2ImgSource? source;

  /// img2img only: how much the source image is changed (0 keeps it, 1 replaces it).
  double denoisingStrength;

  /// img2img only: one of [Img2ImgResizeModes].
  String resizeMode;

  bool get isImg2Img => source != null;
  String get webUiPath => isImg2Img ? '/sdapi/v1/img2img' : '/sdapi/v1/txt2img';
  String get agentSchedulerQueuePath =>
      isImg2Img ? '/agent-scheduler/v1/queue/img2img' : '/agent-scheduler/v1/queue/txt2img';

  Map<String, Object?> toJson() {
    final overrides = <String, Object?>{
      'sd_model_checkpoint': ?sdModelCheckpoint,
      'CLIP_stop_at_last_layers': ?clipStopAtLastLayers,
    };

    final source = this.source;
    return {
      if (source != null) 'init_images': [base64.encode(source.bytes)],
      if (source != null) 'resize_mode': Img2ImgResizeModes.webUiIndex(resizeMode),
      'prompt': prompt,
      'negative_prompt': ?negativePrompt,
      'steps': steps,
      'cfg_scale': cfgScale,
      'width': width,
      'height': height,
      'sampler_name': ?samplerName,
      'scheduler': ?scheduler,
      'seed': seed,
      'force_task_id': ?forceTaskId,
      if (overrides.isNotEmpty) 'override_settings': overrides,
      if (overrides.isNotEmpty) 'override_settings_restore_afterwards': true,
      'enable_hr': ?enableHiresFix,
      'hr_scale': ?hiresScale,
      'hr_upscaler': ?hiresUpscaler,
      'hr_second_pass_steps': ?hiresSteps,
      'hr_sampler_name': ?hiresSamplerName,
      'hr_scheduler': ?hiresScheduler,
      'denoising_strength': ?(source != null ? denoisingStrength : hiresDenoisingStrength),
      'hr_resize_x': ?hiresResizeX,
      'hr_resize_y': ?hiresResizeY,
    };
  }
}

class GenerationResponse {
  const GenerationResponse({this.images = const [], this.info});

  final List<String> images;
  final String? info;

  factory GenerationResponse.fromJson(Object? json) {
    final map = JsonRead.map(json) ?? const <String, Object?>{};
    return GenerationResponse(
      images: (JsonRead.list(map['images']) ?? const []).whereType<String>().toList(),
      info: map['info'] is String ? map['info'] as String : null,
    );
  }

  String? get firstImage => images.where((image) => image.trim().isNotEmpty).firstOrNull;
}

/// `GET /sdapi/v1/progress`.
class ProgressResponse {
  const ProgressResponse({
    this.progress = 0,
    this.etaRelative = 0,
    this.jobCount = -1,
    this.jobNo = -1,
    this.job,
    this.currentImage,
  });

  final double progress;
  final double etaRelative;
  final int jobCount;
  final int jobNo;
  final String? job;
  final String? currentImage;

  factory ProgressResponse.fromJson(Object? json) {
    final map = JsonRead.map(json) ?? const <String, Object?>{};
    final state = JsonRead.map(map['state']) ?? const <String, Object?>{};
    return ProgressResponse(
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
      etaRelative: (map['eta_relative'] as num?)?.toDouble() ?? 0,
      jobCount: state['job_count'] is int ? state['job_count'] as int : -1,
      jobNo: state['job_no'] is int ? state['job_no'] as int : -1,
      job: state['job'] is String ? state['job'] as String : null,
      currentImage: map['current_image'] is String ? map['current_image'] as String : null,
    );
  }
}

/// Body of `POST /internal/progress`.
class InternalProgressRequest {
  const InternalProgressRequest({this.taskId, this.livePreviewId = -1, this.livePreview = true});

  final String? taskId;
  final int livePreviewId;
  final bool livePreview;

  Map<String, Object?> toJson() => {'id_task': ?taskId, 'id_live_preview': livePreviewId, 'live_preview': livePreview};
}

class InternalProgressResponse {
  const InternalProgressResponse({
    this.active = false,
    this.queued = false,
    this.completed = false,
    this.progress = 0,
    this.eta = 0,
    this.livePreview,
    this.livePreviewId = -1,
    this.textInfo,
  });

  final bool active;
  final bool queued;
  final bool completed;
  final double progress;
  final double eta;
  final String? livePreview;
  final int livePreviewId;
  final String? textInfo;

  factory InternalProgressResponse.fromJson(Object? json) {
    final map = JsonRead.map(json) ?? const <String, Object?>{};
    return InternalProgressResponse(
      active: map['active'] == true,
      queued: map['queued'] == true,
      completed: map['completed'] == true,
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
      eta: (map['eta'] as num?)?.toDouble() ?? 0,
      livePreview: map['live_preview'] is String ? map['live_preview'] as String : null,
      livePreviewId: map['id_live_preview'] is int ? map['id_live_preview'] as int : -1,
      textInfo: map['textinfo'] is String ? map['textinfo'] as String : null,
    );
  }

  bool get isMeaningful =>
      active ||
      queued ||
      completed ||
      progress > 0.001 ||
      livePreviewId >= 0 ||
      (livePreview?.trim().isNotEmpty ?? false) ||
      (textInfo?.trim().isNotEmpty ?? false);
}

/// Lists discovered from ComfyUI `/object_info`.
class ComfyObjectInfoMetadata {
  const ComfyObjectInfoMetadata({
    this.checkpointNames = const [],
    this.samplerNames = const [],
    this.schedulerNames = const [],
    this.latentUpscaleMethods = const [],
    this.loraNames = const [],
    this.availableLoraLoaderTypes = const [ComfyLoraLoaderTypes.loraLoader],
    this.supportsClipSetLastLayer = false,
    this.imageScaleMethods = const [],
  });

  final List<String> checkpointNames;
  final List<String> samplerNames;
  final List<String> schedulerNames;
  final List<String> latentUpscaleMethods;
  final List<String> loraNames;
  final List<String> availableLoraLoaderTypes;
  final bool supportsClipSetLastLayer;

  /// `upscale_method` options of the `ImageScale` node (used to fit img2img source images).
  final List<String> imageScaleMethods;

  Map<String, Object?> toJson() => {
    'checkpointNames': checkpointNames,
    'samplerNames': samplerNames,
    'schedulerNames': schedulerNames,
    'latentUpscaleMethods': latentUpscaleMethods,
    'loraNames': loraNames,
    'availableLoraLoaderTypes': availableLoraLoaderTypes,
    'supportsClipSetLastLayer': supportsClipSetLastLayer,
    'imageScaleMethods': imageScaleMethods,
  };

  static ComfyObjectInfoMetadata? fromJson(Object? json) {
    final map = JsonRead.map(json);
    if (map == null) {
      return null;
    }

    List<String> strings(String key) =>
        (JsonRead.list(JsonRead.value(map, key)) ?? const []).whereType<String>().toList();

    final loaderTypes = strings('availableLoraLoaderTypes');
    return ComfyObjectInfoMetadata(
      checkpointNames: strings('checkpointNames'),
      samplerNames: strings('samplerNames'),
      schedulerNames: strings('schedulerNames'),
      latentUpscaleMethods: strings('latentUpscaleMethods'),
      loraNames: strings('loraNames'),
      availableLoraLoaderTypes: loaderTypes.isEmpty ? const [ComfyLoraLoaderTypes.loraLoader] : loaderTypes,
      supportsClipSetLastLayer: JsonRead.boolean(map, 'supportsClipSetLastLayer') ?? false,
      imageScaleMethods: strings('imageScaleMethods'),
    );
  }
}

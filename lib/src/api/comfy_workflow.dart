import '../core/ids.dart';
import '../models/api_platform.dart';
import '../models/lora_selection.dart';
import 'sd_models.dart';

/// Builds the txt2img prompt graph that is queued through ComfyUI `/prompt`, so no separate
/// workflow file is needed.
abstract final class ComfyWorkflow {
  static const filenamePrefix = 'Multiplex';

  static Map<String, Object?> buildTxt2ImgPrompt(
    Txt2ImgRequest request, {
    required String checkpoint,
    required String latentUpscaleMethod,
    required String loraLoaderType,
    required bool supportsClipSetLastLayer,
    int Function() seedGenerator = randomSeed,
  }) {
    final seed = request.seed < 0 ? seedGenerator() : request.seed;
    final steps = request.steps < 1 ? 1 : request.steps;
    final cfg = request.cfgScale < 1 ? 1.0 : request.cfgScale;
    final width = request.width < 64 ? 64 : request.width;
    final height = request.height < 64 ? 64 : request.height;
    final sampler = normalizeSamplerName(request.samplerName);
    final scheduler = normalizeSchedulerName(request.scheduler);
    final loras = LoraSelection.normalize(request.selectedLoras);
    final loaderType = ComfyLoraLoaderTypes.normalize(loraLoaderType);

    final prompt = <String, Object?>{};
    var nextNodeId = 3;
    String nextId() => (nextNodeId++).toString();

    final samplerId = nextId();
    final checkpointId = nextId();
    final latentId = nextId();

    List<Object> modelLink = _link(checkpointId, 0);
    List<Object> clipLink = _link(checkpointId, 1);

    prompt[checkpointId] = _node('CheckpointLoaderSimple', {'ckpt_name': checkpoint});

    for (final lora in loras) {
      final loraNodeId = nextId();
      if (loaderType == ComfyLoraLoaderTypes.loraLoaderModelOnly) {
        prompt[loraNodeId] = _node(ComfyLoraLoaderTypes.loraLoaderModelOnly, {
          'model': modelLink,
          'lora_name': lora.name,
          'strength_model': lora.weight,
        });
        modelLink = _link(loraNodeId, 0);
      } else {
        prompt[loraNodeId] = _node(ComfyLoraLoaderTypes.loraLoader, {
          'model': modelLink,
          'clip': clipLink,
          'lora_name': lora.name,
          'strength_model': lora.weight,
          'strength_clip': lora.weight,
        });
        modelLink = _link(loraNodeId, 0);
        clipLink = _link(loraNodeId, 1);
      }
    }

    if (supportsClipSetLastLayer && request.clipSkip > 1) {
      final clipSkipId = nextId();
      prompt[clipSkipId] = _node('CLIPSetLastLayer', {'clip': clipLink, 'stop_at_clip_layer': -request.clipSkip.abs()});
      clipLink = _link(clipSkipId, 0);
    }

    final positiveId = nextId();
    final negativeId = nextId();

    prompt[latentId] = _node('EmptyLatentImage', {'width': width, 'height': height, 'batch_size': 1});
    prompt[positiveId] = _node('CLIPTextEncode', {'clip': clipLink, 'text': request.prompt});
    prompt[negativeId] = _node('CLIPTextEncode', {'clip': clipLink, 'text': request.negativePrompt ?? ''});
    prompt[samplerId] = _node('KSampler', {
      'seed': seed,
      'steps': steps,
      'cfg': cfg,
      'sampler_name': sampler,
      'scheduler': scheduler,
      'denoise': 1.0,
      'model': modelLink,
      'positive': _link(positiveId, 0),
      'negative': _link(negativeId, 0),
      'latent_image': _link(latentId, 0),
    });

    var finalSamplerId = samplerId;
    if (request.enableHiresFix == true) {
      final upscaleId = nextId();
      final hiresSamplerId = nextId();
      final hiresSteps = request.hiresSteps ?? 0;
      prompt[upscaleId] = _node('LatentUpscaleBy', {
        'samples': _link(samplerId, 0),
        'upscale_method': latentUpscaleMethod,
        'scale_by': resolveHiresScale(request),
      });
      prompt[hiresSamplerId] = _node('KSampler', {
        'seed': seed,
        'steps': hiresSteps > 0 ? hiresSteps : steps,
        'cfg': cfg,
        'sampler_name': sampler,
        'scheduler': scheduler,
        'denoise': (request.hiresDenoisingStrength ?? 0.7).clamp(0.0, 1.0).toDouble(),
        'model': modelLink,
        'positive': _link(positiveId, 0),
        'negative': _link(negativeId, 0),
        'latent_image': _link(upscaleId, 0),
      });
      finalSamplerId = hiresSamplerId;
    }

    final decodeId = nextId();
    final saveId = nextId();
    prompt[decodeId] = _node('VAEDecode', {'samples': _link(finalSamplerId, 0), 'vae': _link(checkpointId, 2)});
    prompt[saveId] = _node('SaveImage', {'filename_prefix': filenamePrefix, 'images': _link(decodeId, 0)});

    return prompt;
  }

  static double resolveHiresScale(Txt2ImgRequest request) {
    var scale = request.hiresScale != null && request.hiresScale! > 1 ? request.hiresScale! : 2.0;
    if (request.width > 0 && request.height > 0) {
      final resizeX = request.hiresResizeX != null && request.hiresResizeX! > 0
          ? request.hiresResizeX! / request.width
          : 0.0;
      final resizeY = request.hiresResizeY != null && request.hiresResizeY! > 0
          ? request.hiresResizeY! / request.height
          : 0.0;
      final resizeScale = resizeX > resizeY ? resizeX : resizeY;
      if (resizeScale > 1) {
        scale = resizeScale;
      }
    }

    return scale < 1 ? 1.0 : scale;
  }

  static String normalizeSamplerName(String? samplerName) {
    return switch (samplerName?.trim()) {
      null || '' => 'euler',
      'Euler a' => 'euler_ancestral',
      'Euler' => 'euler',
      'Heun' => 'heun',
      'LMS' => 'lms',
      'DPM2' => 'dpm_2',
      'DPM2 a' => 'dpm_2_ancestral',
      'DDIM' => 'ddim',
      'UniPC' => 'uni_pc',
      _ => samplerName!,
    };
  }

  static String normalizeSchedulerName(String? schedulerName) {
    return switch (schedulerName?.trim()) {
      null || '' => 'normal',
      'Automatic' => 'normal',
      'Normal' => 'normal',
      'Karras' => 'karras',
      'Exponential' => 'exponential',
      'SGM Uniform' => 'sgm_uniform',
      'Simple' => 'simple',
      'DDIM' => 'ddim_uniform',
      'Beta' => 'beta',
      'KL Optimal' => 'kl_optimal',
      _ => schedulerName!,
    };
  }

  static String resolveLoraLoaderType(String? preferred, List<String> available) {
    final normalizedPreferred = ComfyLoraLoaderTypes.normalize(preferred);
    final normalizedAvailable = <String>[];
    for (final type in available) {
      if (type.trim().isEmpty) {
        continue;
      }

      final normalized = ComfyLoraLoaderTypes.normalize(type);
      if (!normalizedAvailable.contains(normalized)) {
        normalizedAvailable.add(normalized);
      }
    }

    if (normalizedAvailable.isEmpty) {
      return normalizedPreferred;
    }

    return normalizedAvailable.contains(normalizedPreferred) ? normalizedPreferred : normalizedAvailable.first;
  }

  /// Maps a WebUI hires upscaler label (or a ComfyUI method) to an available `LatentUpscaleBy` method.
  static String resolveLatentUpscaleMethod(String? hiresUpscaler, List<String> availableMethods) {
    final preferred = _mapLatentUpscaleMethod(hiresUpscaler);
    if (availableMethods.isEmpty) {
      return preferred;
    }

    for (final candidate in [preferred, 'bislerp', 'bicubic', 'nearest-exact', 'bilinear', 'area']) {
      for (final method in availableMethods) {
        if (method.toLowerCase() == candidate.toLowerCase()) {
          return method;
        }
      }
    }

    return availableMethods.firstWhere((method) => method.trim().isNotEmpty, orElse: () => preferred);
  }

  static String _mapLatentUpscaleMethod(String? hiresUpscaler) {
    final value = hiresUpscaler?.toLowerCase() ?? '';
    if (value.trim().isEmpty) {
      return 'bislerp';
    }

    if (value.contains('nearest')) {
      return 'nearest-exact';
    }

    if (value.contains('bicubic')) {
      return 'bicubic';
    }

    if (value.contains('bilinear') || value.contains('antialiased')) {
      return 'bilinear';
    }

    if (value.contains('area')) {
      return 'area';
    }

    return 'bislerp';
  }

  static Map<String, Object?> _node(String classType, Map<String, Object?> inputs) => {
    'class_type': classType,
    'inputs': inputs,
  };

  static List<Object> _link(String nodeId, int outputIndex) => [nodeId, outputIndex];
}

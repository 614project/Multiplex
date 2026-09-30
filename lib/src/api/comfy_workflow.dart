import '../core/ids.dart';
import '../models/api_platform.dart';
import '../models/img2img.dart';
import '../models/lora_selection.dart';
import 'sd_models.dart';

/// Builds the txt2img or img2img prompt graph that is queued through ComfyUI `/prompt`, so no
/// separate workflow file is needed.
abstract final class ComfyWorkflow {
  static const filenamePrefix = 'Multiplex';

  /// img2img requests need [sourceImageName], the name the uploaded source image has in ComfyUI's
  /// input folder. [imageScaleMethod] fits the source image to the requested size.
  static Map<String, Object?> buildPrompt(
    GenerationRequest request, {
    required String checkpoint,
    required String latentUpscaleMethod,
    required String loraLoaderType,
    required bool supportsClipSetLastLayer,
    String? sourceImageName,
    String imageScaleMethod = 'bicubic',
    int Function() seedGenerator = randomSeed,
  }) {
    final source = request.source;
    if (source != null && (sourceImageName == null || sourceImageName.trim().isEmpty)) {
      throw ArgumentError.value(sourceImageName, 'sourceImageName', 'img2img workflows need the uploaded image name');
    }

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

    if (source == null) {
      prompt[latentId] = _node('EmptyLatentImage', {'width': width, 'height': height, 'batch_size': 1});
    } else {
      _addSourceLatent(
        prompt,
        nextId,
        latentId: latentId,
        vae: _link(checkpointId, 2),
        source: source,
        sourceImageName: sourceImageName!,
        resizeMode: Img2ImgResizeModes.normalize(request.resizeMode),
        width: width,
        height: height,
        imageScaleMethod: imageScaleMethod,
        latentUpscaleMethod: latentUpscaleMethod,
      );
    }

    prompt[positiveId] = _node('CLIPTextEncode', {'clip': clipLink, 'text': request.prompt});
    prompt[negativeId] = _node('CLIPTextEncode', {'clip': clipLink, 'text': request.negativePrompt ?? ''});
    prompt[samplerId] = _node('KSampler', {
      'seed': seed,
      'steps': steps,
      'cfg': cfg,
      'sampler_name': sampler,
      'scheduler': scheduler,
      'denoise': source == null ? 1.0 : request.denoisingStrength.clamp(0.0, 1.0).toDouble(),
      'model': modelLink,
      'positive': _link(positiveId, 0),
      'negative': _link(negativeId, 0),
      'latent_image': _link(latentId, 0),
    });

    var finalSamplerId = samplerId;
    if (source == null && request.enableHiresFix == true) {
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

  /// Loads the uploaded source image, fits it to [width] × [height] as [resizeMode] describes and
  /// encodes it into the latent the sampler starts from (stored at [latentId]).
  static void _addSourceLatent(
    Map<String, Object?> prompt,
    String Function() nextId, {
    required String latentId,
    required List<Object> vae,
    required Img2ImgSource source,
    required String sourceImageName,
    required String resizeMode,
    required int width,
    required int height,
    required String imageScaleMethod,
    required String latentUpscaleMethod,
  }) {
    final loadId = nextId();
    prompt[loadId] = _node('LoadImage', {'image': sourceImageName});
    var pixels = _link(loadId, 0);

    if (resizeMode == Img2ImgResizeModes.latentUpscale) {
      final encodeId = nextId();
      prompt[encodeId] = _node('VAEEncode', {'pixels': pixels, 'vae': vae});
      prompt[latentId] = _node('LatentUpscale', {
        'samples': _link(encodeId, 0),
        'upscale_method': latentUpscaleMethod,
        'width': width,
        'height': height,
        'crop': 'disabled',
      });
      return;
    }

    if (resizeMode == Img2ImgResizeModes.resizeAndFill) {
      final fit = fitInside(source.width, source.height, width, height);
      final scaleId = nextId();
      prompt[scaleId] = _node('ImageScale', {
        'image': pixels,
        'upscale_method': imageScaleMethod,
        'width': fit.width,
        'height': fit.height,
        'crop': 'disabled',
      });
      pixels = _link(scaleId, 0);
      if (fit.width < width || fit.height < height) {
        final left = (width - fit.width) ~/ 2;
        final top = (height - fit.height) ~/ 2;
        final padId = nextId();
        prompt[padId] = _node('ImagePadForOutpaint', {
          'image': pixels,
          'left': left,
          'top': top,
          'right': width - fit.width - left,
          'bottom': height - fit.height - top,
          'feathering': 0,
        });
        pixels = _link(padId, 0);
      }
    } else {
      final scaleId = nextId();
      prompt[scaleId] = _node('ImageScale', {
        'image': pixels,
        'upscale_method': imageScaleMethod,
        'width': width,
        'height': height,
        'crop': resizeMode == Img2ImgResizeModes.cropAndResize ? 'center' : 'disabled',
      });
      pixels = _link(scaleId, 0);
    }

    prompt[latentId] = _node('VAEEncode', {'pixels': pixels, 'vae': vae});
  }

  /// The largest size with the aspect ratio of [sourceWidth] × [sourceHeight] that fits inside
  /// [width] × [height].
  static ({int width, int height}) fitInside(int sourceWidth, int sourceHeight, int width, int height) {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return (width: width, height: height);
    }

    final scale = width / sourceWidth < height / sourceHeight ? width / sourceWidth : height / sourceHeight;
    return (
      width: (sourceWidth * scale).round().clamp(1, width),
      height: (sourceHeight * scale).round().clamp(1, height),
    );
  }

  /// Picks the `ImageScale` method used to fit source images, preferring the sharpest one available.
  static String resolveImageScaleMethod(List<String> availableMethods) {
    for (final candidate in ['lanczos', 'bicubic', 'bilinear', 'area', 'nearest-exact']) {
      for (final method in availableMethods) {
        if (method.toLowerCase() == candidate) {
          return method;
        }
      }
    }

    return availableMethods.firstWhere((method) => method.trim().isNotEmpty, orElse: () => 'bicubic');
  }

  static double resolveHiresScale(GenerationRequest request) {
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

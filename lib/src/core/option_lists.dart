import '../models/api_platform.dart';

/// Fallback option lists used until the server reports its own, plus the matching helpers that
/// WebuiMultiflex used to keep saved values valid when the list changes.
abstract final class OptionLists {
  static const webUiSamplers = <String>[
    'DPM++ 2M',
    'DPM++ SDE',
    'DPM++ 2M SDE',
    'DPM++ 2M SDE Heun',
    'DPM++ 2S a',
    'DPM++ 3M SDE',
    'Euler a',
    'Euler',
    'LMS',
    'Heun',
    'DPM2',
    'DPM2 a',
    'DPM fast',
    'DPM adaptive',
    'Restart',
    'DDIM',
    'DDIM CFG++',
    'PLMS',
    'UniPC',
  ];

  static const webUiSchedulers = <String>[
    'Automatic',
    'Uniform',
    'Karras',
    'Exponential',
    'Polyexponential',
    'SGM Uniform',
    'KL Optimal',
    'Align Your Steps',
    'Simple',
    'Normal',
    'DDIM',
    'Beta',
  ];

  static const comfySamplers = <String>[
    'euler',
    'euler_cfg_pp',
    'euler_ancestral',
    'euler_ancestral_cfg_pp',
    'heun',
    'heunpp2',
    'dpm_2',
    'dpm_2_ancestral',
    'lms',
    'dpm_fast',
    'dpm_adaptive',
    'dpmpp_2s_ancestral',
    'dpmpp_sde',
    'dpmpp_sde_gpu',
    'dpmpp_2m',
    'dpmpp_2m_sde',
    'dpmpp_2m_sde_gpu',
    'dpmpp_3m_sde',
    'dpmpp_3m_sde_gpu',
    'ddpm',
    'ddim',
    'lcm',
    'ipndm',
    'ipndm_v',
    'deis',
    'res_multistep',
    'res_multistep_cfg_pp',
    'res_multistep_ancestral',
    'res_multistep_ancestral_cfg_pp',
    'gradient_estimation',
    'er_sde',
    'uni_pc',
    'uni_pc_bh2',
  ];

  static const comfySchedulers = <String>[
    'normal',
    'karras',
    'exponential',
    'sgm_uniform',
    'simple',
    'ddim_uniform',
    'beta',
    'linear_quadratic',
    'kl_optimal',
  ];

  static const webUiHiresUpscalers = <String>[
    'Latent',
    'Latent (antialiased)',
    'Latent (bicubic)',
    'Latent (bicubic antialiased)',
    'Latent (nearest)',
    'Latent (nearest-exact)',
    'R-ESRGAN 4x+',
    'R-ESRGAN 4x+ Anime6B',
    '4x-UltraSharp',
    'ESRGAN_4x',
    'SwinIR_4x',
    '8x_NMKD-Superscale_150000_G',
    '4x-AnimeSharp',
    'ScuNET GAN',
    'ScuNET PSNR',
    'None',
  ];

  static const comfyHiresUpscalers = <String>['bislerp', 'bicubic', 'nearest-exact', 'bilinear', 'area'];

  static List<String> samplerDefaults(ApiPlatform platform) => platform.isComfyUi ? comfySamplers : webUiSamplers;

  static List<String> schedulerDefaults(ApiPlatform platform) => platform.isComfyUi ? comfySchedulers : webUiSchedulers;

  static List<String> hiresUpscalerDefaults(ApiPlatform platform) =>
      platform.isComfyUi ? comfyHiresUpscalers : webUiHiresUpscalers;

  static String defaultSampler(ApiPlatform platform) => platform.isComfyUi ? 'euler' : 'Euler a';

  static String defaultScheduler(ApiPlatform platform) => platform.isComfyUi ? 'normal' : 'Automatic';

  static String defaultHiresUpscaler(ApiPlatform platform) => platform.isComfyUi ? 'bislerp' : 'Latent';

  /// Builds a de-duplicated option list that always contains [fallback] and the current value,
  /// so a saved choice never silently disappears from a dropdown.
  static List<String> createOptionList(List<String> options, String? currentValue, String fallback) {
    final list = <String>[];
    final seen = <String>{};
    for (final option in options.isEmpty ? [fallback] : options) {
      if (option.trim().isEmpty || !seen.add(option.toLowerCase())) {
        continue;
      }

      list.add(option);
    }

    if (!seen.contains(fallback.toLowerCase())) {
      list.insert(0, fallback);
      seen.add(fallback.toLowerCase());
    }

    var effectiveCurrent = currentValue;
    final normalizedCurrent = normalizeKnownWebUiSchedulerLabel(currentValue);
    if (normalizedCurrent != null &&
        normalizedCurrent.trim().isNotEmpty &&
        seen.contains(normalizedCurrent.toLowerCase())) {
      effectiveCurrent = normalizedCurrent;
    }

    if (effectiveCurrent != null &&
        effectiveCurrent.trim().isNotEmpty &&
        !seen.contains(effectiveCurrent.toLowerCase())) {
      list.insert(0, effectiveCurrent);
    }

    return list;
  }

  /// Returns the option that matches [value] (case-insensitively, also trying the WebUI label of a
  /// ComfyUI scheduler id), or [fallback].
  static String resolveOption(String? value, List<String> options, String fallback) {
    final candidates = <String>[
      if (value != null && value.trim().isNotEmpty) value,
      if (normalizeKnownWebUiSchedulerLabel(value) case final normalized?
          when normalized.trim().isNotEmpty && normalized != value)
        normalized,
    ];

    for (final candidate in candidates) {
      for (final option in options) {
        if (option.toLowerCase() == candidate.toLowerCase()) {
          return option;
        }
      }
    }

    return fallback;
  }

  static String normalizeSchedulerForRequest(ApiPlatform platform, String scheduler) {
    if (!platform.isWebUi) {
      return scheduler;
    }

    final normalized = normalizeKnownWebUiSchedulerLabel(scheduler);
    return normalized == null || normalized.trim().isEmpty ? scheduler : normalized;
  }

  static String? normalizeKnownWebUiSchedulerLabel(String? value) {
    if (value == null || value.trim().isEmpty) {
      return value;
    }

    return switch (value.trim().toLowerCase()) {
      'automatic' => 'Automatic',
      'uniform' => 'Uniform',
      'karras' => 'Karras',
      'exponential' => 'Exponential',
      'polyexponential' => 'Polyexponential',
      'sgm_uniform' => 'SGM Uniform',
      'kl_optimal' => 'KL Optimal',
      'align_your_steps' => 'Align Your Steps',
      'simple' => 'Simple',
      'normal' => 'Normal',
      'ddim_uniform' => 'DDIM',
      _ => value,
    };
  }
}

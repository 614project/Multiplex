/// Whether a project generates images from text alone or transforms source images.
enum GenerationType {
  txt2img('txt2img', 'Text to image'),
  img2img('img2img', 'Image to image');

  const GenerationType(this.id, this.label);

  /// Name used in project files and exports.
  final String id;
  final String label;

  bool get isImg2Img => this == GenerationType.img2img;

  static GenerationType parse(String? value) =>
      value != null && value.trim().toLowerCase() == img2img.id ? img2img : txt2img;
}

/// How a source image is fitted to the requested size. The order matches WebUI's `resize_mode`.
abstract final class Img2ImgResizeModes {
  static const justResize = 'Just resize';
  static const cropAndResize = 'Crop and resize';
  static const resizeAndFill = 'Resize and fill';
  static const latentUpscale = 'Just resize (latent upscale)';

  static const all = <String>[justResize, cropAndResize, resizeAndFill, latentUpscale];

  static String normalize(String? value) {
    final wanted = value?.trim().toLowerCase();
    return all.firstWhere((mode) => mode.toLowerCase() == wanted, orElse: () => justResize);
  }

  /// WebUI `resize_mode` value.
  static int webUiIndex(String mode) => all.indexOf(normalize(mode));

  static String describe(String mode) => switch (normalize(mode)) {
    cropAndResize => 'Fills the target size and crops what sticks out, keeping the aspect ratio.',
    resizeAndFill => 'Fits the whole image inside the target size and fills the empty borders.',
    latentUpscale => 'Stretches the image in latent space instead of pixel space.',
    _ => 'Stretches the image to the target size.',
  };
}

abstract final class Img2ImgDefaults {
  static const denoisingStrength = 0.75;

  /// Folder inside a project that holds its source images.
  static const sourceFolderName = 'sources';
}

/// Rounds a source image dimension to a size the generators accept: a multiple of 8, at least 64.
int roundGenerationDimension(int value) {
  final rounded = (value / 8).round() * 8;
  return rounded < 64 ? 64 : rounded;
}

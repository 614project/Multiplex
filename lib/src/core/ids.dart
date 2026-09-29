import 'dart:math';

final Random _random = Random.secure();

/// Returns a random 128-bit identifier as 32 lowercase hex characters (the same shape as a
/// .NET `Guid.ToString("N")`, which WebuiMultiflex used for project and cell folders).
String newId() {
  final buffer = StringBuffer();
  for (var index = 0; index < 16; index++) {
    var value = _random.nextInt(256);
    if (index == 6) {
      value = (value & 0x0f) | 0x40;
    } else if (index == 8) {
      value = (value & 0x3f) | 0x80;
    }

    buffer.write(value.toRadixString(16).padLeft(2, '0'));
  }

  return buffer.toString();
}

/// Random positive 63-bit integer, used for ComfyUI seeds when the project seed is -1.
int randomSeed() {
  final high = _random.nextInt(1 << 31);
  final low = _random.nextInt(1 << 32);
  final value = (high << 32) | low;
  return value == 0 ? 1 : value;
}

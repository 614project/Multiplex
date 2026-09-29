import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core/image_timestamps.dart';
import '../core/json_read.dart';
import '../models/image_metadata.dart';

/// Reads generation details from PNG text chunks: the WebUI `parameters` infotext or the ComfyUI
/// `prompt` graph written by this app's txt2img workflow. Basic size information is always filled.
abstract final class PngMetadataReader {
  static const _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
  static final RegExp _webUiParameter = RegExp(
    r'(?:^|, )(?<key>[^:]+): (?<value>.*?)(?=(?:, [A-Za-z][A-Za-z0-9 ._+\-/]*: )|$)',
    dotAll: true,
  );

  static Future<GeneratedImageMetadata> readFile(String filePath) async {
    final metadata = GeneratedImageMetadata(filePath: filePath, generatedAt: ImageTimestamps.resolve(filePath));

    final file = File(filePath);
    if (!await file.exists()) {
      metadata.parseStatusMessage = 'Image file could not be found.';
      return metadata;
    }

    final bytes = await file.readAsBytes();
    if (p.extension(filePath).toLowerCase() != '.png') {
      metadata.parseStatusMessage =
          'Only PNG metadata parsing is currently supported. Basic file information is still shown.';
      return metadata;
    }

    return readBytes(bytes, metadata);
  }

  static GeneratedImageMetadata readBytes(Uint8List bytes, GeneratedImageMetadata metadata) {
    try {
      final textChunks = readTextChunks(bytes, metadata);
      final parameters = _lookup(textChunks, 'parameters');
      if (parameters != null && _tryParseWebUi(parameters, metadata)) {
        return metadata;
      }

      final prompt = _lookup(textChunks, 'prompt');
      if (prompt != null && _tryParseComfy(prompt, metadata)) {
        return metadata;
      }

      if (_lookup(textChunks, 'workflow') != null) {
        metadata.parseStatusMessage = 'ComfyUI workflow metadata exists, but the prompt graph chunk could not be read.';
        return metadata;
      }

      if (metadata.parseStatusMessage.isEmpty) {
        metadata.parseStatusMessage = textChunks.isEmpty
            ? 'No PNG text metadata was found in this image.'
            : 'Supported generation metadata keys were not found. Available PNG text keys: '
                  '${textChunks.keys.take(6).join(', ')}';
      }

      return metadata;
    } catch (error) {
      metadata.parseStatusMessage = 'Metadata could not be parsed: $error';
      return metadata;
    }
  }

  /// Returns the text chunks (tEXt, zTXt, iTXt) and fills width/height from IHDR.
  static Map<String, String> readTextChunks(Uint8List bytes, GeneratedImageMetadata metadata) {
    if (bytes.length < 8) {
      throw const FormatException('The file is not a valid PNG image.');
    }

    for (var index = 0; index < _pngSignature.length; index++) {
      if (bytes[index] != _pngSignature[index]) {
        throw const FormatException('The file is not a valid PNG image.');
      }
    }

    final data = ByteData.sublistView(bytes);
    final chunks = <String, String>{};
    var position = 8;
    while (position + 12 <= bytes.length) {
      final length = data.getUint32(position);
      final type = ascii.decode(bytes.sublist(position + 4, position + 8), allowInvalid: true);
      final start = position + 8;
      if (length > 0x7fffffff || start + length + 4 > bytes.length) {
        break;
      }

      final chunk = Uint8List.sublistView(bytes, start, start + length);
      position = start + length + 4;

      switch (type) {
        case 'IHDR':
          if (chunk.length >= 8) {
            final header = ByteData.sublistView(chunk);
            metadata.width = header.getUint32(0);
            metadata.height = header.getUint32(4);
          }
        case 'tEXt':
          _addIfPresent(chunks, _parseText(chunk));
        case 'zTXt':
          _addIfPresent(chunks, _parseCompressedText(chunk));
        case 'iTXt':
          _addIfPresent(chunks, _parseInternationalText(chunk));
        case 'IEND':
          return chunks;
      }
    }

    return chunks;
  }

  static String? _lookup(Map<String, String> chunks, String key) {
    for (final entry in chunks.entries) {
      if (entry.key.toLowerCase() == key) {
        return entry.value;
      }
    }

    return null;
  }

  static void _addIfPresent(Map<String, String> chunks, MapEntry<String, String>? entry) {
    if (entry != null && entry.key.isNotEmpty) {
      chunks[entry.key] = entry.value;
    }
  }

  static MapEntry<String, String>? _parseText(Uint8List chunk) {
    final separator = chunk.indexOf(0);
    if (separator <= 0 || separator >= chunk.length - 1) {
      return null;
    }

    return MapEntry(latin1.decode(chunk.sublist(0, separator)), _decodeText(chunk.sublist(separator + 1)));
  }

  static MapEntry<String, String>? _parseCompressedText(Uint8List chunk) {
    final separator = chunk.indexOf(0);
    if (separator <= 0 || separator + 2 > chunk.length) {
      return null;
    }

    final key = latin1.decode(chunk.sublist(0, separator));
    return MapEntry(key, _decodeText(const ZLibDecoder().decodeBytes(chunk.sublist(separator + 2))));
  }

  static MapEntry<String, String>? _parseInternationalText(Uint8List chunk) {
    final keywordEnd = chunk.indexOf(0);
    if (keywordEnd <= 0 || keywordEnd + 5 > chunk.length) {
      return null;
    }

    final key = latin1.decode(chunk.sublist(0, keywordEnd));
    final compressed = chunk[keywordEnd + 1] == 1;
    final languageEnd = chunk.indexOf(0, keywordEnd + 3);
    if (languageEnd < 0) {
      return null;
    }

    final translatedEnd = chunk.indexOf(0, languageEnd + 1);
    if (translatedEnd < 0) {
      return null;
    }

    final textBytes = chunk.sublist(translatedEnd + 1);
    final text = compressed ? _decodeText(const ZLibDecoder().decodeBytes(textBytes)) : _decodeText(textBytes);
    return MapEntry(key, text);
  }

  static String _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  static bool _tryParseWebUi(String infotext, GeneratedImageMetadata metadata) {
    if (infotext.trim().isEmpty) {
      metadata.parseStatusMessage = 'The WebUI parameters chunk was empty.';
      return false;
    }

    final lines = infotext.replaceAll('\r\n', '\n').split('\n');
    var stepsLine = -1;
    for (var index = lines.length - 1; index >= 0; index--) {
      if (lines[index].toLowerCase().startsWith('steps:')) {
        stepsLine = index;
        break;
      }
    }

    if (stepsLine < 0) {
      metadata.parseStatusMessage =
          'A WebUI parameters chunk was found, but the parameter line could not be identified.';
      return false;
    }

    final promptSection = lines.take(stepsLine).join('\n').trim();
    final parameterSection = lines.skip(stepsLine).map((line) => line.trim()).join(' ').trim();
    _splitWebUiPromptSection(promptSection, metadata);

    final parameters = <String, String>{};
    for (final match in _webUiParameter.allMatches(parameterSection)) {
      final key = match.namedGroup('key')!.trim();
      final value = match.namedGroup('value')!.trim();
      if (key.isNotEmpty) {
        parameters[key.toLowerCase()] = value;
      }
    }

    String? parameter(String key) => parameters[key.toLowerCase()];

    metadata.steps = int.tryParse(parameter('Steps') ?? '');
    metadata.cfgScale = double.tryParse(parameter('CFG scale') ?? '');
    metadata.sampler = parameter('Sampler') ?? '';
    metadata.scheduler = parameter('Schedule type') ?? parameter('Scheduler') ?? '';

    final hiresSampler = parameter('Hires sampler');
    if (hiresSampler != null && hiresSampler.isNotEmpty && !hiresSampler.toLowerCase().startsWith('use same')) {
      metadata.enableHiresFix = true;
      metadata.sampler = hiresSampler;
    }

    final hiresScheduler = parameter('Hires schedule type');
    if (hiresScheduler != null && hiresScheduler.isNotEmpty && !hiresScheduler.toLowerCase().startsWith('use same')) {
      metadata.enableHiresFix = true;
      metadata.scheduler = hiresScheduler;
    }

    metadata.seed = int.tryParse(parameter('Seed') ?? '');
    final size = parameter('Size');
    if (size != null) {
      final parts = size.split('x').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
      if (parts.length == 2) {
        metadata.baseWidth = int.tryParse(parts[0]) ?? metadata.baseWidth;
        metadata.baseHeight = int.tryParse(parts[1]) ?? metadata.baseHeight;
      }
    }

    metadata.checkpoint = parameter('Model') ?? '';
    metadata.clipSkip = int.tryParse(parameter('Clip skip') ?? '');

    final hiresSteps = int.tryParse(parameter('Hires steps') ?? '');
    if (hiresSteps != null) {
      metadata.enableHiresFix = true;
      metadata.hiresSteps = hiresSteps;
    }

    final denoise = double.tryParse(parameter('Denoising strength') ?? '');
    if (denoise != null) {
      metadata.enableHiresFix = true;
      metadata.hiresDenoisingStrength = denoise;
    }

    final loraNames = <String>{};
    for (final match in RegExp(
      r'<lora:([^:>]+)(?::[^>]*)?>',
      caseSensitive: false,
    ).allMatches(metadata.positivePrompt)) {
      loraNames.add(match.group(1)!.trim());
    }

    final loraHashes = parameter('Lora hashes');
    if (loraHashes != null) {
      for (final entry in loraHashes.replaceAll('"', '').split(',')) {
        final name = entry.split(':').first.trim();
        if (name.isNotEmpty) {
          loraNames.add(name);
        }
      }
    }

    metadata.loras = loraNames.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    metadata.metadataParsed =
        metadata.positivePrompt.isNotEmpty || metadata.negativePrompt.isNotEmpty || parameters.isNotEmpty;
    metadata.metadataSource = 'WebUI PNG parameters';
    metadata.parseStatusMessage = metadata.metadataParsed ? '' : 'The WebUI parameters chunk could not be parsed.';
    return metadata.metadataParsed;
  }

  static void _splitWebUiPromptSection(String promptSection, GeneratedImageMetadata metadata) {
    if (promptSection.trim().isEmpty) {
      return;
    }

    const marker = '\nnegative prompt:';
    final negativeIndex = promptSection.toLowerCase().indexOf(marker);
    if (negativeIndex >= 0) {
      metadata.positivePrompt = promptSection.substring(0, negativeIndex).trim();
      metadata.negativePrompt = promptSection.substring(negativeIndex + marker.length).trim();
      return;
    }

    if (promptSection.toLowerCase().startsWith('negative prompt:')) {
      metadata.negativePrompt = promptSection.substring('negative prompt:'.length).trim();
      return;
    }

    metadata.positivePrompt = promptSection.trim();
  }

  static bool _tryParseComfy(String promptJson, GeneratedImageMetadata metadata) {
    if (promptJson.trim().isEmpty) {
      metadata.parseStatusMessage = 'The ComfyUI prompt graph chunk was empty.';
      return false;
    }

    final root = JsonRead.map(jsonDecode(promptJson));
    if (root == null) {
      metadata.parseStatusMessage = 'The ComfyUI prompt graph chunk was not a JSON object.';
      return false;
    }

    final saveNodeId = _bestSaveNode(root);
    final saveNode = saveNodeId == null ? null : _node(root, saveNodeId);
    if (saveNode == null) {
      metadata.parseStatusMessage = 'The ComfyUI prompt graph did not contain a SaveImage node.';
      return false;
    }

    final decodeNode = _linked(root, saveNode, 'images');
    if (decodeNode == null) {
      metadata.parseStatusMessage = 'The ComfyUI SaveImage node did not point to a decodable image node.';
      return false;
    }

    final finalSampler = _linked(root, decodeNode, 'samples');
    if (finalSampler == null) {
      metadata.parseStatusMessage = 'The ComfyUI decode node did not point to a KSampler node.';
      return false;
    }

    final finalSteps = _readInt(finalSampler, 'steps');
    metadata.cfgScale = _readDouble(finalSampler, 'cfg');
    metadata.sampler = _readString(finalSampler, 'sampler_name') ?? '';
    metadata.scheduler = _readString(finalSampler, 'scheduler') ?? '';
    metadata.seed = _readInt(finalSampler, 'seed');

    final loras = <String>{};
    final positive = _linked(root, finalSampler, 'positive');
    if (positive != null) {
      metadata.positivePrompt = _readString(positive, 'text') ?? '';
      final clipId = _linkedId(positive, 'clip');
      if (clipId != null) {
        _parseClipChain(root, clipId, metadata, loras);
      }
    }

    final negative = _linked(root, finalSampler, 'negative');
    if (negative != null) {
      metadata.negativePrompt = _readString(negative, 'text') ?? '';
      final clipId = _linkedId(negative, 'clip');
      if (clipId != null) {
        _parseClipChain(root, clipId, metadata, <String>{});
      }
    }

    final modelId = _linkedId(finalSampler, 'model');
    if (modelId != null) {
      _parseModelChain(root, modelId, metadata, loras);
    }

    _populateBaseSize(root, finalSampler, metadata);

    var isHiresFix = false;
    final latentSource = _linked(root, finalSampler, 'latent_image');
    if (latentSource != null && _classType(latentSource) == 'LatentUpscaleBy') {
      isHiresFix = true;
      metadata.hiresSteps = finalSteps;
      metadata.hiresDenoisingStrength = _readDouble(finalSampler, 'denoise');
      final baseSampler = _linked(root, latentSource, 'samples');
      if (baseSampler != null) {
        metadata.steps = _readInt(baseSampler, 'steps') ?? finalSteps;
        metadata.seed ??= _readInt(baseSampler, 'seed');
      } else {
        metadata.steps = finalSteps;
      }
    } else {
      metadata.steps = finalSteps;
    }

    metadata.enableHiresFix = isHiresFix;
    metadata.loras = loras.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    metadata.metadataParsed =
        metadata.positivePrompt.isNotEmpty ||
        metadata.negativePrompt.isNotEmpty ||
        metadata.steps != null ||
        metadata.seed != null;
    metadata.metadataSource = 'ComfyUI prompt graph';
    metadata.parseStatusMessage = metadata.metadataParsed
        ? ''
        : "The ComfyUI prompt graph could not be matched to this app's txt2img workflow.";
    return metadata.metadataParsed;
  }

  static void _parseModelChain(
    Map<String, Object?> root,
    String startId,
    GeneratedImageMetadata metadata,
    Set<String> loras,
  ) {
    String? currentId = startId;
    final visited = <String>{};
    while (currentId != null && visited.add(currentId)) {
      final node = _node(root, currentId);
      if (node == null) {
        return;
      }

      switch (_classType(node)) {
        case 'CheckpointLoaderSimple':
          metadata.checkpoint = _readString(node, 'ckpt_name') ?? metadata.checkpoint;
          return;
        case 'LoraLoader':
        case 'LoraLoaderModelOnly':
          final name = _readString(node, 'lora_name');
          if (name != null && name.isNotEmpty) {
            loras.add(name);
          }

          currentId = _linkedId(node, 'model');
        default:
          return;
      }
    }
  }

  static void _parseClipChain(
    Map<String, Object?> root,
    String startId,
    GeneratedImageMetadata metadata,
    Set<String> loras,
  ) {
    String? currentId = startId;
    final visited = <String>{};
    while (currentId != null && visited.add(currentId)) {
      final node = _node(root, currentId);
      if (node == null) {
        return;
      }

      switch (_classType(node)) {
        case 'CheckpointLoaderSimple':
          if (metadata.checkpoint.isEmpty) {
            metadata.checkpoint = _readString(node, 'ckpt_name') ?? metadata.checkpoint;
          }

          return;
        case 'LoraLoader':
          final name = _readString(node, 'lora_name');
          if (name != null && name.isNotEmpty) {
            loras.add(name);
          }

          currentId = _linkedId(node, 'clip');
        case 'CLIPSetLastLayer':
          final layer = _readInt(node, 'stop_at_clip_layer');
          if (layer != null) {
            metadata.clipSkip = layer.abs();
          }

          currentId = _linkedId(node, 'clip');
        default:
          return;
      }
    }
  }

  static void _populateBaseSize(
    Map<String, Object?> root,
    Map<String, Object?> finalSampler,
    GeneratedImageMetadata metadata,
  ) {
    String? emptyLatentId;
    final latentSourceId = _linkedId(finalSampler, 'latent_image');
    final latentSource = latentSourceId == null ? null : _node(root, latentSourceId);
    if (latentSource != null) {
      final type = _classType(latentSource);
      if (type == 'LatentUpscaleBy') {
        final baseSampler = _linked(root, latentSource, 'samples');
        if (baseSampler != null) {
          emptyLatentId = _linkedId(baseSampler, 'latent_image');
        }
      } else if (type == 'EmptyLatentImage') {
        emptyLatentId = latentSourceId;
      }
    }

    final emptyLatent = emptyLatentId == null ? null : _node(root, emptyLatentId);
    if (emptyLatent != null && _classType(emptyLatent) == 'EmptyLatentImage') {
      metadata.baseWidth = _readInt(emptyLatent, 'width') ?? metadata.baseWidth;
      metadata.baseHeight = _readInt(emptyLatent, 'height') ?? metadata.baseHeight;
    }
  }

  static String? _bestSaveNode(Map<String, Object?> root) {
    String? bestId;
    var bestOrder = -1 << 62;
    for (final entry in root.entries) {
      final node = JsonRead.map(entry.value);
      if (node == null || _classType(node) != 'SaveImage') {
        continue;
      }

      final order = int.tryParse(entry.key) ?? (-1 << 62) + 1;
      if (order >= bestOrder) {
        bestOrder = order;
        bestId = entry.key;
      }
    }

    return bestId;
  }

  static Map<String, Object?>? _node(Map<String, Object?> root, String id) => JsonRead.map(root[id]);

  static String _classType(Map<String, Object?> node) {
    final value = node['class_type'];
    return value is String ? value : '';
  }

  static Object? _input(Map<String, Object?> node, String name) => JsonRead.map(node['inputs'])?[name];

  static String? _linkedId(Map<String, Object?> node, String inputName) {
    final input = _input(node, inputName);
    if (input is! List || input.isEmpty) {
      return null;
    }

    final first = input.first;
    if (first is String && first.isNotEmpty) {
      return first;
    }

    if (first is num) {
      return first.toInt().toString();
    }

    return null;
  }

  static Map<String, Object?>? _linked(Map<String, Object?> root, Map<String, Object?> node, String inputName) {
    final id = _linkedId(node, inputName);
    return id == null ? null : _node(root, id);
  }

  static String? _readString(Map<String, Object?> node, String name) {
    final value = _input(node, name);
    return value is String ? value : null;
  }

  static int? _readInt(Map<String, Object?> node, String name) {
    final value = _input(node, name);
    if (value is num) {
      return value.round();
    }

    if (value is String) {
      return int.tryParse(value) ?? double.tryParse(value)?.round();
    }

    return null;
  }

  static double? _readDouble(Map<String, Object?> node, String name) {
    final value = _input(node, name);
    if (value is num) {
      return value.toDouble();
    }

    return value is String ? double.tryParse(value) : null;
  }
}

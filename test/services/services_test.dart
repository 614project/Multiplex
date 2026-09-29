import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:multiplex/src/models/api_platform.dart';
import 'package:multiplex/src/models/image_metadata.dart';
import 'package:multiplex/src/models/lora_selection.dart';
import 'package:multiplex/src/models/project_data.dart';
import 'package:multiplex/src/models/project_settings.dart';
import 'package:multiplex/src/services/autocomplete_service.dart';
import 'package:multiplex/src/services/png_metadata_reader.dart';
import 'package:multiplex/src/services/project_transfer.dart';

/// Builds a PNG with extra chunks appended before IEND.
Uint8List pngWithChunks(List<(String, List<int>)> chunks, {int width = 16, int height = 8}) {
  final base = img.encodePng(img.Image(width: width, height: height));
  final iendStart = base.length - 12;
  final builder = BytesBuilder()..add(base.sublist(0, iendStart));
  for (final (type, data) in chunks) {
    final length = ByteData(4)..setUint32(0, data.length);
    builder
      ..add(length.buffer.asUint8List())
      ..add(ascii.encode(type))
      ..add(data)
      ..add([0, 0, 0, 0]);
  }

  builder.add(base.sublist(iendStart));
  return builder.toBytes();
}

GeneratedImageMetadata read(Uint8List bytes) =>
    PngMetadataReader.readBytes(bytes, GeneratedImageMetadata(filePath: 'x.png', generatedAt: DateTime(2026)));

void main() {
  group('PngMetadataReader', () {
    test('parses WebUI infotext including Hires.fix details', () {
      const infotext =
          'masterpiece, a cat <lora:style:0.8>\n'
          'Negative prompt: lowres, blurry\n'
          'Steps: 28, Sampler: DPM++ 2M, Schedule type: Karras, CFG scale: 6.5, Seed: 1234, Size: 512x768, '
          'Model: sdxl-base, Denoising strength: 0.45, Clip skip: 2, Hires upscale: 2, Hires steps: 12, '
          'Hires upscaler: Latent, Lora hashes: "style: abc123", Version: v1.10.1';
      final bytes = pngWithChunks(
        [
          ('tEXt', [...latin1.encode('parameters'), 0, ...utf8.encode(infotext)]),
        ],
        width: 1024,
        height: 1536,
      );
      final metadata = read(bytes);

      expect(metadata.metadataParsed, isTrue);
      expect(metadata.positivePrompt, 'masterpiece, a cat <lora:style:0.8>');
      expect(metadata.negativePrompt, 'lowres, blurry');
      expect(metadata.steps, 28);
      expect(metadata.sampler, 'DPM++ 2M');
      expect(metadata.scheduler, 'Karras');
      expect(metadata.cfgScale, 6.5);
      expect(metadata.seed, 1234);
      expect(metadata.checkpoint, 'sdxl-base');
      expect(metadata.clipSkip, 2);
      expect(metadata.hiresSteps, 12);
      expect(metadata.hiresDenoisingStrength, 0.45);
      expect(metadata.enableHiresFix, isTrue);
      expect(metadata.loras, ['style']);
      expect(metadata.sizeText, '1024 × 1536 (Hires.fix from 512 × 768)');
    });

    test('reads compressed zTXt and iTXt chunks', () {
      final compressed = const ZLibEncoder().encodeBytes(utf8.encode('a dog\nSteps: 10, Seed: 7'));
      final metadata = read(
        pngWithChunks([
          ('zTXt', [...latin1.encode('parameters'), 0, 0, ...compressed]),
        ]),
      );
      expect(metadata.positivePrompt, 'a dog');
      expect(metadata.steps, 10);

      final international = read(
        pngWithChunks([
          ('iTXt', [...latin1.encode('parameters'), 0, 0, 0, 0, 0, ...utf8.encode('고양이\nSteps: 5')]),
        ]),
      );
      expect(international.positivePrompt, '고양이');
      expect(international.steps, 5);
    });

    test('explains when no generation metadata exists', () {
      final metadata = read(pngWithChunks(const []));
      expect(metadata.metadataParsed, isFalse);
      expect(metadata.width, 16);
      expect(metadata.parseStatusMessage, 'No PNG text metadata was found in this image.');
    });

    test('rejects files that are not PNG', () {
      final metadata = read(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]));
      expect(metadata.parseStatusMessage, contains('not a valid PNG'));
    });
  });

  group('ProjectTransfer', () {
    test('imports WebuiMultiflex bundle exports with PascalCase keys', () {
      final json = jsonEncode({
        'Format': 'WebuiMultiflex.ProjectBundle',
        'Version': 4,
        'Projects': [
          {
            'Format': 'WebuiMultiflex.Project',
            'Name': 'Portraits',
            'Settings': {
              'ApiBaseUrl': 'http://192.168.0.10:8188',
              'Platform': 'ComfyUI',
              'TimeoutSeconds': 900,
              'CommonPrompt': 'best quality, <CELL_PROMPT>',
              'Steps': 25,
              'CfgScale': 5.5,
              'Width': 832,
              'Height': 1216,
              'SamplerName': 'dpmpp_2m',
              'Scheduler': 'karras',
              'SelectedLoras': [
                {'Name': 'detail', 'Weight': 0.4},
              ],
              'ComfyLoraLoaderType': 'LoraLoaderModelOnly',
              'Seed': 42,
              'EnableHiresFix': true,
              'HiresDenoisingStrength': 3,
            },
            'Cells': [
              {'Order': 1, 'Name': 'Second', 'Prompt': 'b', 'OverrideSteps': 40},
              {'Order': 0, 'Name': '', 'Prompt': 'a', 'RepresentativeImagePath': r'..\..\secret.png'},
            ],
          },
        ],
      });

      final projects = ProjectTransfer.deserialize(json);
      expect(projects, hasLength(1));
      final project = projects.single;
      expect(project.name, 'Portraits');
      expect(project.settings.platform, ApiPlatform.comfyUi);
      expect(project.settings.timeoutSeconds, 900);
      expect(project.settings.cfgScale, 5.5);
      expect(project.settings.width, 832);
      expect(project.settings.selectedLoras, const [LoraSelection(name: 'detail', weight: 0.4)]);
      expect(project.settings.comfyLoraLoaderType, 'LoraLoaderModelOnly');
      expect(project.settings.generationMode, 'Standard');
      expect(project.settings.hiresDenoisingStrength, 1.0);
      expect(project.cells.map((cell) => cell.name), ['Cell 1', 'Second']);
      expect(project.cells.first.representativeImagePath, isNull);
      expect(project.cells.last.overrideSteps, 40);
    });

    test('exports without credentials and round-trips', () {
      final data = ProjectData(
        metadata: ProjectMetadata.create('Landscapes'),
        settings: ProjectSettings(apiBaseUrl: 'http://user:secret@host:7860', steps: 31),
        cells: [CellData(id: 'c1', name: 'Sky', prompt: 'blue sky', overrideCfgScale: 4.5)],
      );

      final json = ProjectTransfer.serializeProject(data);
      expect(json, isNot(contains('secret')));
      expect(json, contains('"ApiBaseUrl": "http://host:7860"'));

      final restored = ProjectTransfer.deserialize(json).single;
      expect(restored.name, 'Landscapes');
      expect(restored.settings.steps, 31);
      expect(restored.cells.single.prompt, 'blue sky');
      expect(restored.cells.single.overrideCfgScale, 4.5);

      final bundle = ProjectTransfer.serializeProjects([data, data]);
      expect(ProjectTransfer.deserialize(bundle), hasLength(2));
    });

    test('rejects empty and unsupported files', () {
      expect(() => ProjectTransfer.deserialize(''), throwsFormatException);
      expect(() => ProjectTransfer.deserialize('42'), throwsFormatException);
    });
  });

  group('Autocomplete', () {
    test('suggests tags by prefix, preferring names over aliases and popular tags', () async {
      final directory = await Directory.systemTemp.createTemp('multiplex-autocomplete-');
      addTearDown(() => directory.delete(recursive: true));
      final custom = File('${directory.path}/custom.csv')..writeAsStringSync('long_hair,0,50,"longhair,lh"\n');
      final danbooru = File('${directory.path}/danbooru.csv')
        ..writeAsStringSync('long_hair,0,900000,\nlong_sleeves,0,500000,\nlowres,5,300000,"low_res"\n');

      final buckets = AutocompleteService.buildBuckets([(custom.path, 0), (danbooru.path, 2)]);
      final entries = buckets['lo']!;
      expect(entries.first.canonical, 'long_hair');
      expect(entries.where((entry) => entry.isAlias).map((entry) => entry.canonical), contains('lowres'));
    });

    test('finds and replaces the fragment at the caret', () {
      const text = 'masterpiece, long ha';
      final fragment = PromptFragment.at(text, text.length)!;
      expect(fragment.text, 'long ha');
      final (replaced, caret) = fragment.apply(text, 'long_hair', appendSeparator: true);
      expect(replaced, 'masterpiece, long hair, ');
      expect(caret, replaced.length);
      expect(PromptFragment.at('a, b', 4), isNull);
    });

    test('normalizes search keys', () {
      expect(AutocompleteService.normalizeSearchKey('  Long   Hair_'), 'long_hair');
    });
  });
}

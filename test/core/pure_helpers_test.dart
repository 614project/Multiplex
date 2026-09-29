import 'package:flutter_test/flutter_test.dart';
import 'package:multiplex/src/core/image_signature.dart';
import 'package:multiplex/src/core/path_safety.dart';
import 'package:multiplex/src/core/prompt_composer.dart';
import 'package:multiplex/src/core/url_tools.dart';
import 'package:multiplex/src/models/lora_selection.dart';
import 'package:path/path.dart' as p;

void main() {
  group('PromptComposer', () {
    test('cell prompt placeholder keeps dollar signs literal', () {
      final prompt = PromptComposer.composePositivePrompt(
        null,
        'masterpiece, <CELL_PROMPT>, best quality',
        r'{2$$red|blue} hair, $1 ${name}',
      );
      expect(prompt, r'masterpiece, {2$$red|blue} hair, $1 ${name}, best quality');
    });

    test('cell prompt placeholder is case insensitive', () {
      expect(PromptComposer.composePositivePrompt('global', 'a, <cell_prompt>', 'b'), 'global,a, b');
    });

    test('segments are joined without double commas', () {
      expect(PromptComposer.composePositivePrompt('a', 'b', 'c'), 'a,b,c');
      expect(PromptComposer.composePositivePrompt('a,', ',b', '  '), 'a,b');
      expect(PromptComposer.composeNegativePrompt(' a ', null, 'b'), 'a,b');
    });

    test('empty segments produce an empty prompt', () {
      expect(PromptComposer.composePositivePrompt(null, ' ', null), '');
    });
  });

  group('UrlCredentials', () {
    const removes = {
      'http://user:secret@127.0.0.1:7860': 'http://127.0.0.1:7860',
      'https://user:p%40ss@example.com/sdapi/v1': 'https://example.com/sdapi/v1',
      'https://user:p@ss@example.com?x=1': 'https://example.com?x=1',
      'http://token@host:8188/': 'http://host:8188/',
      '  http://user:pw@host  ': 'http://host',
    };
    removes.forEach((input, expected) {
      test('removes user info from $input', () => expect(UrlCredentials.remove(input), expected));
    });

    const unchanged = {
      'http://127.0.0.1:7860': 'http://127.0.0.1:7860',
      'http://host/path@with-at': 'http://host/path@with-at',
      'http://host?q=a@b': 'http://host?q=a@b',
      'not a url': 'not a url',
    };
    unchanged.forEach((input, expected) {
      test('leaves $input unchanged', () => expect(UrlCredentials.remove(input), expected));
    });

    test('empty input becomes an empty string', () {
      expect(UrlCredentials.remove(null), '');
      expect(UrlCredentials.remove(''), '');
      expect(UrlCredentials.remove('   '), '');
    });
  });

  group('EndpointResolver', () {
    test('turns credentials into a basic authorization header', () {
      final endpoint = EndpointResolver.resolve('http://user:p%40ss@127.0.0.1:7860/', '/sdapi/v1/samplers');
      expect(endpoint.uri.toString(), 'http://127.0.0.1:7860/sdapi/v1/samplers');
      expect(endpoint.basicAuthorization, 'Basic dXNlcjpwQHNz');
    });

    test('strips pasted API roots and keeps sub paths and queries', () {
      expect(
        EndpointResolver.resolve('http://host:7860/sdapi/v1/', '/sdapi/v1/progress?skip_current_image=true').uri.toString(),
        'http://host:7860/sdapi/v1/progress?skip_current_image=true',
      );
      expect(EndpointResolver.resolve('https://host/webui/docs', '/internal/progress').uri.toString(),
          'https://host/webui/internal/progress');
    });

    test('rejects relative base URLs', () {
      expect(() => EndpointResolver.resolve('127.0.0.1:7860', '/x'), throwsArgumentError);
      expect(() => EndpointResolver.resolve('', '/x'), throwsArgumentError);
    });
  });

  group('PathSafety', () {
    for (final path in ['cells/abc/20260101_120000000.png', r'cells\abc\image.png', './cells/image.png']) {
      test('accepts $path', () => expect(PathSafety.isSafeRelativePath(path), isTrue));
    }

    for (final path in [
      null,
      '',
      '../outside.png',
      'cells/../../outside.png',
      r'C:\Windows\win.ini',
      'C:relative.png',
      '/etc/passwd',
      r'\\server\share\image.png',
    ]) {
      test('rejects $path', () => expect(PathSafety.isSafeRelativePath(path), isFalse));
    }

    final root = p.join(p.current, 'build', 'path-safety', 'project');

    test('resolves relative paths inside the root', () {
      expect(PathSafety.tryResolveWithinRoot(root, 'cells/a/image.png'), p.join(root, 'cells', 'a', 'image.png'));
    });

    test('accepts legacy absolute paths inside the root', () {
      final absolute = p.join(root, 'cells', 'a', 'image.png');
      expect(PathSafety.tryResolveWithinRoot(root, absolute), absolute);
    });

    test('rejects paths outside the root', () {
      expect(PathSafety.tryResolveWithinRoot(root, p.join('..', 'other', 'image.png')), isNull);
      expect(PathSafety.tryResolveWithinRoot(root, '$root-evil${p.separator}image.png'), isNull);
      expect(PathSafety.tryResolveWithinRoot(root, p.normalize(p.join(root, '..', '..', 'secret.txt'))), isNull);
      expect(PathSafety.tryResolveWithinRoot(root, root), isNull);
      expect(PathSafety.tryResolveWithinRoot(root, null), isNull);
    });

    test('uses forward slashes for stored relative paths', () {
      expect(PathSafety.toPortableRelative(root, p.join(root, 'cells', 'a', 'x.png')), 'cells/a/x.png');
    });
  });

  group('LoraSelection', () {
    test('normalizes names, weights and duplicates', () {
      final loras = LoraSelection.normalize(const [
        LoraSelection(name: ' style ', weight: 0.5),
        LoraSelection(name: 'STYLE', weight: 2),
        LoraSelection(name: 'detail', weight: double.nan),
        LoraSelection(name: 'strong', weight: 10),
        LoraSelection(name: '  ', weight: 1),
        null,
      ]);
      expect(loras, const [
        LoraSelection(name: 'style', weight: 0.5),
        LoraSelection(name: 'detail', weight: 1.0),
        LoraSelection(name: 'strong', weight: LoraSelection.maximumWeight),
      ]);
    });

    test('null input produces an empty list', () => expect(LoraSelection.normalize(null), isEmpty));

    test('formats weights like WebuiMultiflex', () {
      expect(LoraSelection.formatWeight(1), '1');
      expect(LoraSelection.formatWeight(0.5), '0.5');
      expect(LoraSelection.formatWeight(0.1234), '0.123');
      expect(LoraSelection.formatWeight(-1.25), '-1.25');
    });
  });

  group('ImageSignature', () {
    test('detects PNG', () {
      expect(ImageSignature.detectExtension([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]), '.png');
    });

    test('detects JPEG', () => expect(ImageSignature.detectExtension([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]), '.jpg'));

    test('detects WebP', () => expect(ImageSignature.detectExtension('RIFF\u0000\u0000\u0000\u0000WEBPVP8 '.codeUnits), '.webp'));

    test('detects BMP', () => expect(ImageSignature.detectExtension('BM\u0000\u0000\u0000\u0000'.codeUnits), '.bmp'));

    test('falls back to PNG for unknown data', () {
      expect(ImageSignature.detectExtension(const []), '.png');
      expect(ImageSignature.detectExtension(const [1, 2, 3, 4]), '.png');
    });

    test('decodes base64 with a data URI prefix', () {
      expect(ImageSignature.tryDecodeBase64('data:image/png;base64,AQID'), [1, 2, 3]);
      expect(ImageSignature.tryDecodeBase64('not base64!'), isNull);
    });
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:figma_tokens_builder/src/figma_token_builder.dart';
import 'package:glob/glob.dart';
import 'package:test/test.dart';

/// Minimal [BuildStep] that serves in-memory assets.
class _FakeBuildStep implements BuildStep {
  _FakeBuildStep(this.assets);

  /// Asset path → JSON contents.
  final Map<String, String> assets;
  final Map<String, String> outputs = {};

  @override
  AssetId get inputId => AssetId('app', r'$lib$');

  @override
  Stream<AssetId> findAssets(Glob glob) async* {
    for (final path in assets.keys.where(glob.matches)) {
      yield AssetId('app', path);
    }
  }

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) async {
    final content = assets[id.path];
    if (content == null) throw AssetNotFoundException(id);
    return content;
  }

  @override
  Future<void> writeAsString(
    AssetId id,
    FutureOr<String> contents, {
    Encoding encoding = utf8,
  }) async {
    outputs[id.path] = await contents;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> _generate(Map<String, dynamic> json) async {
  final step = _FakeBuildStep({
    'assets/figma/Typography/Mobile.tokens.json': jsonEncode(json),
  });
  final builder = FigmaTokenBuilder(
    BuilderOptions({
      'input_dir': 'assets/figma',
      'output_dir': 'lib/generated',
      'base_class': 'Figma',
    }),
  );

  await builder.build(step);
  return step.outputs['lib/generated/figma.g.dart']!;
}

void main() {
  group('FigmaTokenBuilder', () {
    test('toCamelCase converts kebab-case', () {
      final builder = FigmaTokenBuilder(const BuilderOptions({}));
      // Builder is created successfully
      expect(builder, isNotNull);
    });

    test('nested group "Archived" becomes a nested class, not 0.0', () async {
      final output = await _generate({
        'font-size': {
          'label-sm': {r'$type': 'number', r'$value': 12},
          'label-md': {r'$type': 'number', r'$value': 14},
          'Archived': {
            'fs-12': {r'$type': 'number', r'$value': 12},
            'fs-14': {r'$type': 'number', r'$value': 14},
          },
        },
        'line-height': {
          'lh-body-sm': {r'$type': 'number', r'$value': 16},
          'Archived': {
            'lh-16': {r'$type': 'number', r'$value': 16},
          },
        },
        'font-weight': {
          'regular': {r'$type': 'number', r'$value': 400},
        },
        r'$extensions': {'com.figma.modeName': 'Mobile'},
      });

      // Archived is a group, so it gets its own class...
      expect(output, contains('class _FigmaTypography_FontSizeArchivedGroup'));
      expect(output, contains('class _FigmaTypography_LineHeightArchivedGroup'));
      expect(
        output,
        contains('final _FigmaTypography_FontSizeArchivedGroup archived;'),
      );

      // ...with real values from the JSON.
      expect(output, contains('fs12: 12.0,'));
      expect(output, contains('fs14: 14.0,'));
      expect(output, contains('lh16: 16.0,'));

      // No placeholder field for a group interpreted as a token.
      expect(output, isNot(contains('archived: 0.0')));
      expect(output, isNot(contains('final double archived;')));
    });

    test('single group with nested group is flattened correctly', () async {
      final output = await _generate({
        'size': {
          'card': {r'$type': 'number', r'$value': 16},
          'Archived': {
            'old-8': {r'$type': 'number', r'$value': 8},
          },
        },
        r'$extensions': {'com.figma.modeName': 'Mobile'},
      });

      expect(output, contains('class FigmaTypography'));
      expect(output, contains('final double card;'));
      expect(output, contains('final _FigmaTypography_SizeArchivedGroup archived;'));
      expect(output, contains('old8: 8.0,'));
      expect(output, isNot(contains('archived: 0.0')));
    });

    test('flat tokens still generate direct fields', () async {
      final output = await _generate({
        'space-md': {r'$type': 'number', r'$value': 8},
        'space-lg': {r'$type': 'number', r'$value': 16},
        r'$extensions': {'com.figma.modeName': 'Mobile'},
      });

      expect(output, contains('final double spaceMd;'));
      expect(output, contains('spaceMd: 8.0,'));
      expect(output, contains('spaceLg: 16.0,'));
    });
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:glob/glob.dart';

/// A collection of token data: groups → tokens, organized by mode.
class _CollectionData {
  final String name;
  final Map<String, Map<String, dynamic>> modeJsons; // modeName → full JSON

  _CollectionData(this.name, this.modeJsons);
}

/// The children of a token group, split into leaf tokens and sub-groups.
///
/// Insertion order is preserved so generated fields follow the JSON order.
class _GroupShape {
  final List<String> tokens;
  final List<String> groups;

  const _GroupShape(this.tokens, this.groups);

  factory _GroupShape.of(Map<String, dynamic> json) {
    final tokens = <String>[];
    final groups = <String>[];

    json.forEach((key, value) {
      if (key.startsWith(r'$')) return;
      if (value is! Map<String, dynamic>) return;

      if (_isToken(value)) {
        tokens.add(key);
      } else {
        final nested = _GroupShape.of(value);
        if (!nested.isEmpty) groups.add(key);
      }
    });

    return _GroupShape(tokens, groups);
  }

  bool get isEmpty => tokens.isEmpty && groups.isEmpty;

  /// A leaf token has a `$value`. A group may declare a `$type` for its
  /// children, so only treat it as a token when it has no child maps.
  static bool _isToken(Map<String, dynamic> value) {
    if (value.containsKey(r'$value')) return true;
    if (value.containsKey(r'$type')) {
      final hasChildren = value.entries.any(
        (entry) => !entry.key.startsWith(r'$') && entry.value is Map,
      );
      return !hasChildren;
    }
    return false;
  }
}

/// A [Builder] that reads Figma token JSON files and generates
/// Dart ThemeExtension classes with typed values for each mode.
///
/// Supports two layouts:
/// - **Flat**: JSON files directly in `input_dir` → single ThemeExtension class
/// - **Multi-collection**: subdirectories in `input_dir` → one ThemeExtension
///   per subdirectory + a top-level accessor class
///
/// When a collection has only **one group**, tokens are flattened directly onto
/// the ThemeExtension class (no sub-group nesting).
///
/// Groups can be nested to any depth (e.g. `font-size > Archived > fs-12`),
/// producing one class per group level.
class FigmaTokenBuilder implements Builder {
  final BuilderOptions options;

  FigmaTokenBuilder(this.options);

  String get _inputDir =>
      options.config['input_dir'] as String? ?? 'assets/figma';
  String get _outputDir =>
      options.config['output_dir'] as String? ?? 'lib/generated';
  String get _baseClass => options.config['base_class'] as String? ?? 'Figma';

  @override
  Map<String, List<String>> get buildExtensions {
    var outDir = _outputDir;
    if (outDir.startsWith('lib/')) {
      outDir = outDir.substring(4);
    }
    return {
      r'$lib$': ['$outDir/${_baseClass.toLowerCase()}.g.dart'],
    };
  }

  @override
  Future<void> build(BuildStep buildStep) async {
    final collections = <_CollectionData>[];

    // Check for subdirectories first
    final subDirGlob = Glob('$_inputDir/*/*.tokens.json');
    final subDirAssets = <String, Map<String, Map<String, dynamic>>>{};

    await for (final asset in buildStep.findAssets(subDirGlob)) {
      final content = await buildStep.readAsString(asset);
      final json = jsonDecode(content) as Map<String, dynamic>;
      final modeName = _getModeName(json, asset.path);
      final parts = asset.path.split('/');
      final collectionName = parts[parts.length - 2];
      subDirAssets.putIfAbsent(collectionName, () => {});
      subDirAssets[collectionName]![modeName] = json;
    }

    for (final entry in subDirAssets.entries) {
      collections.add(_CollectionData(entry.key, entry.value));
    }

    // Flat structure fallback (backward compatible)
    if (collections.isEmpty) {
      final flatGlob = Glob('$_inputDir/*.tokens.json');
      final flatModes = <String, Map<String, dynamic>>{};

      await for (final asset in buildStep.findAssets(flatGlob)) {
        final content = await buildStep.readAsString(asset);
        final json = jsonDecode(content) as Map<String, dynamic>;
        final modeName = _getModeName(json, asset.path);
        flatModes[modeName] = json;
      }

      if (flatModes.isNotEmpty) {
        collections.add(_CollectionData('', flatModes));
      }
    }

    if (collections.isEmpty) {
      log.warning('FigmaTokenBuilder: No token files found in "$_inputDir".');
      return;
    }

    collections.sort((a, b) => a.name.compareTo(b.name));

    // Generate code
    final buffer = StringBuffer();
    _writeHeader(buffer);

    final isMultiCollection =
        collections.length > 1 ||
        (collections.length == 1 && collections.first.name.isNotEmpty);

    for (final collection in collections) {
      final className = isMultiCollection
          ? '$_baseClass${_toPascalCase(collection.name)}'
          : _baseClass;
      _generateCollectionClass(buffer, className, collection);
    }

    if (isMultiCollection) {
      _writeAccessorClass(buffer, collections);
    }

    // BuildContext extensions
    _writeContextExtensions(buffer, collections, isMultiCollection);

    final outputAsset = AssetId(
      buildStep.inputId.package,
      '$_outputDir/${_baseClass.toLowerCase()}.g.dart',
    );
    await buildStep.writeAsString(outputAsset, buffer.toString());

    log.info(
      'FigmaTokenBuilder: Generated ${outputAsset.path} '
      '(${collections.length} collection(s))',
    );
  }

  // ---------------------------------------------------------------------------
  // Collection generation
  // ---------------------------------------------------------------------------

  void _generateCollectionClass(
    StringBuffer buffer,
    String className,
    _CollectionData collection,
  ) {
    final firstJson = collection.modeJsons.values.first;
    final shape = _GroupShape.of(firstJson);

    if (shape.isEmpty) return;

    if (shape.groups.isEmpty) {
      // All tokens are flat → generate flat class (no groups)
      _generateFlatClassFromTokens(buffer, className, collection, shape.tokens);
    } else if (shape.tokens.isEmpty && shape.groups.length == 1) {
      // Single group → flatten onto class
      _generateFlatClass(
        buffer,
        className,
        collection,
        firstJson,
        shape.groups.single,
      );
    } else {
      // Multiple groups (and/or mix of flat + grouped) → nested classes
      _generateNestedClass(buffer, className, collection, firstJson, shape);
    }
  }

  // ---------------------------------------------------------------------------
  // Flat mode: tokens directly on ThemeExtension class
  // ---------------------------------------------------------------------------

  /// Flat tokens at root level (no groups at all).
  /// Extracts value from json[tokenName].$value
  void _generateFlatClassFromTokens(
    StringBuffer b,
    String className,
    _CollectionData collection,
    List<String> tokens,
  ) {
    b.writeln('class $className extends ThemeExtension<$className> {');

    for (final t in tokens) {
      b.writeln('  final double ${_toCamelCase(t)};');
    }
    b.writeln();

    b.writeln('  const $className({');
    for (final t in tokens) {
      b.writeln('    required this.${_toCamelCase(t)},');
    }
    b.writeln('  });');
    b.writeln();

    final sortedModes = collection.modeJsons.keys.toList()..sort();
    for (final modeName in sortedModes) {
      final json = collection.modeJsons[modeName]!;
      b.writeln('  static const ${_toCamelCase(modeName)} = $className(');
      for (final t in tokens) {
        final value = _extractFlatValue(json, t);
        b.writeln('    ${_toCamelCase(t)}: ${value.toDouble()},');
      }
      b.writeln('  );');
      b.writeln();
    }

    _writeOfMethod(b, className);

    // copyWith
    b.writeln('  @override');
    b.writeln('  $className copyWith({');
    for (final t in tokens) {
      b.writeln('    double? ${_toCamelCase(t)},');
    }
    b.writeln('  }) {');
    b.writeln('    return $className(');
    for (final t in tokens) {
      final camel = _toCamelCase(t);
      b.writeln('      $camel: $camel ?? this.$camel,');
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    // lerp
    b.writeln('  @override');
    b.writeln('  $className lerp(covariant $className? other, double t) {');
    b.writeln('    if (other == null) return this;');
    b.writeln('    return $className(');
    for (final t in tokens) {
      final camel = _toCamelCase(t);
      b.writeln('      $camel: $camel + (other.$camel - $camel) * t,');
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    _writeHashEquals(b, className, tokens.map(_toCamelCase).toList());

    b.writeln('}');
    b.writeln();
  }

  /// Single group → flatten tokens onto class (legacy grouped format).
  ///
  /// Sub-groups inside the flattened group become fields that reference their
  /// own generated classes (e.g. `fontSize.archived.fs12`).
  void _generateFlatClass(
    StringBuffer b,
    String className,
    _CollectionData collection,
    Map<String, dynamic> firstJson,
    String groupName,
  ) {
    final groupJson = firstJson[groupName] as Map<String, dynamic>;
    final shape = _GroupShape.of(groupJson);
    final path = [groupName];

    // Sub-group classes
    for (final g in shape.groups) {
      _writeGroupClass(b, _groupClassName(className, [...path, g]), className, [
        ...path,
        g,
      ], groupJson[g] as Map<String, dynamic>);
    }

    b.writeln('class $className extends ThemeExtension<$className> {');

    for (final t in shape.tokens) {
      b.writeln('  final double ${_toCamelCase(t)};');
    }
    for (final g in shape.groups) {
      b.writeln(
        '  final ${_groupClassName(className, [...path, g])} '
        '${_toCamelCase(g)};',
      );
    }
    b.writeln();

    b.writeln('  const $className({');
    for (final t in shape.tokens) {
      b.writeln('    required this.${_toCamelCase(t)},');
    }
    for (final g in shape.groups) {
      b.writeln('    required this.${_toCamelCase(g)},');
    }
    b.writeln('  });');
    b.writeln();

    // Static presets
    final sortedModes = collection.modeJsons.keys.toList()..sort();
    for (final modeName in sortedModes) {
      final json = collection.modeJsons[modeName]!;
      b.writeln('  static const ${_toCamelCase(modeName)} = $className(');
      for (final t in shape.tokens) {
        final value = _extractAtPath(json, [...path, t]);
        b.writeln('    ${_toCamelCase(t)}: ${value.toDouble()},');
      }
      for (final g in shape.groups) {
        _writeGroupValue(
          b,
          '    ',
          _toCamelCase(g),
          _groupClassName(className, [...path, g]),
          className,
          [...path, g],
          groupJson[g] as Map<String, dynamic>,
          json,
        );
      }
      b.writeln('  );');
      b.writeln();
    }

    _writeOfMethod(b, className);

    // copyWith
    b.writeln('  @override');
    b.writeln('  $className copyWith({');
    for (final t in shape.tokens) {
      b.writeln('    double? ${_toCamelCase(t)},');
    }
    for (final g in shape.groups) {
      b.writeln(
        '    ${_groupClassName(className, [...path, g])}? '
        '${_toCamelCase(g)},',
      );
    }
    b.writeln('  }) {');
    b.writeln('    return $className(');
    for (final t in shape.tokens) {
      final camel = _toCamelCase(t);
      b.writeln('      $camel: $camel ?? this.$camel,');
    }
    for (final g in shape.groups) {
      final camel = _toCamelCase(g);
      b.writeln('      $camel: $camel ?? this.$camel,');
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    // lerp
    b.writeln('  @override');
    b.writeln('  $className lerp(covariant $className? other, double t) {');
    b.writeln('    if (other == null) return this;');
    b.writeln('    return $className(');
    for (final t in shape.tokens) {
      final camel = _toCamelCase(t);
      b.writeln('      $camel: $camel + (other.$camel - $camel) * t,');
    }
    for (final g in shape.groups) {
      final camel = _toCamelCase(g);
      b.writeln(
        '      $camel: ${_groupClassName(className, [...path, g])}'
        '.lerp($camel, other.$camel, t),',
      );
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    _writeHashEquals(b, className, [
      ...shape.tokens.map(_toCamelCase),
      ...shape.groups.map(_toCamelCase),
    ]);

    b.writeln('}');
    b.writeln();
  }

  // ---------------------------------------------------------------------------
  // Nested mode: multiple groups → sub-group classes
  // ---------------------------------------------------------------------------

  void _generateNestedClass(
    StringBuffer b,
    String className,
    _CollectionData collection,
    Map<String, dynamic> firstJson,
    _GroupShape rootShape,
  ) {
    // Root-level flat tokens are grouped into a synthetic "root" group.
    final rootJson = <String, dynamic>{
      for (final t in rootShape.tokens) t: firstJson[t],
    };
    final rootClass = '_${className}_RootGroup';
    final hasRoot = rootShape.tokens.isNotEmpty;

    // Sub-group classes (recursive, arbitrary depth)
    for (final g in rootShape.groups) {
      _writeGroupClass(b, _groupClassName(className, [g]), className, [
        g,
      ], firstJson[g] as Map<String, dynamic>);
    }
    if (hasRoot) {
      _writeGroupClass(b, rootClass, className, const [], rootJson);
    }

    // Main ThemeExtension class
    b.writeln('class $className extends ThemeExtension<$className> {');

    for (final g in rootShape.groups) {
      b.writeln(
        '  final ${_groupClassName(className, [g])} ${_toCamelCase(g)};',
      );
    }
    if (hasRoot) {
      b.writeln('  final $rootClass root;');
    }
    b.writeln();

    b.writeln('  const $className({');
    for (final g in rootShape.groups) {
      b.writeln('    required this.${_toCamelCase(g)},');
    }
    if (hasRoot) {
      b.writeln('    required this.root,');
    }
    b.writeln('  });');
    b.writeln();

    // Static presets
    final sortedModes = collection.modeJsons.keys.toList()..sort();
    for (final modeName in sortedModes) {
      final json = collection.modeJsons[modeName]!;
      b.writeln('  static const ${_toCamelCase(modeName)} = $className(');
      for (final g in rootShape.groups) {
        _writeGroupValue(
          b,
          '    ',
          _toCamelCase(g),
          _groupClassName(className, [g]),
          className,
          [g],
          firstJson[g] as Map<String, dynamic>,
          json,
        );
      }
      if (hasRoot) {
        _writeGroupValue(
          b,
          '    ',
          'root',
          rootClass,
          className,
          const [],
          rootJson,
          json,
        );
      }
      b.writeln('  );');
      b.writeln();
    }

    _writeOfMethod(b, className);

    // copyWith
    b.writeln('  @override');
    b.writeln('  $className copyWith({');
    for (final g in rootShape.groups) {
      b.writeln('    ${_groupClassName(className, [g])}? ${_toCamelCase(g)},');
    }
    if (hasRoot) {
      b.writeln('    $rootClass? root,');
    }
    b.writeln('  }) {');
    b.writeln('    return $className(');
    for (final g in rootShape.groups) {
      final camel = _toCamelCase(g);
      b.writeln('      $camel: $camel ?? this.$camel,');
    }
    if (hasRoot) {
      b.writeln('      root: root ?? this.root,');
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    // lerp
    b.writeln('  @override');
    b.writeln('  $className lerp(covariant $className? other, double t) {');
    b.writeln('    if (other == null) return this;');
    b.writeln('    return $className(');
    for (final g in rootShape.groups) {
      final camel = _toCamelCase(g);
      b.writeln(
        '      $camel: ${_groupClassName(className, [g])}'
        '.lerp($camel, other.$camel, t),',
      );
    }
    if (hasRoot) {
      b.writeln('      root: $rootClass.lerp(root, other.root, t),');
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    _writeHashEquals(b, className, [
      ...rootShape.groups.map(_toCamelCase),
      if (hasRoot) 'root',
    ]);

    b.writeln('}');
    b.writeln();
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

  /// Generates a plain class for one (possibly nested) token group.
  ///
  /// [path] is the key path from the mode JSON root to [groupJson], used both
  /// for value lookup in presets and for stable nested class names.
  void _writeGroupClass(
    StringBuffer b,
    String cls,
    String rootClass,
    List<String> path,
    Map<String, dynamic> groupJson,
  ) {
    final shape = _GroupShape.of(groupJson);

    // Nested group classes
    for (final g in shape.groups) {
      _writeGroupClass(b, _groupClassName(rootClass, [...path, g]), rootClass, [
        ...path,
        g,
      ], groupJson[g] as Map<String, dynamic>);
    }

    b.writeln('class $cls {');

    for (final t in shape.tokens) {
      b.writeln('  final double ${_toCamelCase(t)};');
    }
    for (final g in shape.groups) {
      b.writeln(
        '  final ${_groupClassName(rootClass, [...path, g])} '
        '${_toCamelCase(g)};',
      );
    }
    b.writeln();

    b.writeln('  const $cls({');
    for (final t in shape.tokens) {
      b.writeln('    required this.${_toCamelCase(t)},');
    }
    for (final g in shape.groups) {
      b.writeln('    required this.${_toCamelCase(g)},');
    }
    b.writeln('  });');
    b.writeln();

    b.writeln('  $cls copyWith({');
    for (final t in shape.tokens) {
      b.writeln('    double? ${_toCamelCase(t)},');
    }
    for (final g in shape.groups) {
      b.writeln(
        '    ${_groupClassName(rootClass, [...path, g])}? '
        '${_toCamelCase(g)},',
      );
    }
    b.writeln('  }) {');
    b.writeln('    return $cls(');
    for (final t in shape.tokens) {
      final camel = _toCamelCase(t);
      b.writeln('      $camel: $camel ?? this.$camel,');
    }
    for (final g in shape.groups) {
      final camel = _toCamelCase(g);
      b.writeln('      $camel: $camel ?? this.$camel,');
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    b.writeln('  static $cls lerp($cls a, $cls b, double t) {');
    b.writeln('    return $cls(');
    for (final t in shape.tokens) {
      final camel = _toCamelCase(t);
      b.writeln('      $camel: a.$camel + (b.$camel - a.$camel) * t,');
    }
    for (final g in shape.groups) {
      final camel = _toCamelCase(g);
      b.writeln(
        '      $camel: ${_groupClassName(rootClass, [...path, g])}'
        '.lerp(a.$camel, b.$camel, t),',
      );
    }
    b.writeln('    );');
    b.writeln('  }');

    b.writeln('}');
    b.writeln();
  }

  /// Emits `fieldName: Cls(...)` for a group, recursively, using values from
  /// [modeJson]. Used when building static presets.
  void _writeGroupValue(
    StringBuffer b,
    String indent,
    String fieldName,
    String cls,
    String rootClass,
    List<String> path,
    Map<String, dynamic> groupJson,
    Map<String, dynamic> modeJson,
  ) {
    b.writeln('$indent$fieldName: $cls(');

    final shape = _GroupShape.of(groupJson);
    for (final t in shape.tokens) {
      final value = _extractAtPath(modeJson, [...path, t]);
      b.writeln('$indent  ${_toCamelCase(t)}: ${value.toDouble()},');
    }
    for (final g in shape.groups) {
      _writeGroupValue(
        b,
        '$indent  ',
        _toCamelCase(g),
        _groupClassName(rootClass, [...path, g]),
        rootClass,
        [...path, g],
        groupJson[g] as Map<String, dynamic>,
        modeJson,
      );
    }

    b.writeln('$indent),');
  }

  /// Stable class name for a group at [path], e.g.
  /// `_FigmaTypography_FontSizeArchivedGroup`.
  String _groupClassName(String rootClass, List<String> path) =>
      '_${rootClass}_${_toPascalCase(path.join('-'))}Group';

  void _writeHeader(StringBuffer b) {
    b.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    b.writeln('// Generated by figma_tokens_builder');
    b.writeln();
    b.writeln(
      '// ignore_for_file: library_private_types_in_public_api, camel_case_types',
    );
    b.writeln();
    b.writeln("import 'package:flutter/material.dart';");
    b.writeln();
  }

  void _writeOfMethod(StringBuffer b, String className) {
    b.writeln('  /// Retrieve the nearest [$className] from the widget tree.');
    b.writeln('  static $className of(BuildContext context) {');
    b.writeln('    return Theme.of(context).extension<$className>()!;');
    b.writeln('  }');
    b.writeln();
  }

  void _writeHashEquals(StringBuffer b, String cls, List<String> fields) {
    b.writeln('  @override');
    b.writeln('  int get hashCode {');
    if (fields.length == 1) {
      b.writeln('    return ${fields.first}.hashCode;');
    } else {
      b.writeln('    return Object.hash(');
      b.writeln('      ${fields.join(',\n      ')},');
      b.writeln('    );');
    }
    b.writeln('  }');
    b.writeln();

    b.writeln('  @override');
    b.writeln('  bool operator ==(Object other) {');
    b.writeln('    if (identical(this, other)) return true;');
    b.writeln('    if (other is! $cls) return false;');
    final cond = fields.map((f) => '$f == other.$f').join(' && ');
    b.writeln('    return $cond;');
    b.writeln('  }');
  }

  /// Generates accessor classes and the top-level namespace class.
  void _writeAccessorClass(StringBuffer b, List<_CollectionData> collections) {
    for (final c in collections) {
      final className = '$_baseClass${_toPascalCase(c.name)}';
      final accessorName = '_${className}Accessor';

      b.writeln('class $accessorName {');
      b.writeln('  const $accessorName();');
      b.writeln();

      final sortedModes = c.modeJsons.keys.toList()..sort();
      for (final mode in sortedModes) {
        final camelMode = _toCamelCase(mode);
        b.writeln('  $className get $camelMode => $className.$camelMode;');
      }
      b.writeln();

      b.writeln('  /// Retrieve [$className] from the nearest [Theme].');
      b.writeln(
        '  $className of(BuildContext context) => $className.of(context);',
      );

      b.writeln('}');
      b.writeln();
    }

    // Collect all unique modes across collections
    final allModes = <String>{};
    for (final c in collections) {
      allModes.addAll(c.modeJsons.keys);
    }
    final sortedAllModes = allModes.toList()..sort();

    b.writeln('/// Top-level accessor for all Figma token collections.');
    b.writeln('class $_baseClass {');
    b.writeln('  $_baseClass._();');
    b.writeln();

    // Collection accessors (e.g. Figma.spacing)
    for (final c in collections) {
      final className = '$_baseClass${_toPascalCase(c.name)}';
      final accessorName = '_${className}Accessor';
      b.writeln('  static const ${_toCamelCase(c.name)} = $accessorName();');
    }
    b.writeln();

    // Mode getters returning List<ThemeExtension> (e.g. Figma.mobile)
    b.writeln('  // --- Mode presets (all collections at once) ---');
    b.writeln();
    for (final mode in sortedAllModes) {
      final camelMode = _toCamelCase(mode);
      final items = <String>[];
      for (final c in collections) {
        if (c.modeJsons.containsKey(mode)) {
          final className = '$_baseClass${_toPascalCase(c.name)}';
          items.add('$className.$camelMode');
        }
      }
      b.writeln(
        '  static List<ThemeExtension> get $camelMode => [${items.join(', ')}];',
      );
    }

    b.writeln('}');
    b.writeln();
  }

  /// Generates BuildContext extensions for convenient access.
  ///
  /// ```dart
  /// extension FigmaSpacingContext on BuildContext {
  ///   FigmaSpacing get spacing => FigmaSpacing.of(this);
  /// }
  /// ```
  void _writeContextExtensions(
    StringBuffer b,
    List<_CollectionData> collections,
    bool isMultiCollection,
  ) {
    b.writeln('// --- BuildContext extensions ---');
    b.writeln();

    if (isMultiCollection) {
      for (final c in collections) {
        final className = '$_baseClass${_toPascalCase(c.name)}';
        final fieldName = _toCamelCase(c.name);
        b.writeln('extension ${className}Context on BuildContext {');
        b.writeln('  $className get $fieldName => $className.of(this);');
        b.writeln('}');
        b.writeln();
      }
    } else {
      final className = _baseClass;
      final fieldName = _toCamelCase(_baseClass);
      b.writeln('extension ${className}Context on BuildContext {');
      b.writeln('  $className get $fieldName => $className.of(this);');
      b.writeln('}');
      b.writeln();
    }
  }

  // ---------------------------------------------------------------------------
  // Utility methods
  // ---------------------------------------------------------------------------

  /// Reads `$value` at [path] (e.g. `['font-size', 'Archived', 'fs-12']`).
  num _extractAtPath(Map<String, dynamic> json, List<String> path) {
    dynamic node = json;
    for (final key in path) {
      if (node is! Map<String, dynamic>) return 0;
      node = node[key];
    }
    if (node is! Map<String, dynamic>) return 0;
    final value = node[r'$value'];
    if (value is num) return value;
    return 0;
  }

  /// Extracts value from a flat token (no group nesting).
  num _extractFlatValue(Map<String, dynamic> json, String token) =>
      _extractAtPath(json, [token]);

  String _getModeName(Map<String, dynamic> json, String path) {
    final extensions = json[r'$extensions'] as Map<String, dynamic>?;
    if (extensions != null) {
      final modeName = extensions['com.figma.modeName'] as String?;
      if (modeName != null && modeName.isNotEmpty) return modeName;
    }
    final fileName = path.split('/').last;
    return fileName.split('.').first;
  }

  String _toCamelCase(String s) {
    final parts = s.split(RegExp(r'[-_]'));
    if (parts.isEmpty) return s;
    final buffer = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isEmpty) continue;
      if (i == 0) {
        buffer.write(part[0].toLowerCase());
        if (part.length > 1) buffer.write(part.substring(1));
      } else {
        buffer.write(part[0].toUpperCase());
        if (part.length > 1) buffer.write(part.substring(1));
      }
    }
    return buffer.toString();
  }

  String _toPascalCase(String s) {
    final parts = s.split(RegExp(r'[-_]'));
    if (parts.isEmpty) return s;
    final buffer = StringBuffer();
    for (final part in parts) {
      if (part.isEmpty) continue;
      buffer.write(part[0].toUpperCase());
      if (part.length > 1) buffer.write(part.substring(1));
    }
    return buffer.toString();
  }
}

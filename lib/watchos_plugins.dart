// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/platform_plugins.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:yaml/yaml.dart';

import 'watchos_host_mode.dart';
import 'watchos_swift_package_manager.dart';

/// Pubspec key, nested under `flutter.plugin.platforms.watchos`, by which an
/// FFI plugin declares the C symbols it exports for `dart:ffi` lookup. The
/// symbols are kept in the binary by `-force_load` of the plugin archive (see
/// `build_targets/application.dart`); this list documents and validates them.
const String kWatchosFfiSymbols = 'ffiSymbols';

/// A C identifier: a letter or underscore followed by letters, digits, or
/// underscores. Declared FFI symbol names are validated against this at parse
/// time, so a malformed pubspec entry is rejected rather than stored.
final RegExp _cIdentifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

const String _swiftPluginRegistryTemplate = '''
//
//  Generated file. Do not edit.
//

import Flutter
import Foundation

{{#methodChannelPlugins}}
import {{name}}
{{/methodChannelPlugins}}

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  {{#methodChannelPlugins}}
  {{class}}.register(with: registry.registrar(forPlugin: "{{class}}"))
{{/methodChannelPlugins}}
}
''';

/// Snapshot of the user-facing plugins for which a federated `<name>_watchos`
/// package is published under the `flutterwatch.dev` verified publisher.
///
/// Keys are the **user-facing** pub package names (the aggregator the app pulls
/// into its pubspec). Values are alternative watchOS implementations the user
/// might already have. Empty list means the canonical `<name>_watchos` is the
/// only acceptable fix.
///
/// Currently empty: the `flutterwatch.dev` publisher has no packages yet. Add
/// entries as it gains them so [recommendWatchosPluginsToInstall] can suggest
/// them. Never add a name that isn't actually published — recommending a
/// non-existent package is worse than staying silent.
const Map<String, List<String>> _kKnownWatchosPlugins = <String, List<String>>{};

/// One entry surfaced by [_walkPluginDependencies].
class _DependencyPluginYaml {
  _DependencyPluginYaml({required this.name, required this.path, required this.pluginYaml});

  /// Pub package name (e.g. `audioplayers`).
  final String name;

  /// Resolved absolute filesystem path to the plugin's checkout.
  final String path;

  /// The `flutter.plugin:` map from the plugin's `pubspec.yaml`.
  final YamlMap pluginYaml;
}

/// Walks the project's plugin dependency graph and yields each entry that
/// declares a `flutter.plugin:` block, regardless of platform.
///
/// Flutter's built-in `findPlugins` ignores unknown platform keys like
/// `watchos`, so we read the `dependencyGraph` from
/// `.flutter-plugins-dependencies` (which Flutter does populate even for
/// unrecognized platforms) to get plugin names, resolve each one's path through
/// `.dart_tool/package_config.json`, and parse each pubspec ourselves.
///
/// Returns `[]` (not an error) if either input file is missing or malformed;
/// callers degrade silently the same way Flutter itself does.
List<_DependencyPluginYaml> _walkPluginDependencies(FlutterProject project) {
  final out = <_DependencyPluginYaml>[];

  final File depsFile = project.flutterPluginsDependenciesFile;
  if (!depsFile.existsSync()) {
    return out;
  }
  Map<String, dynamic> depsJson;
  try {
    final dynamic decoded = json.decode(depsFile.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      return out;
    }
    depsJson = decoded;
  } on FormatException {
    return out; // Malformed JSON — treat as no plugins.
  } on FileSystemException {
    return out; // File disappeared between existsSync() and read.
  }
  final dynamic rawGraph = depsJson['dependencyGraph'];
  final List<dynamic> depGraph = rawGraph is List<dynamic> ? rawGraph : <dynamic>[];

  // Build a name→path map from .dart_tool/package_config.json.
  final packagePaths = <String, String>{};
  final File packageConfigFile = project.directory
      .childDirectory('.dart_tool')
      .childFile('package_config.json');
  if (packageConfigFile.existsSync()) {
    try {
      final packageConfig =
          json.decode(packageConfigFile.readAsStringSync()) as Map<String, dynamic>;
      final List<dynamic> packages = (packageConfig['packages'] as List<dynamic>?) ?? <dynamic>[];
      for (final dynamic pkg in packages) {
        final pkgMap = pkg as Map<String, dynamic>;
        final name = pkgMap['name'] as String;
        var rootUri = pkgMap['rootUri'] as String;
        // rootUri may be relative to .dart_tool/ or a file:// URI.
        if (rootUri.startsWith('../')) {
          rootUri = globals.fs.path.normalize(
            globals.fs.path.join(project.directory.path, '.dart_tool', rootUri),
          );
        } else if (rootUri.startsWith('file://')) {
          rootUri = Uri.parse(rootUri).toFilePath();
        }
        packagePaths[name] = rootUri;
      }
    } on FormatException {
      // Malformed package_config.json — leave packagePaths empty.
    } on TypeError {
      // Unexpected JSON shape; fall through with empty packagePaths.
    }
  }

  for (final dynamic dep in depGraph) {
    final depMap = dep as Map<String, dynamic>;
    final pluginName = depMap['name'] as String;
    final String? pluginPath = packagePaths[pluginName];
    if (pluginPath == null) {
      continue;
    }
    final File pubspecFile = globals.fs.file(globals.fs.path.join(pluginPath, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      continue;
    }
    try {
      final pubspec = loadYaml(pubspecFile.readAsStringSync()) as YamlMap;
      final flutter = pubspec['flutter'] as YamlMap?;
      final plugin = flutter?['plugin'] as YamlMap?;
      if (plugin == null) {
        continue;
      }
      out.add(_DependencyPluginYaml(name: pluginName, path: pluginPath, pluginYaml: plugin));
    } on YamlException {
      continue; // Malformed pubspec.yaml — skip this plugin.
    } on TypeError {
      continue; // pubspec layout doesn't match the expected schema; skip.
    }
  }

  return out;
}

/// Discovers plugins in [project] that declare a
/// `flutter.plugin.platforms.watchos` block, parsing them into [WatchosPlugin]
/// instances.
List<WatchosPlugin> _discoverWatchosPlugins(FlutterProject project) {
  final watchosPlugins = <WatchosPlugin>[];
  for (final _DependencyPluginYaml dep in _walkPluginDependencies(project)) {
    final dynamic platforms = dep.pluginYaml['platforms'];
    if (platforms is! YamlMap) {
      continue;
    }
    final dynamic watchosConfig = platforms['watchos'];
    if (watchosConfig is! YamlMap) {
      continue;
    }
    watchosPlugins.add(
      WatchosPlugin(
        name: dep.name,
        path: dep.path,
        pluginClass: watchosConfig['pluginClass'] as String?,
        dartPluginClass: watchosConfig['dartPluginClass'] as String?,
        ffiPlugin: watchosConfig[kFfiPlugin] as bool?,
        ffiSymbols: _parseFfiSymbols(dep.name, watchosConfig[kWatchosFfiSymbols]),
      ),
    );
    globals.logger.printTrace('Discovered watchOS plugin: ${dep.name} at ${dep.path}');
  }
  return watchosPlugins;
}

/// Parses the `flutter.plugin.platforms.watchos.ffiSymbols` list declared by an
/// FFI plugin into a clean `List<String>` of C identifiers.
///
/// Tolerant of garbage: a non-list value, non-string entries, and names that
/// aren't valid C identifiers are dropped with a trace, never an exception.
List<String> _parseFfiSymbols(String pluginName, Object? raw) {
  if (raw == null) {
    return const <String>[];
  }
  if (raw is! YamlList) {
    globals.logger.printTrace(
      'Ignoring `$kWatchosFfiSymbols` for $pluginName: expected a list, '
      'got ${raw.runtimeType}.',
    );
    return const <String>[];
  }
  final symbols = <String>[];
  for (final Object? entry in raw) {
    if (entry is! String || !_cIdentifierPattern.hasMatch(entry)) {
      globals.logger.printTrace(
        'Ignoring invalid `$kWatchosFfiSymbols` entry "$entry" for $pluginName: '
        'not a valid C identifier.',
      );
      continue;
    }
    symbols.add(entry);
  }
  return symbols;
}

/// Discovers the watchOS plugins in [project] that ship a Swift Package
/// (`<plugin>/watchos/Package.swift`) and returns them as [WatchosSpmPlugin]s
/// for the generated SPM umbrella.
List<WatchosSpmPlugin> discoverWatchosSpmPlugins(FlutterProject project) {
  final spmPlugins = <WatchosSpmPlugin>[];
  for (final WatchosPlugin plugin in _discoverWatchosPlugins(project)) {
    final Directory watchosDir = globals.fs.directory(globals.fs.path.join(plugin.path, 'watchos'));
    final File manifest = watchosDir.childFile('Package.swift');
    if (!manifest.existsSync()) {
      continue;
    }
    final _SwiftPackageNames names = _readSwiftPackageNames(manifest);
    final String packageName = names.package ?? plugin.name;
    spmPlugins.add(
      WatchosSpmPlugin(name: packageName, packagePath: watchosDir.path, libraryName: names.library),
    );
    globals.logger.printTrace(
      'watchOS SPM plugin: $packageName (product '
      '${names.library ?? '${packageName.replaceAll('_', '-')} [derived]'}) at ${watchosDir.path}',
    );
  }
  return spmPlugins;
}

/// The `name:` (package) and `.library(name:)` (product) declared in a
/// `Package.swift`. Either may be null when it can't be parsed.
class _SwiftPackageNames {
  const _SwiftPackageNames({this.package, this.library});
  final String? package;
  final String? library;
}

final RegExp _packageNamePattern = RegExp(r'^[A-Za-z0-9_]+$');
final RegExp _libraryNamePattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// Extracts the SwiftPM package name (anchored to the `Package(` initializer)
/// and the first `.library(name:)` product from a `Package.swift`. Validates
/// both against the SwiftPM identifier charset; an unparseable or invalid value
/// is logged and returned as null so the caller falls back to a safe default.
_SwiftPackageNames _readSwiftPackageNames(File manifest) {
  String contents;
  try {
    contents = manifest.readAsStringSync();
  } on FileSystemException catch (e) {
    globals.logger.printTrace('Could not read ${manifest.path}: $e');
    return const _SwiftPackageNames();
  }

  String? validated(Match? match, RegExp charset, String what) {
    final String? value = match?.group(1);
    if (value == null) {
      return null;
    }
    if (!charset.hasMatch(value)) {
      globals.logger.printTrace(
        'Ignoring invalid SwiftPM $what "$value" in ${manifest.path}; '
        'falling back to a derived name.',
      );
      return null;
    }
    return value;
  }

  final String? package = validated(
    RegExp(r'Package\s*\(\s*name:\s*"([^"]+)"').firstMatch(contents),
    _packageNamePattern,
    'package name',
  );
  final String? library = validated(
    RegExp(r'\.library\s*\(\s*name:\s*"([^"]+)"').firstMatch(contents),
    _libraryNamePattern,
    'library name',
  );
  return _SwiftPackageNames(package: package, library: library);
}

/// Returns the names of every dependency that declares `flutter.plugin`,
/// regardless of whether it advertises a `watchos:` platform.
List<String> _findAllPluginNames(FlutterProject project) {
  return <String>[for (final dep in _walkPluginDependencies(project)) dep.name];
}

/// The package names the root project depends on directly (its own
/// `dependencies:` + `dev_dependencies:`). Returns null when the root pubspec
/// can't be read/parsed, so callers fall back to auditing every plugin rather
/// than silently scoping to nothing.
Set<String>? _directDependencyNames(FlutterProject project) {
  final File pubspec = project.directory.childFile('pubspec.yaml');
  if (!pubspec.existsSync()) {
    return null;
  }
  try {
    final dynamic doc = loadYaml(pubspec.readAsStringSync());
    if (doc is! YamlMap) {
      return null;
    }
    final names = <String>{};
    for (final section in const <String>['dependencies', 'dev_dependencies']) {
      final dynamic block = doc[section];
      if (block is YamlMap) {
        names.addAll(block.keys.whereType<String>());
      }
    }
    return names;
  } on YamlException {
    return null; // Malformed pubspec — don't scope (audit everything).
  }
}

/// Builds the developer-facing warning lines for any plugin in the project's
/// dep graph that has a FlutterWatch-published watchOS implementation the user
/// hasn't added yet. Public so tests can drive it without faking a project
/// tree.
List<String> recommendWatchosPluginsToInstall({required Iterable<String> allPluginNames}) {
  final Set<String> depGraph = allPluginNames.toSet();
  final messages = <String>[];
  for (final name in allPluginNames) {
    final List<String>? alternatives = _kKnownWatchosPlugins[name];
    if (alternatives == null) {
      continue;
    }
    final canonical = '${name}_watchos';
    final bool satisfied = depGraph.contains(canonical) || alternatives.any(depGraph.contains);
    if (satisfied) {
      continue;
    }
    if (alternatives.isEmpty) {
      messages.add(
        '$canonical is available on pub.dev under the flutterwatch.dev '
        'verified publisher. Did you forget to add it to pubspec.yaml?',
      );
    } else {
      final options = <String>[canonical, ...alternatives];
      final String last = options.removeLast();
      messages.add(
        '[${options.join(', ')} or $last] is available on pub.dev. '
        'Did you forget to add one to pubspec.yaml?',
      );
    }
  }
  return messages;
}

/// Federated platform-implementation packages (`foo_android`,
/// `foo_foundation`, …) and platform interfaces. These are internal halves of
/// some other plugin the user chose; auditing them individually would only
/// repeat the aggregator's line as noise.
final RegExp _federatedImplementationSuffix = RegExp(
  r'_(android|ios|linux|macos|windows|web|foundation|darwin|avfoundation|platform_interface)$',
);

/// Framework-provided plugin packages that already work on watchOS through the
/// flutter-watchos tooling rather than a `watchos:` platform key, so flagging
/// them as "unsupported" would be a false positive. `integration_test` runs on
/// the watch simulator via the CLI's own test harness.
const Set<String> _kWatchSupportedFrameworkPlugins = <String>{'integration_test'};

/// Builds the developer-facing warning lines for plugins in the dependency
/// graph that ship native code for other platforms but have no watchOS
/// implementation. Such plugins never break the build — their native code is
/// simply not bundled — but calling them on the watch fails at runtime
/// (`MissingPluginException`, or an FFI "symbol not found" `ArgumentError`).
///
/// [pluginPlatforms] maps each plugin package name to the platform keys it
/// declares under `flutter.plugin.platforms` (empty list = legacy pre-federated
/// plugin, which is implicitly ios/android). Public so tests can drive it
/// without faking a project tree.
///
/// [directDependencies], when non-null, scopes the warning to packages the
/// developer added themselves (the root pubspec's `dependencies` +
/// `dev_dependencies`). Deeply transitive plugins — e.g. a federated impl's
/// own Android helper packages (`jni`, `jni_flutter`) — are pulled in by a
/// package the user chose, not called directly, so warning about each of them
/// individually is noise. When null, every plugin is audited (no scoping).
List<String> auditPluginsWithoutWatchosSupport({
  required Map<String, List<String>> pluginPlatforms,
  Set<String>? directDependencies,
}) {
  final Set<String> allNames = pluginPlatforms.keys.toSet();
  final unsupported = <String>[];
  for (final MapEntry<String, List<String>> entry in pluginPlatforms.entries) {
    final String name = entry.key;
    final platforms = List<String>.of(entry.value)..sort();
    if (platforms.contains('watchos')) {
      continue;
    }
    if (_federatedImplementationSuffix.hasMatch(name)) {
      continue;
    }
    if (_kWatchSupportedFrameworkPlugins.contains(name)) {
      continue;
    }
    // Only warn about plugins the developer added directly and can act on.
    if (directDependencies != null && !directDependencies.contains(name)) {
      continue;
    }
    // A manually added (not yet endorsed) watchOS implementation counts.
    if (allNames.contains('${name}_watchos')) {
      continue;
    }
    final String label = platforms.isEmpty ? 'legacy ios/android' : platforms.join(', ');
    unsupported.add('  - $name ($label)');
  }
  if (unsupported.isEmpty) {
    return const <String>[];
  }
  unsupported.sort();
  const header =
      'The following plugin(s) have no watchOS implementation. The build will '
      'succeed, but calling them on the watch fails at runtime '
      '(MissingPluginException, or an FFI "symbol not found" error) unless '
      'the calls are guarded with FlutterWatchosPlatform.isWatch:';
  return <String>[
    header,
    ...unsupported,
    'See doc/plugins.md in the flutter-watchos repo for details.',
  ];
}

Future<void> ensureReadyForWatchosTooling(FlutterProject project) async {
  final Directory watchosDir = project.directory.childDirectory('watchos');
  if (!watchosDir.existsSync()) {
    return;
  }

  // Keep the host-mode wiring (standalone thin container vs companion iOS
  // app) consistent on every build/run. The mode is derived from the project
  // shape — an ios/ Flutter app means the watch app ships inside it as its
  // companion, no iOS app means watch-only — the same way stock Flutter
  // treats platform directories as the source of truth. Idempotent and
  // silent when the project is already consistent.
  await syncWatchosHostMode(projectDir: project.directory, logger: globals.logger);

  final List<WatchosPlugin> plugins = _discoverWatchosPlugins(project);

  final List<String> recommendations = recommendWatchosPluginsToInstall(
    allPluginNames: _findAllPluginNames(project),
  );
  recommendations.forEach(globals.logger.printWarning);

  // Surface plugins that will silently lack native code on the watch, so the
  // first hint isn't a runtime exception on the device.
  final pluginPlatforms = <String, List<String>>{};
  for (final _DependencyPluginYaml dep in _walkPluginDependencies(project)) {
    final dynamic platformsYaml = dep.pluginYaml['platforms'];
    pluginPlatforms[dep.name] = platformsYaml is YamlMap
        ? platformsYaml.keys.whereType<String>().toList()
        : <String>[];
  }
  final List<String> unsupported = auditPluginsWithoutWatchosSupport(
    pluginPlatforms: pluginPlatforms,
    directDependencies: _directDependencyNames(project),
  );
  if (unsupported.isNotEmpty) {
    globals.logger.printWarning(unsupported.join('\n'));
  }
  final methodChannelPlugins = <Map<String, Object?>>[];
  final ffiPlugins = <Map<String, Object?>>[];

  final watchosPluginEntries = <Map<String, dynamic>>[];

  // CRITICAL: preserve the existing `.flutter-plugins-dependencies` rather than
  // overwriting it. Stock `flutter pub get` writes ios/android/... plugin lists
  // AND the `dependencyGraph` array we need for later `_discoverWatchosPlugins`
  // calls. Wiping `dependencyGraph: []` here would make every federated watchOS
  // plugin with `dartPluginClass:` silently disappear from the registrant —
  // producing runtime `MissingPluginException` errors.
  var dependenciesJson = <String, dynamic>{
    'info': 'This is a generated file; do not edit or check into version control.',
    'plugins': <String, dynamic>{},
    'dependencyGraph': <dynamic>[],
  };
  final File depsFile = project.flutterPluginsDependenciesFile;
  if (depsFile.existsSync()) {
    try {
      final dynamic decoded = json.decode(depsFile.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        dependenciesJson = decoded;
      } else {
        globals.logger.printWarning(
          '.flutter-plugins-dependencies is not a JSON object; regenerating from scratch.',
        );
      }
    } on FormatException catch (e) {
      globals.logger.printWarning(
        '.flutter-plugins-dependencies contains malformed JSON ($e); regenerating from scratch.',
      );
    } on FileSystemException catch (e) {
      globals.logger.printWarning(
        '.flutter-plugins-dependencies disappeared before it could be read ($e); '
        'regenerating from scratch.',
      );
    }
  }
  final dynamic rawPlugins = dependenciesJson['plugins'];
  final Map<String, dynamic> pluginsMap = rawPlugins is Map<String, dynamic>
      ? rawPlugins
      : <String, dynamic>{};
  pluginsMap['watchos'] = watchosPluginEntries;
  dependenciesJson['plugins'] = pluginsMap;

  final pluginsBuffer = StringBuffer();

  for (final plugin in plugins) {
    if (plugin.hasMethodChannel()) {
      methodChannelPlugins.add(plugin.toMap());
    }
    if (plugin.hasFfi()) {
      ffiPlugins.add(plugin.toMap());
    }

    watchosPluginEntries.add(<String, dynamic>{
      'name': plugin.name,
      'path': plugin.path,
      'native_build': plugin.hasNativeBuild(),
      'dependencies': <String>[],
      'dev_dependency': false,
    });
    pluginsBuffer.writeln('${plugin.name}=${plugin.path}');
  }

  if (ffiPlugins.isNotEmpty) {
    globals.logger.printTrace(
      'Found ${ffiPlugins.length} FFI plugin(s): '
      '${ffiPlugins.map((p) => p['name']).join(', ')}',
    );
  }

  // Write .flutter-plugins-dependencies with the watchos key for the Podfile.
  project.flutterPluginsDependenciesFile.writeAsStringSync(json.encode(dependenciesJson));
  project.directory.childFile('.flutter-plugins').writeAsStringSync(pluginsBuffer.toString());

  final context = <String, Object>{'methodChannelPlugins': methodChannelPlugins};

  final File registryFile = watchosDir
      .childDirectory('Flutter')
      .childFile('GeneratedPluginRegistrant.swift');

  final String renderedTemplate = globals.templateRenderer.renderString(
    _swiftPluginRegistryTemplate,
    context,
  );
  registryFile.parent.createSync(recursive: true);
  registryFile.writeAsStringSync(renderedTemplate);

  globals.logger.printTrace('Generated $registryFile successfully for watchOS');

  // No ObjC GeneratedPluginRegistrant is written to Runner/. watchOS plugins
  // are FFI-only, and the build links their static archive with `-force_load`
  // (see `build_targets/application.dart`), which keeps every archive member —
  // so the exported symbols survive without a per-symbol forced-reference
  // registrant. The old Runner/GeneratedPluginRegistrant.{h,m} was never in the
  // Xcode Sources phase and had no caller; the slim host-module runner removed
  // any lingering illusion that it was compiled. Dart-side registration runs
  // through `dart_plugin_registrant.dart` below.

  // Write the watchOS dart plugin registrant now that the native side is fully
  // configured (a second call — the first ran before kernel compilation).
  writeWatchosDartPluginRegistrant(project, plugins: plugins);
}

/// Writes `.dart_tool/flutter_build/dart_plugin_registrant.dart` with watchOS-
/// aware plugin registrations.
///
/// **Must be called BEFORE `globals.buildSystem.build()`** so the Dart kernel
/// is compiled with the correct registrant. On watchOS (which identifies as an
/// iOS-family OS with `Platform.isIOS == true`) upstream plugin discovery would
/// register iOS plugins that have no native code in our watchOS build, causing
/// channel-error crashes. This watchOS-strict registrant only lists plugins
/// that declare `flutter.plugin.platforms.watchos`.
void writeWatchosDartPluginRegistrant(FlutterProject project, {List<WatchosPlugin>? plugins}) {
  final List<WatchosPlugin> dartPlugins = (plugins ?? _discoverWatchosPlugins(project))
      .where((p) => p.hasDart())
      .toList();

  final dartImports = StringBuffer();
  final dartRegistrations = StringBuffer();

  for (final plugin in dartPlugins) {
    final String alias = plugin.name.replaceAll('.', '_').replaceAll('-', '_');
    final libFile = '${plugin.name}.dart';
    dartImports.writeln("import 'package:${plugin.name}/$libFile' as $alias;");
    dartRegistrations.writeln(
      '    try {\n'
      '      $alias.${plugin.dartPluginClass}.registerWith();\n'
      '    } catch (err) {\n'
      "      print('`${plugin.name}` threw an error: \$err. '\n"
      "          'The app may not function as expected until you remove this plugin from pubspec.yaml');\n"
      '    }',
    );
  }

  final dartRegistrantContent =
      '//\n'
      '// Generated by flutter-watchos. Do not edit.\n'
      "// Flutter's own plugin-registrant generator only recognizes the\n"
      '// android/ios/linux/macos/web/windows platform keys, so on watchOS it\n'
      '// emits no registrations for plugins declared under `watchos:`. This\n'
      '// file is the watchOS-aware replacement. WatchosKernelSnapshot +\n'
      '// WatchosDartPluginRegistrantTarget (see build_targets/application.dart)\n'
      '// keep the stock DartPluginRegistrantTarget out of our build graph,\n'
      '// so this file is never overwritten by the upstream generator.\n'
      '//\n'
      '\n'
      '// @dart = 3.9\n'
      '\n'
      '$dartImports\n'
      "@pragma('vm:entry-point')\n"
      'class _PluginRegistrant {\n'
      "  @pragma('vm:entry-point')\n"
      '  static void register() {\n'
      '$dartRegistrations'
      '  }\n'
      '}\n';

  final Directory dartToolBuildDir = project.directory
      .childDirectory('.dart_tool')
      .childDirectory('flutter_build');
  dartToolBuildDir.createSync(recursive: true);
  final File dartRegistrantFile = dartToolBuildDir.childFile('dart_plugin_registrant.dart');
  dartRegistrantFile.writeAsStringSync(dartRegistrantContent);
  globals.logger.printTrace(
    'Wrote watchOS dart_plugin_registrant.dart (${dartPlugins.length} dart plugin(s))',
  );
}

class WatchosPlugin extends PluginPlatform implements NativeOrDartPlugin {
  WatchosPlugin({
    required this.name,
    this.path = '',
    this.pluginClass,
    this.dartPluginClass,
    this.defaultPackage,
    this.ffiPlugin,
    this.ffiSymbols = const <String>[],
  }) : assert(
         pluginClass != null ||
             dartPluginClass != null ||
             defaultPackage != null ||
             (ffiPlugin ?? false),
       );

  final String name;
  final String path;
  final String? pluginClass;
  final String? dartPluginClass;
  final String? defaultPackage;
  final bool? ffiPlugin;

  /// C symbols this FFI plugin exports for `dart:ffi` lookup, declared under
  /// `flutter.plugin.platforms.watchos.ffiSymbols`.
  final List<String> ffiSymbols;

  @override
  bool hasMethodChannel() => pluginClass != null;

  @override
  bool hasFfi() => ffiPlugin ?? false;

  @override
  bool hasDart() => dartPluginClass != null;

  /// Whether this plugin has native code that needs to be built.
  bool hasNativeBuild() => hasMethodChannel() || hasFfi();

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'name': name,
      if (pluginClass != null) 'class': pluginClass,
      if (dartPluginClass != null) 'dartPluginClass': dartPluginClass,
      if (defaultPackage != null) kDefaultPackage: defaultPackage,
      if (ffiPlugin ?? false) kFfiPlugin: true,
    };
  }
}

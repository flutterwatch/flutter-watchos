// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The FlutterWatchOS host module: the generic Swift glue around the engine
/// (frame display, touch + Digital Crown forwarding, the text-input and
/// platform-view overlays), compiled by the CLI instead of shipped as app
/// template source — the same split as stock Flutter, whose iOS Runner is a
/// dozen lines because the machinery lives in `Flutter.framework`.
///
/// The sources live in the CLI's own `host/` directory (`FlutterRunner.swift`,
/// `FlutterHostView.swift`, plus the C declarations `flutter_watchos_host.h`
/// behind the `FlutterWatchOSHostC` clang module). At build time they are
/// compiled with the USER'S toolchain — one `swiftc` invocation per
/// architecture — into `watchos/Flutter/`:
///
///   Flutter/libFlutterWatchOSHost.a          the (fat) static archive
///   Flutter/FlutterWatchOS.swiftmodule/…     one .swiftmodule per triple
///   Flutter/module.modulemap + …host.h       the C module, staged alongside
///
/// and the app's `App.swift` just does `import FlutterWatchOS` and shows
/// `FlutterHostView()`. Compiling locally (rather than shipping a binary
/// module) sidesteps Swift module compatibility entirely: `xcrun swiftc` and
/// `xcodebuild` resolve to the same toolchain. Because the archive ships with
/// the CLI, glue fixes reach EXISTING apps on their next build — template
/// source only ever reached newly `create`d ones.
///
/// Apps created before the host module existed compile their own
/// `Runner/FlutterRunner.swift` with a bridging header; the presence of that
/// file marks a legacy project and skips all of this (see
/// [isLegacyRunnerProject]) so the two glue copies never collide.
library;

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/version.dart';
import 'package:path/path.dart' as p;

import '../watchos_build_info.dart';

/// Whether the app's watchOS project predates the CLI-compiled host module:
/// its runner glue is template source (`Runner/FlutterRunner.swift`) compiled
/// into the app target, so the host module must NOT be built or linked —
/// the duplicate symbols would collide.
bool isLegacyRunnerProject(Directory watchosProjectDir) {
  return watchosProjectDir
      .childDirectory('Runner')
      .childFile('FlutterRunner.swift')
      .existsSync();
}

/// The `WATCHOS_DEPLOYMENT_TARGET` that Xcode builds the watch app's
/// `App.swift` with, for [configuration] (`Debug` or `Release`, see
/// `WatchosBuildInfo.configuration`).
///
/// The host module is compiled for it so its `.swiftmodule` never claims a
/// newer deployment target than the `App.swift` that imports it (Swift
/// rejects such imports), and the plugin sources the CLI compiles itself use
/// it too.
///
/// The value is looked up statically, in Xcode's order, for the
/// `PBXNativeTarget` named `Runner` (the target `-scheme Runner` builds); the
/// HostApp container is never read. The first level that sets it wins:
///
///  1. the file named by `XCODE_XCCONFIG_FILE` in [environment], relative to
///     [watchosProjectDir] unless absolute;
///  2. the target's [configuration] in `Runner.xcodeproj/project.pbxproj`;
///  3. the xcconfig that configuration's `baseConfigurationReference` names,
///     following `#include` and `#include?`;
///  4. the project-level configuration with the same name;
///  5. the xcconfig that the project-level configuration names;
///  6. otherwise [kWatchosSupportedMinimum].
///
/// `$(inherited)` passes on to the next level. A version number, quoted or
/// not, is a value. Any other value (a variable reference, a conditional
/// assignment such as `WATCHOS_DEPLOYMENT_TARGET[sdk=watchos*]`), a missing
/// or unparseable `project.pbxproj`, and a file the lookup needs but cannot
/// read end the lookup with [kWatchosSupportedMinimum]. That is the safe
/// answer: an object built for an older OS than `App.swift` still imports
/// and links, a newer one does not.
///
/// The CLI's own `Flutter/Debug.xcconfig`, `Flutter/Release.xcconfig` and
/// `Flutter/Generated.xcconfig` count as empty, present or not, apart from
/// the files they include: the CLI rewrites them on every build without the
/// setting. A missing `#include?` file also counts as empty.
///
/// Stock Flutter asks `xcodebuild -showBuildSettings` instead. That follows
/// Xcode exactly, but would add an `xcodebuild` run to every build.
String resolveWatchosDeploymentTarget({
  required Directory watchosProjectDir,
  required String configuration,
  Map<String, String> environment = const <String, String>{},
}) {
  final fallback = kWatchosSupportedMinimum.toString();
  try {
    return _DeploymentTargetLookup(watchosProjectDir, configuration, environment).resolve() ??
        fallback;
  } on _Unresolvable {
    return fallback;
  }
}

/// The architectures the host module is compiled for.
///
/// The Simulator is arm64-only. A device build adds arm64_32 while
/// [deploymentTarget] is below 27.0, because Xcode's Standard Architectures
/// build an arm64_32 slice of `App.swift` there, and its
/// `import FlutterWatchOS` must resolve for that slice too. From 27.0 Xcode
/// builds arm64 alone, so an arm64_32 module would never be used.
List<String> hostModuleArchs({required bool simulator, required String deploymentTarget}) {
  if (simulator) {
    return const <String>['arm64'];
  }
  final Version? target = Version.parse(deploymentTarget);
  if (target != null && target >= _firstArm64OnlyWatchos) {
    return const <String>['arm64'];
  }
  return const <String>['arm64', 'arm64_32'];
}

/// The first watchOS for which Xcode's Standard Architectures leave out
/// arm64_32.
const Version _firstArm64OnlyWatchos = Version.withText(27, 0, 0, '27.0');

const String _deploymentTargetSetting = 'WATCHOS_DEPLOYMENT_TARGET';

/// Thrown inside the lookup when the setting cannot be resolved statically.
class _Unresolvable implements Exception {
  const _Unresolvable();
}

/// One [resolveWatchosDeploymentTarget] lookup.
class _DeploymentTargetLookup {
  _DeploymentTargetLookup(this._projectDir, this._configuration, this._environment)
    : _fileSystem = _projectDir.fileSystem;

  final Directory _projectDir;
  final String _configuration;
  final Map<String, String> _environment;
  final FileSystem _fileSystem;

  late final Set<String> _cliOwnXcconfigs = <String>{
    for (final name in <String>['Debug.xcconfig', 'Release.xcconfig', 'Generated.xcconfig'])
      _normalize(_projectDir.childDirectory('Flutter').childFile(name).path),
  };

  /// The value, or null when no level sets it.
  String? resolve() {
    final String? overrideFile = _environment['XCODE_XCCONFIG_FILE'];
    if (overrideFile != null && overrideFile.isNotEmpty) {
      final String path = _fileSystem.path.isAbsolute(overrideFile)
          ? overrideFile
          : _fileSystem.path.join(_projectDir.path, overrideFile);
      final String? value = _fromXcconfig(path);
      if (value != null) {
        return value;
      }
    }

    final File pbxproj = _projectDir
        .childDirectory('Runner.xcodeproj')
        .childFile('project.pbxproj');
    if (!pbxproj.existsSync()) {
      throw const _Unresolvable();
    }
    final _Pbxproj? project = _Pbxproj.parse(pbxproj.readAsStringSync());
    if (project == null) {
      throw const _Unresolvable();
    }

    final Map<String, Object>? target = project.nativeTargetNamed('Runner');
    final Map<String, Object>? projectObject = project.rootProject;
    if (target == null || projectObject == null) {
      throw const _Unresolvable();
    }
    final Map<String, Object>? targetConfiguration = project.configurationNamed(
      target,
      _configuration,
    );
    if (targetConfiguration == null) {
      throw const _Unresolvable();
    }
    final Map<String, Object>? projectConfiguration = project.configurationNamed(
      projectObject,
      _configuration,
    );

    for (final configuration in <Map<String, Object>?>[targetConfiguration, projectConfiguration]) {
      if (configuration == null) {
        continue;
      }
      final String? fromSettings = _fromBuildSettings(configuration['buildSettings']);
      if (fromSettings != null) {
        return fromSettings;
      }
      final Object? reference = configuration['baseConfigurationReference'];
      if (reference is String) {
        final String? path = project.filePath(reference, _projectDir.path, _fileSystem.path);
        if (path == null) {
          throw const _Unresolvable();
        }
        final String? fromXcconfig = _fromXcconfig(path);
        if (fromXcconfig != null) {
          return fromXcconfig;
        }
      }
    }
    return null;
  }

  /// The value a configuration's `buildSettings` sets, or null.
  String? _fromBuildSettings(Object? settings) {
    if (settings == null) {
      return null;
    }
    if (settings is! Map<String, Object>) {
      throw const _Unresolvable();
    }
    if (settings.keys.any((String key) => key.startsWith('$_deploymentTargetSetting['))) {
      throw const _Unresolvable();
    }
    final Object? value = settings[_deploymentTargetSetting];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw const _Unresolvable();
    }
    return _classify(value);
  }

  /// The value an xcconfig and the files it includes set, or null.
  String? _fromXcconfig(String path) {
    final values = <String>[];
    _collectXcconfig(path, optional: false, values: values, visiting: <String>{});
    for (final String value in values.reversed) {
      final String? result = _classify(value);
      if (result != null) {
        return result;
      }
    }
    return null;
  }

  /// Appends the setting's assignments in [path], in order, includes
  /// expanded where they stand.
  void _collectXcconfig(
    String path, {
    required bool optional,
    required List<String> values,
    required Set<String> visiting,
  }) {
    final String normalized = _normalize(path);
    final bool cliOwn = _cliOwnXcconfigs.contains(normalized);
    final File file = _fileSystem.file(normalized);
    if (!file.existsSync()) {
      if (optional || cliOwn) {
        return;
      }
      throw const _Unresolvable();
    }
    if (!visiting.add(normalized)) {
      throw const _Unresolvable();
    }
    final List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } on FileSystemException {
      throw const _Unresolvable();
    }
    for (final rawLine in lines) {
      final String line = _stripXcconfigComment(rawLine).trim();
      final RegExpMatch? include = _xcconfigInclude.firstMatch(line);
      if (include != null) {
        final String included = include.group(2)!;
        if (included.startsWith('<')) {
          // `<DEVELOPER_DIR>/…`: outside the project, and not resolvable here.
          if (include.group(1) == null) {
            throw const _Unresolvable();
          }
          continue;
        }
        _collectXcconfig(
          _fileSystem.path.isAbsolute(included)
              ? included
              : _fileSystem.path.join(_fileSystem.path.dirname(normalized), included),
          optional: include.group(1) != null,
          values: values,
          visiting: visiting,
        );
        continue;
      }
      if (cliOwn) {
        continue;
      }
      final RegExpMatch? assignment = _xcconfigAssignment.firstMatch(line);
      if (assignment == null || assignment.group(1) != _deploymentTargetSetting) {
        continue;
      }
      if (assignment.group(2)!.isNotEmpty) {
        throw const _Unresolvable();
      }
      values.add(assignment.group(3)!);
    }
    visiting.remove(normalized);
  }

  /// A version number for a value, null for `$(inherited)`, and
  /// [_Unresolvable] for anything else.
  String? _classify(String value) {
    String text = value.trim();
    if (text.endsWith(';')) {
      text = text.substring(0, text.length - 1).trim();
    }
    if (text == r'$(inherited)' || text == r'${inherited}') {
      return null;
    }
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1).trim();
    }
    if (_versionNumber.hasMatch(text)) {
      return text;
    }
    throw const _Unresolvable();
  }

  String _normalize(String path) => _fileSystem.path.normalize(_fileSystem.path.absolute(path));
}

final RegExp _versionNumber = RegExp(r'^\d+(\.\d+){0,2}$');
final RegExp _xcconfigInclude = RegExp(r'^#include(\?)?\s*"([^"]*)"');
final RegExp _xcconfigAssignment = RegExp(
  r'^([A-Za-z_][A-Za-z0-9_]*)((?:\[[^\]]*\])*)\s*=\s*(.*)$',
);

/// [line] without its `//` comment. xcconfig has no quoting for `//`.
String _stripXcconfigComment(String line) {
  final int comment = line.indexOf('//');
  return comment < 0 ? line : line.substring(0, comment);
}

/// A parsed `project.pbxproj`.
class _Pbxproj {
  _Pbxproj._(this._root, this._objects);

  /// The project in [text], or null when [text] is not a project file.
  static _Pbxproj? parse(String text) {
    final Object? root = _OpenStepPlistParser(text).parse();
    if (root is! Map<String, Object>) {
      return null;
    }
    final Object? objects = root['objects'];
    return objects is Map<String, Object> ? _Pbxproj._(root, objects) : null;
  }

  final Map<String, Object> _root;
  final Map<String, Object> _objects;

  Map<String, Object>? _object(Object? id) {
    final Object? object = id is String ? _objects[id] : null;
    return object is Map<String, Object> ? object : null;
  }

  /// The `PBXProject` object, which holds the project-level configurations.
  Map<String, Object>? get rootProject {
    final Map<String, Object>? project = _object(_root['rootObject']);
    return project != null && project['isa'] == 'PBXProject' ? project : null;
  }

  /// The `PBXNativeTarget` called [name].
  Map<String, Object>? nativeTargetNamed(String name) {
    for (final Object object in _objects.values) {
      if (object is Map<String, Object> &&
          object['isa'] == 'PBXNativeTarget' &&
          object['name'] == name) {
        return object;
      }
    }
    return null;
  }

  /// The `XCBuildConfiguration` named [name] in [owner]'s configuration list.
  Map<String, Object>? configurationNamed(Map<String, Object> owner, String name) {
    final Object? configurations = _object(owner['buildConfigurationList'])?['buildConfigurations'];
    if (configurations is! List<Object>) {
      return null;
    }
    for (final Object id in configurations) {
      final Map<String, Object>? configuration = _object(id);
      if (configuration != null && configuration['name'] == name) {
        return configuration;
      }
    }
    return null;
  }

  /// The file system path of the file reference [id], or null when it is
  /// relative to something outside the project (a build or SDK directory).
  String? filePath(String id, String projectDir, p.Context context) {
    final parents = <String, String>{};
    for (final MapEntry<String, Object> entry in _objects.entries) {
      final Object? children = entry.value is Map<String, Object>
          ? (entry.value as Map<String, Object>)['children']
          : null;
      if (children is List<Object>) {
        for (final Object child in children) {
          if (child is String) {
            parents[child] = entry.key;
          }
        }
      }
    }
    String? pathOf(String id, int depth) {
      final Map<String, Object>? item = _object(id);
      if (item == null || depth > 64) {
        return null;
      }
      final Object? path = item['path'];
      final String? base = switch (item['sourceTree'] ?? '<group>') {
        '<absolute>' => '',
        'SOURCE_ROOT' => projectDir,
        '<group>' => parents[id] == null ? projectDir : pathOf(parents[id]!, depth + 1),
        _ => null,
      };
      if (base == null) {
        return null;
      }
      if (path is! String) {
        return base;
      }
      return base.isEmpty ? path : context.join(base, path);
    }

    return pathOf(id, 0);
  }
}

/// A parser for old-style (OpenStep) property lists, the format of
/// `project.pbxproj`: dictionaries, arrays and strings, with `//` and `/* */`
/// comments. [parse] returns null for malformed input.
class _OpenStepPlistParser {
  _OpenStepPlistParser(this._text);

  final String _text;
  int _position = 0;

  Object? parse() {
    try {
      final Object value = _value();
      _skipWhitespaceAndComments();
      return _position == _text.length ? value : null;
    } on FormatException {
      return null;
    }
  }

  void _skipWhitespaceAndComments() {
    while (_position < _text.length) {
      if (_text.startsWith('//', _position)) {
        final int end = _text.indexOf('\n', _position);
        _position = end < 0 ? _text.length : end + 1;
      } else if (_text.startsWith('/*', _position)) {
        final int end = _text.indexOf('*/', _position + 2);
        if (end < 0) {
          throw const FormatException('Unterminated comment');
        }
        _position = end + 2;
      } else if (' \t\r\n'.contains(_text[_position])) {
        _position++;
      } else {
        return;
      }
    }
  }

  Object _value() {
    _skipWhitespaceAndComments();
    if (_position >= _text.length) {
      throw const FormatException('Unexpected end');
    }
    return switch (_text[_position]) {
      '{' => _dictionary(),
      '(' => _array(),
      '"' => _quotedString(),
      _ => _unquotedString(),
    };
  }

  void _expect(String character) {
    _skipWhitespaceAndComments();
    if (_position >= _text.length || _text[_position] != character) {
      throw FormatException('Expected $character', _text, _position);
    }
    _position++;
  }

  Map<String, Object> _dictionary() {
    _position++;
    final result = <String, Object>{};
    while (true) {
      _skipWhitespaceAndComments();
      if (_position < _text.length && _text[_position] == '}') {
        _position++;
        return result;
      }
      final Object key = _value();
      if (key is! String) {
        throw FormatException('Dictionary key is not a string', _text, _position);
      }
      _expect('=');
      result[key] = _value();
      _expect(';');
    }
  }

  List<Object> _array() {
    _position++;
    final result = <Object>[];
    while (true) {
      _skipWhitespaceAndComments();
      if (_position < _text.length && _text[_position] == ')') {
        _position++;
        return result;
      }
      result.add(_value());
      _skipWhitespaceAndComments();
      if (_position < _text.length && _text[_position] == ',') {
        _position++;
      } else if (_position >= _text.length || _text[_position] != ')') {
        throw FormatException('Expected , or )', _text, _position);
      }
    }
  }

  String _quotedString() {
    _position++;
    final buffer = StringBuffer();
    while (_position < _text.length) {
      final String character = _text[_position++];
      if (character == '"') {
        return buffer.toString();
      }
      if (character == r'\' && _position < _text.length) {
        final String escaped = _text[_position++];
        buffer.write(switch (escaped) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          _ => escaped,
        });
      } else {
        buffer.write(character);
      }
    }
    throw const FormatException('Unterminated string');
  }

  String _unquotedString() {
    final int start = _position;
    while (_position < _text.length && !_delimiters.contains(_text[_position])) {
      _position++;
    }
    if (_position == start) {
      throw FormatException('Unexpected character', _text, _position);
    }
    return _text.substring(start, _position);
  }

  static const String _delimiters = ' \t\r\n{}()=;,"';
}

/// The host module's Swift sources: every `.swift` in the CLI's `host/`
/// directory, sorted for a deterministic compile.
List<String> collectHostModuleSources(Directory hostDir) {
  final List<String> sources = hostDir
      .listSync()
      .whereType<File>()
      .map((File f) => f.path)
      .where((String p) => p.endsWith('.swift'))
      .toList();
  sources.sort();
  return sources;
}

/// Compilation condition that admits the Dart VM Service bridge.
///
/// Defined for debug and profile, never for release: a shipping app must not
/// carry the bridge's networking code at all, dormant or not. See
/// `host/FlutterWatchOSVmBridge.swift`, which compiles to an empty stub
/// without it.
const String kVmBridgeSwiftDefine = 'FLUTTER_WATCHOS_VM_BRIDGE';

/// Compilation condition that admits the status-bar SPI (`_statusBarHidden`).
///
/// Defined only when the app depends on package:flutter_watchos, the one way
/// Dart can ask for the system clock to be hidden (`WatchStatusBar.hidden`).
/// Without the define the host module never references the SwiftUI SPI, so an
/// app that cannot opt in does not carry the symbol a private-API scan would
/// find. See `host/FlutterHostView.swift`.
const String kStatusBarSpiSwiftDefine = 'FLUTTER_WATCHOS_STATUS_BAR_SPI';

/// The `swiftc` command line that compiles the host module for one
/// architecture: emits the `.swiftmodule` (what `import FlutterWatchOS`
/// resolves) and the object file that becomes the linked archive.
///
/// [optimize] selects `-O` (profile and release) or `-Onone` (debug). swiftc
/// defaults to `-Onone` when neither is given, and the host module's frame
/// path, gesture handling and overlay mirrors used to ship unoptimised in
/// release apps because of it — while the app's own dozen-line `App.swift`
/// got `-O` from Xcode. `-g` is always on: the debug info lands in the app's
/// dSYM, not in the shipped binary, and a crash log without it names no host
/// frame.
List<String> hostModuleSwiftcArgs({
  required String sdkName,
  required bool simulator,
  required String arch,
  required String deploymentTarget,
  required String moduleOutputPath,
  required String objectOutputPath,
  required String cModuleSearchPath,
  required List<String> sources,
  required bool enableVmBridge,
  required bool optimize,
  required bool enableStatusBarSpi,
}) {
  return <String>[
    'xcrun',
    '-sdk',
    sdkName,
    'swiftc',
    '-target',
    watchosTargetTriple(arch: arch, osVersion: deploymentTarget, simulator: simulator),
    '-parse-as-library',
    if (optimize) '-O' else '-Onone',
    '-g',
    '-whole-module-optimization',
    '-module-name',
    'FlutterWatchOS',
    '-emit-module-path',
    moduleOutputPath,
    '-emit-object',
    '-o',
    objectOutputPath,
    // Resolves the FlutterWatchOSHostC clang module (module.modulemap +
    // flutter_watchos_host.h, staged into Flutter/ before this runs).
    '-I',
    cModuleSearchPath,
    if (enableVmBridge) ...<String>['-D', kVmBridgeSwiftDefine],
    if (enableStatusBarSpi) ...<String>['-D', kStatusBarSpiSwiftDefine],
    ...sources,
  ];
}

/// The `.swiftmodule` file name Swift expects for a triple: arch + platform,
/// no OS version (e.g. `arm64-apple-watchos-simulator.swiftmodule`).
String swiftmoduleFileName({required String arch, required bool simulator}) {
  return simulator
      ? '$arch-apple-watchos-simulator.swiftmodule'
      : '$arch-apple-watchos.swiftmodule';
}

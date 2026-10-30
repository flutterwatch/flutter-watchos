// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Per-app preprocessor defines for the plugin sources the CLI compiles.
///
/// A plugin maps each of its macros to the app Info.plist key that turns it
/// on, under `flutter.plugin.platforms.watchos.defines` in its pubspec:
///
/// ```yaml
/// defines:
///   PERMISSION_CONTACTS: NSContactsUsageDescription
///   PERMISSION_LOCATION:
///     - NSLocationWhenInUseUsageDescription
///     - NSLocationAlwaysAndWhenInUseUsageDescription
/// ```
///
/// The build reads the watch app's Info.plist and compiles that plugin's
/// sources with each macro whose key the app sets, so the code for a feature
/// the app does not use stays out of its binary. It is the watchOS form of
/// the `PERMISSION_*` macros an iOS app sets in its Podfile for
/// permission_handler.
library;

import 'package:flutter_tools/src/base/common.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Pubspec key, nested under `flutter.plugin.platforms.watchos`, that maps a
/// plugin's preprocessor macros to the app Info.plist keys that turn them on.
const String kWatchosDefines = 'defines';

/// The define that the sources of a plugin whose `defines` the CLI applies
/// get, ahead of the plugin's own macros: `-DFLUTTER_WATCHOS_PLUGIN_DEFINES=1`
/// for clang, and a compilation condition of the same name for swiftc.
///
/// It says that the CLI applied this plugin's `defines`. A CLI that predates
/// them passes no macro at all, and neither does this one for a plugin that
/// declares none, so a plugin keeps all of its code there by guarding with
/// `#if !defined(FLUTTER_WATCHOS_PLUGIN_DEFINES) || MY_MACRO` (in Swift,
/// `#if !FLUTTER_WATCHOS_PLUGIN_DEFINES || MY_MACRO`). A `defines` that is
/// misspelled or misplaced in the pubspec then keeps that code too, instead
/// of compiling all of it out.
const String kWatchosPluginDefinesMarker = 'FLUTTER_WATCHOS_PLUGIN_DEFINES';

/// A C identifier, which a macro name must be.
final RegExp _cIdentifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// One entry of a plugin's `defines`: a macro, and the app Info.plist keys
/// any one of which turns it on.
@immutable
class WatchosPluginDefine {
  /// Creates the entry for [macro], turned on by any of [infoPlistKeys].
  const WatchosPluginDefine(this.macro, this.infoPlistKeys);

  /// The macro name, a C identifier.
  final String macro;

  /// The app Info.plist keys that turn [macro] on. Never empty.
  final List<String> infoPlistKeys;

  @override
  bool operator ==(Object other) {
    if (other is! WatchosPluginDefine ||
        other.macro != macro ||
        other.infoPlistKeys.length != infoPlistKeys.length) {
      return false;
    }
    for (var i = 0; i < infoPlistKeys.length; i++) {
      if (other.infoPlistKeys[i] != infoPlistKeys[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(macro, Object.hashAll(infoPlistKeys));

  @override
  String toString() => '$macro: ${infoPlistKeys.join(', ')}';
}

/// Parses the `defines` that the plugin [pluginName] declares in the
/// `pubspec.yaml` at [pubspecPath]. [yaml] is the value under
/// `flutter.plugin.platforms.watchos.defines`; null means none.
///
/// The entries keep their order in the pubspec. Unlike `ffiSymbols`, the
/// parse is strict, because an entry dropped here would silently move code in
/// or out of every app that uses the plugin. Throws a [ToolExit] that names
/// the plugin, [pubspecPath] and every invalid entry when [yaml] is not a
/// map, when a macro name is not a C identifier, or when a value is not an
/// Info.plist key (a non-empty string) or a non-empty list of keys. Its last
/// line is for the developer of an app that uses the plugin, who cannot fix
/// its pubspec: after a change to the dependency, `flutter-watchos pub get`
/// resolves the plugin again.
List<WatchosPluginDefine> parseWatchosPluginDefines({
  required String pluginName,
  required String pubspecPath,
  required Object? yaml,
}) {
  if (yaml == null) {
    return const <WatchosPluginDefine>[];
  }
  final problems = <String>[];
  final defines = <WatchosPluginDefine>[];
  if (yaml is! Map<Object?, Object?>) {
    problems.add('`$kWatchosDefines` is ${_describe(yaml)}, not a map.');
  } else {
    for (final MapEntry<Object?, Object?> entry in yaml.entries) {
      final Object? macro = entry.key;
      if (macro is! String || !_cIdentifier.hasMatch(macro)) {
        problems.add('`$macro` is not a C identifier.');
        continue;
      }
      final List<String>? keys = _infoPlistKeys(macro, entry.value, problems);
      if (keys != null) {
        defines.add(WatchosPluginDefine(macro, keys));
      }
    }
  }
  if (problems.isNotEmpty) {
    throwToolExit(
      'The watchOS plugin $pluginName has an invalid `$kWatchosDefines` in $pubspecPath:\n'
      '${problems.map((String problem) => '  - $problem').join('\n')}\n'
      'Each entry maps a macro name, a C identifier, to an app Info.plist key '
      'or to a list of keys.\n'
      "If the app's dependency on $pluginName changed, run `flutter-watchos pub get` "
      'to resolve it again.',
    );
  }
  return defines;
}

/// The Info.plist keys that [value] names for [macro], or null after adding
/// what is wrong with it to [problems].
List<String>? _infoPlistKeys(String macro, Object? value, List<String> problems) {
  if (value == null) {
    problems.add('`$macro` names no Info.plist key.');
    return null;
  }
  if (value is String) {
    if (value.isEmpty) {
      problems.add('`$macro` names an empty Info.plist key.');
      return null;
    }
    return <String>[value];
  }
  if (value is! List<Object?>) {
    problems.add('`$macro` maps to ${_describe(value)}, not an Info.plist key or a list of keys.');
    return null;
  }
  if (value.isEmpty) {
    problems.add('`$macro` lists no Info.plist key.');
    return null;
  }
  final keys = <String>[];
  var valid = true;
  for (final Object? key in value) {
    if (key is String && key.isNotEmpty) {
      keys.add(key);
    } else {
      problems.add('`$macro` lists ${_describe(key)}, which is not an Info.plist key.');
      valid = false;
    }
  }
  return valid ? List<String>.unmodifiable(keys) : null;
}

/// [value] as an error message shows it.
String _describe(Object? value) {
  return switch (value) {
    null => 'an empty entry',
    String() when value.isEmpty => 'an empty string',
    String() => '"$value"',
    Map<Object?, Object?>() => 'a map',
    List<Object?>() => 'a list',
    _ => '$value',
  };
}

/// The macros of [defines] that the app's Info.plist turns on, in the order
/// the plugin declares them, each mapped to the first of its keys that did.
///
/// [infoPlist] is the Info.plist as `PlistParser.parseFile` reads it. A key
/// turns its macro on when its value is a non-empty string or `true`. Values
/// are read as written: Xcode expands build settings only later, so
/// `$(TEXT)` counts as a non-empty string, and so does `NO`. A missing key,
/// `false`, an empty string and any other value (a number, a date, data, an
/// array or a dictionary) leave it off.
Map<String, String> enabledWatchosPluginDefines(
  List<WatchosPluginDefine> defines,
  Map<String, Object> infoPlist,
) {
  final enabled = <String, String>{};
  for (final define in defines) {
    for (final String key in define.infoPlistKeys) {
      final Object? value = infoPlist[key];
      if ((value is String && value.isNotEmpty) || value == true) {
        enabled[define.macro] = key;
        break;
      }
    }
  }
  return enabled;
}

/// An `INFOPLIST_FILE` build setting in the text of a `project.pbxproj`, with
/// or without a condition (`"INFOPLIST_FILE[sdk=watchos*]"`), and its value,
/// quoted or not. The word boundary leaves out `GENERATE_INFOPLIST_FILE`.
final RegExp _infoPlistFileSetting = RegExp(
  r'\bINFOPLIST_FILE(?:\[[^\]\n]*\])*"?\s*=\s*("(?:[^"\\\n]|\\.)*"|[^\s;"]+)\s*;',
);

/// A backslash escape in a quoted `project.pbxproj` string.
final RegExp _pbxprojEscape = RegExp(r'\\(.)');

/// The project's own directory in a build setting, `$(SRCROOT)` or
/// `$(PROJECT_DIR)`, in either bracket style.
final RegExp _projectDirectorySetting = RegExp(r'\$[({](?:SRCROOT|PROJECT_DIR)[)}]');

/// The `INFOPLIST_FILE` values that [pbxproj], the text of the watch app's
/// `Runner.xcodeproj/project.pbxproj`, sets, when none of them names
/// [infoPlistPath], the Info.plist that plugin `defines` are read from. Each
/// value is given once, as written, in the order it first appears.
///
/// Null when one of them names [infoPlistPath], when [pbxproj] sets none, and
/// when a value holds a build setting other than `$(SRCROOT)` or
/// `$(PROJECT_DIR)`, such as `$(TARGET_NAME)/Info.plist`, which may well name
/// it. A relative value is read from [projectDirectory], the `watchos/`
/// directory, as Xcode reads it. This is a cheap reading of the text, not
/// Xcode's resolution of the setting per target and configuration: a value
/// that only the iOS container's target sets counts as well.
List<String>? otherInfoPlistFiles({
  required String pbxproj,
  required String projectDirectory,
  required String infoPlistPath,
  required p.Context pathContext,
}) {
  final values = <String>{};
  for (final RegExpMatch match in _infoPlistFileSetting.allMatches(pbxproj)) {
    String value = match[1]!;
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value
          .substring(1, value.length - 1)
          .replaceAllMapped(_pbxprojEscape, (Match escape) => escape[1]!);
    }
    if (value.isNotEmpty) {
      values.add(value);
    }
  }
  if (values.isEmpty) {
    return null;
  }
  final String infoPlist = pathContext.normalize(infoPlistPath);
  for (final value in values) {
    final String path = value.replaceAll(_projectDirectorySetting, projectDirectory);
    if (path.contains(r'$') ||
        pathContext.normalize(pathContext.join(projectDirectory, path)) == infoPlist) {
      return null;
    }
  }
  return values.toList();
}

// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The version fields of each product agree.
//
// A release bumps several files by hand: the CLI's pubspec, CHANGELOG and
// README, the two pins the README quotes, and the package's pubspec and
// CHANGELOG. Each pair is checked here, so a bump that misses one fails
// before the tag. The CLI and the package are versioned on their own, so
// their versions are never compared with each other.

import 'dart:io' as io;

import 'package:yaml/yaml.dart';

import '../src/common.dart';
import '../src/host_sources.dart';

String _read(String relativePath) => io.File(cliRootPath(relativePath)).readAsStringSync();

/// The `version:` of a pubspec, or null.
String? _pubspecVersion(String pubspec) {
  final Object? yaml = loadYaml(pubspec);
  if (yaml is YamlMap && yaml['version'] != null) {
    return '${yaml['version']}';
  }
  return null;
}

/// The version that the first `## ` heading of a CHANGELOG names, or null.
///
/// A first heading `## Unreleased` is skipped, and the version is the next
/// heading's: CONTRIBUTING.md asks for that section, which collects changes
/// until a release turns it into the new version's heading.
String? _firstChangelogVersion(String changelog) {
  var first = true;
  for (final String line in changelog.split('\n')) {
    if (line.startsWith('## ')) {
      final String name = line.substring(3).trim().split(RegExp(r'\s+')).first;
      if (first && name.toLowerCase() == 'unreleased') {
        first = false;
        continue;
      }
      return name;
    }
  }
  return null;
}

String? _readmeField(String readme, RegExp pattern) => pattern.firstMatch(readme)?.group(1);

final RegExp _readmeCliVersion = RegExp(r'^- flutter-watchos: `([^`]+)`', multiLine: true);
final RegExp _readmeFlutterSha = RegExp(
  r'^- Flutter SDK: `[^`]+` \(`([0-9a-f]{40})`\)',
  multiLine: true,
);
final RegExp _readmeEngineId = RegExp(
  r'^- watchOS engine artifacts: `(engine-[0-9a-f]+)`',
  multiLine: true,
);

/// Null when the CLI's pubspec version, the first CHANGELOG heading and the
/// README's "flutter-watchos:" line agree; otherwise what disagrees.
String? _cliVersionMismatch({
  required String pubspec,
  required String changelog,
  required String readme,
}) {
  final String? fromPubspec = _pubspecVersion(pubspec);
  final String? fromChangelog = _firstChangelogVersion(changelog);
  final String? fromReadme = _readmeField(readme, _readmeCliVersion);
  if (fromPubspec == null || fromPubspec != fromChangelog || fromPubspec != fromReadme) {
    return 'pubspec.yaml version $fromPubspec, CHANGELOG.md first heading $fromChangelog, '
        'README.md flutter-watchos: $fromReadme';
  }
  return null;
}

/// Null when the README's Flutter SHA is the pinned one in
/// `bin/internal/flutter.version`; otherwise both values.
String? _flutterPinMismatch({required String readme, required String flutterVersion}) {
  final String? fromReadme = _readmeField(readme, _readmeFlutterSha);
  final String pinned = flutterVersion.trim();
  if (fromReadme == null || fromReadme != pinned) {
    return 'README.md Flutter SHA $fromReadme, bin/internal/flutter.version $pinned';
  }
  return null;
}

/// Null when the README's engine id is the pinned one in
/// `bin/internal/engine.version`; otherwise both values.
String? _enginePinMismatch({required String readme, required String engineVersion}) {
  final String? fromReadme = _readmeField(readme, _readmeEngineId);
  final String pinned = engineVersion.trim();
  if (fromReadme == null || fromReadme != pinned) {
    return 'README.md engine id $fromReadme, bin/internal/engine.version $pinned';
  }
  return null;
}

/// Null when the package's pubspec version is its CHANGELOG's first heading;
/// otherwise both values.
String? _packageVersionMismatch({required String pubspec, required String changelog}) {
  final String? fromPubspec = _pubspecVersion(pubspec);
  final String? fromChangelog = _firstChangelogVersion(changelog);
  if (fromPubspec == null || fromPubspec != fromChangelog) {
    return 'package pubspec.yaml version $fromPubspec, package CHANGELOG.md first heading '
        '$fromChangelog';
  }
  return null;
}

void main() {
  group('this repository', () {
    testWithoutContext('the CLI version agrees in pubspec, CHANGELOG and README', () {
      expect(
        _cliVersionMismatch(
          pubspec: _read('pubspec.yaml'),
          changelog: _read('CHANGELOG.md'),
          readme: _read('README.md'),
        ),
        isNull,
      );
    });

    testWithoutContext('the README names the pinned Flutter SHA', () {
      expect(
        _flutterPinMismatch(
          readme: _read('README.md'),
          flutterVersion: _read('bin/internal/flutter.version'),
        ),
        isNull,
      );
    });

    testWithoutContext('the README names the pinned engine id', () {
      expect(
        _enginePinMismatch(
          readme: _read('README.md'),
          engineVersion: _read('bin/internal/engine.version'),
        ),
        isNull,
      );
    });

    testWithoutContext('the package version agrees in its pubspec and CHANGELOG', () {
      expect(
        _packageVersionMismatch(
          pubspec: _read('packages/flutter_watchos/pubspec.yaml'),
          changelog: _read('packages/flutter_watchos/CHANGELOG.md'),
        ),
        isNull,
      );
    });
  });

  group('fixtures', () {
    const pubspec = 'name: flutter_watchos\nversion: 0.2.0\n';
    const changelog = '# Changelog\n\n## 0.2.0\n\n- A change.\n\n## 0.1.0\n\n- The first.\n';
    const flutterSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const readme =
        '# flutter-watchos\n\n## Current version\n\n'
        '- flutter-watchos: `0.2.0`\n'
        '- Flutter SDK: `3.48.0` (`$flutterSha`)\n'
        '- watchOS engine artifacts: `engine-0123456789ab`\n';

    testWithoutContext('fields that agree give no mismatch', () {
      expect(_cliVersionMismatch(pubspec: pubspec, changelog: changelog, readme: readme), isNull);
      expect(_flutterPinMismatch(readme: readme, flutterVersion: '$flutterSha\n'), isNull);
      expect(_enginePinMismatch(readme: readme, engineVersion: 'engine-0123456789ab\n'), isNull);
      expect(_packageVersionMismatch(pubspec: pubspec, changelog: changelog), isNull);
    });

    testWithoutContext('a leading Unreleased section is skipped, and only that one', () {
      const unreleased = '# Changelog\n\n## Unreleased\n\n- A change to come.\n\n$changelog';
      expect(_firstChangelogVersion(unreleased), '0.2.0');
      expect(_cliVersionMismatch(pubspec: pubspec, changelog: unreleased, readme: readme), isNull);
      expect(_packageVersionMismatch(pubspec: pubspec, changelog: unreleased), isNull);
      expect(_firstChangelogVersion('## Unreleased\n\n- A change to come.\n'), isNull);
      expect(_firstChangelogVersion('## 0.2.1\n\n## Unreleased\n\n## 0.2.0\n'), '0.2.1');
      expect(_firstChangelogVersion('## Unreleased\n\n## Unreleased\n\n## 0.2.0\n'), 'Unreleased');
    });

    testWithoutContext('a CLI bump that misses one file is a mismatch', () {
      expect(
        _cliVersionMismatch(
          pubspec: pubspec.replaceFirst('0.2.0', '0.2.1'),
          changelog: changelog,
          readme: readme,
        ),
        'pubspec.yaml version 0.2.1, CHANGELOG.md first heading 0.2.0, '
        'README.md flutter-watchos: 0.2.0',
      );
      expect(
        _cliVersionMismatch(pubspec: pubspec, changelog: '## 0.2.1\n$changelog', readme: readme),
        isNotNull,
      );
      expect(
        _cliVersionMismatch(
          pubspec: pubspec,
          changelog: changelog,
          readme: readme.replaceFirst('`0.2.0`', '`0.2.1`'),
        ),
        isNotNull,
      );
      expect(
        _cliVersionMismatch(
          pubspec: pubspec,
          changelog: changelog,
          readme: readme.replaceFirst('- flutter-watchos:', '- CLI:'),
        ),
        isNotNull,
      );
    });

    testWithoutContext('a repin that misses the README is a mismatch', () {
      expect(
        _flutterPinMismatch(readme: readme, flutterVersion: 'b' * 40),
        'README.md Flutter SHA $flutterSha, bin/internal/flutter.version ${'b' * 40}',
      );
      expect(
        _enginePinMismatch(readme: readme, engineVersion: 'engine-ba9876543210'),
        'README.md engine id engine-0123456789ab, bin/internal/engine.version engine-ba9876543210',
      );
    });

    testWithoutContext('a package bump without its CHANGELOG heading is a mismatch', () {
      expect(
        _packageVersionMismatch(
          pubspec: pubspec.replaceFirst('0.2.0', '0.2.1'),
          changelog: changelog,
        ),
        'package pubspec.yaml version 0.2.1, package CHANGELOG.md first heading 0.2.0',
      );
      expect(_packageVersionMismatch(pubspec: pubspec, changelog: '# Changelog\n'), isNotNull);
    });

    testWithoutContext('the CLI and the package may have different versions', () {
      const packagePubspec = 'name: flutter_watchos\nversion: 0.1.3\n';
      const packageChangelog = '## 0.1.3\n\n- A package change.\n';
      expect(_cliVersionMismatch(pubspec: pubspec, changelog: changelog, readme: readme), isNull);
      expect(_packageVersionMismatch(pubspec: packagePubspec, changelog: packageChangelog), isNull);
    });
  });
}

// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';

import 'objc_porter.dart';
import 'report_emitter.dart';
import 'source_analyzer.dart';
import 'swift_porter.dart';
import 'templates.dart' as tmpl;

/// Writes the on-disk **FFI** scaffolding for a `*_watchos` plugin package
/// given an already-analysed source plugin.
///
/// Method-channel plugins are not supported on watchOS — a method-channel
/// plugin cannot run there. The porter therefore emits an FFI scaffold —
/// a C stub (`watchos/Classes/<pkg>_ffi.{h,m}`), an FFI `Package.swift`, an
/// `ffiPlugin: true` pubspec, and a Dart class over the platform interface
/// that resolves the native symbols via `DynamicLibrary.process()`.
///
/// The source plugin's own native sources are **not** copied (they are
/// method-channel code that can't run on the watch); instead they are
/// analysed against the compatibility database so `PORTING_REPORT.md` can
/// tell the developer which iOS APIs the plugin used and their watchOS
/// equivalents.
class Scaffolder {
  Scaffolder({
    required FileSystem fileSystem,
    required Logger logger,
    required this.licenseHolder,
  }) : _fs = fileSystem,
       _log = logger;

  final FileSystem _fs;
  final Logger _log;
  final String licenseHolder;

  /// Generates [source]'s watchOS FFI scaffold into [outputDirectory].
  ///
  /// When [dryRun] is true no files are written; the call still produces a
  /// [ScaffoldResult] reporting which paths *would* have been written and
  /// the findings collected from the source (so `--dry-run` can preview the
  /// report). When [overwrite] is false and [outputDirectory] already
  /// exists, throws. When [emitReport] is false, `PORTING_REPORT.md` is not
  /// written (`--no-report`).
  ScaffoldResult scaffold({
    required PluginSource source,
    required Directory outputDirectory,
    bool overwrite = false,
    bool dryRun = false,
    bool emitReport = true,
  }) {
    if (outputDirectory.existsSync() && !dryRun) {
      if (!overwrite) {
        throw ScaffoldError(
          'Output directory already exists: ${outputDirectory.path}\n'
          'Pass `--force` to overwrite, or `--output <other-dir>` to write elsewhere.',
        );
      }
      outputDirectory.deleteSync(recursive: true);
    }

    // Analyse the source's native code (if any) against the compatibility
    // database. We keep only the findings — the transformed output is
    // discarded, since the ported package is a fresh FFI scaffold, not a
    // copy of the source's method-channel implementation.
    final List<PortingFinding> findings = _collectFindings(source);

    // The whole FFI package as relative-path → contents.
    final Map<String, String> files = _ffiFiles(source);

    final File? reportFile =
        emitReport ? outputDirectory.childFile('PORTING_REPORT.md') : null;
    final String? reportContents = reportFile == null
        ? null
        : const ReportEmitter().render(source: source, findings: findings);

    final written = <String>[];
    if (!dryRun) {
      files.forEach((String rel, String contents) {
        final File f = _fs.file(_fs.path.join(outputDirectory.path, rel))
          ..parent.createSync(recursive: true);
        f.writeAsStringSync(contents);
        _log.printTrace('  wrote ${f.path}');
        written.add(f.path);
      });
      if (reportFile != null && reportContents != null) {
        reportFile.parent.createSync(recursive: true);
        reportFile.writeAsStringSync(reportContents);
        _log.printTrace('  wrote ${reportFile.path}');
        written.add(reportFile.path);
      }
    } else {
      for (final String rel in files.keys) {
        written.add(_fs.path.join(outputDirectory.path, rel));
      }
      if (reportFile != null) {
        written.add(reportFile.path);
      }
    }

    // Copy the source LICENSE verbatim if present.
    if (source.licenseFile != null) {
      final File dst = outputDirectory.childFile('LICENSE');
      if (!dryRun) {
        dst.parent.createSync(recursive: true);
        source.licenseFile!.copySync(dst.path);
      }
      written.add(dst.path);
    }

    return ScaffoldResult(
      outputDirectory: outputDirectory,
      writtenPaths: written,
      findings: findings,
      reportPath: reportFile?.path,
      dryRun: dryRun,
    );
  }

  /// The relative-path → contents map for the whole FFI package.
  Map<String, String> _ffiFiles(PluginSource source) {
    final String out = source.outputPackageName;
    return <String, String>{
      'pubspec.yaml': tmpl.renderPubspec(source: source, licenseHolder: licenseHolder),
      'README.md': tmpl.renderReadme(source: source, licenseHolder: licenseHolder),
      'CHANGELOG.md': tmpl.renderChangelog(source: source),
      'analysis_options.yaml': tmpl.renderAnalysisOptions(),
      '.gitignore': tmpl.renderGitignore(),
      'lib/$out.dart': tmpl.renderDartEntry(source: source, licenseHolder: licenseHolder),
      'test/${out}_test.dart':
          tmpl.renderTestStub(source: source, licenseHolder: licenseHolder),
      'watchos/Package.swift': tmpl.renderPackageSwift(source: source),
      'watchos/Classes/${out}_ffi.h':
          tmpl.renderFfiHeader(source: source, licenseHolder: licenseHolder),
      'watchos/Classes/${out}_ffi.m':
          tmpl.renderFfiSource(source: source, licenseHolder: licenseHolder),
    };
  }

  /// Runs the Swift / Objective-C transformers over the source's native
  /// files purely to collect compatibility findings for the report. Returns
  /// an empty list when the source has no native code (pure-Dart / FFI
  /// source) — the report then just describes the FFI model.
  List<PortingFinding> _collectFindings(PluginSource source) {
    final Directory dir = source.isMultiTargetSpm
        ? source.spmSourcesRoot!
        : source.classesDirectory;
    if (!dir.existsSync()) {
      return const <PortingFinding>[];
    }
    const swiftExt = <String>{'.swift'};
    const objcExt = <String>{'.h', '.m', '.mm'};
    final findings = <PortingFinding>[];
    final swiftPorter = SwiftPorter();
    final objcPorter = ObjcPorter();
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is! File) {
        continue;
      }
      final String base = _fs.path.basename(e.path);
      if (base == 'Package.swift' || base == 'Package.resolved') {
        continue;
      }
      final String ext = _fs.path.extension(e.path).toLowerCase();
      final String rel = _fs.path.relative(e.path, from: source.directory.path);
      if (swiftExt.contains(ext)) {
        findings.addAll(swiftPorter.port(e.readAsStringSync(), fileRelativePath: rel).findings);
      } else if (objcExt.contains(ext)) {
        findings.addAll(objcPorter.port(e.readAsStringSync(), fileRelativePath: rel).findings);
      }
    }
    return findings;
  }
}

/// Returned from [Scaffolder.scaffold] so callers can summarise what happened
/// without re-walking the directory.
class ScaffoldResult {
  ScaffoldResult({
    required this.outputDirectory,
    required this.writtenPaths,
    required this.findings,
    required this.reportPath,
    required this.dryRun,
  });

  final Directory outputDirectory;
  final List<String> writtenPaths;

  /// Compatibility findings collected from the source plugin's native code
  /// (which iOS APIs it used and their watchOS status). Surfaced in the
  /// report as guidance for filling in the C stub. Empty for a pure-Dart /
  /// FFI source.
  final List<PortingFinding> findings;

  /// Absolute path of the generated `PORTING_REPORT.md`, or `null` when
  /// `--no-report` suppressed it.
  final String? reportPath;

  final bool dryRun;
}

class ScaffoldError implements Exception {
  ScaffoldError(this.message);
  final String message;
  @override
  String toString() => 'ScaffoldError: $message';
}

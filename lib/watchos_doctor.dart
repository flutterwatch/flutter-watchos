// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:file/file.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/doctor.dart';
import 'package:flutter_tools/src/doctor_validator.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/version.dart' show kUserBranch;
import 'package:process/process.dart';

import 'watchos_auth.dart';
import 'watchos_cache.dart';

WatchosWorkflow? get watchosWorkflow => context.get<WatchosWorkflow>();
WatchosValidator? get watchosValidator => context.get<WatchosValidator>();

/// See: `_DefaultDoctorValidatorsProvider` in `doctor.dart`
class WatchosDoctorValidatorsProvider implements DoctorValidatorsProvider {
  @override
  List<DoctorValidator> get validators {
    final List<DoctorValidator> validators = DoctorValidatorsProvider.defaultInstance.validators;
    return <DoctorValidator>[
      PinnedFlutterValidator(validators.first),
      watchosValidator!,
      ...validators.sublist(1),
    ];
  }

  @override
  List<Workflow> get workflows => <Workflow>[
    ...DoctorValidatorsProvider.defaultInstance.workflows,
    watchosWorkflow!,
  ];
}

/// Stock Flutter's doctor entry, for the Flutter SDK flutter-watchos pins.
///
/// That SDK is checked out at one commit rather than on a branch, so the stock
/// validator reports the channel as "[user-branch]", with advice to switch
/// channel or reinstall Flutter, and warns that the `flutter` on PATH is not
/// this SDK, with advice to put this SDK first on PATH. Both are expected
/// here and both pieces of advice are wrong: the pinned SDK is not meant to be
/// switched, and putting it first on PATH would shadow the developer's own
/// Flutter. Every install showed `[!] Flutter` for it.
///
/// This drops exactly those messages (and the "if those were intentional"
/// line that follows them), says the SDK is pinned instead, and leaves
/// anything else the stock validator finds as it is.
class PinnedFlutterValidator extends DoctorValidator {
  PinnedFlutterValidator(this._inner) : super(_inner.title);

  final DoctorValidator _inner;

  static const _pinned = 'pinned by flutter-watchos';

  @override
  String get slowWarning => _inner.slowWarning;

  @override
  Future<ValidationResult> validateImpl() async {
    final ValidationResult result = await _inner.validate();
    final messages = <ValidationMessage>[];
    ValidationMessage? intentionalFooter;
    for (final ValidationMessage message in result.messages) {
      final String text = message.message;
      if (text.contains('Currently on an unknown channel') &&
          !text.contains('Cannot resolve current version')) {
        messages.add(
          ValidationMessage(
            _pinnedVersionLine(text),
            piiStrippedMessage: _pinnedVersionLine(message.piiStrippedMessage),
          ),
        );
      } else if (text.contains('on your path resolves to') ||
          text.contains('binary is not on your path')) {
        continue;
      } else if (text.startsWith('If those were intentional, you can disregard the above warnings')) {
        intentionalFooter = message;
      } else {
        messages.add(message);
      }
    }

    final bool nothingLeftToWarnAbout =
        messages.every((ValidationMessage message) => message.isInformation);
    // Anything else the stock validator warned about still stands, and so
    // does its footer.
    if (!nothingLeftToWarnAbout && intentionalFooter != null) {
      messages.add(intentionalFooter);
    }
    return ValidationResult(
      result.type == ValidationType.partial && nothingLeftToWarnAbout
          ? ValidationType.success
          : result.type,
      messages,
      statusInfo: _pinnedStatusInfo(result.statusInfo),
    );
  }

  /// "Flutter version 3.47.4 on channel [user-branch] at /x/flutter" plus the
  /// unknown-channel advice, as "Flutter version 3.47.4 at /x/flutter, pinned
  /// by flutter-watchos".
  static String _pinnedVersionLine(String text) {
    final String firstLine = text.split('\n').first.replaceFirst(' on channel $kUserBranch', '');
    return '$firstLine, $_pinned';
  }

  /// "Channel [user-branch], 3.47.4, on macOS …" as "3.47.4, pinned by
  /// flutter-watchos, on macOS …"; anything else unchanged.
  static String? _pinnedStatusInfo(String? statusInfo) {
    const prefix = 'Channel $kUserBranch, ';
    if (statusInfo == null || !statusInfo.startsWith(prefix)) {
      return statusInfo;
    }
    final String rest = statusInfo.substring(prefix.length);
    final int comma = rest.indexOf(', ');
    return comma < 0 ? '$rest, $_pinned' : '${rest.substring(0, comma)}, $_pinned${rest.substring(comma)}';
  }
}

class WatchosValidator extends DoctorValidator {
  WatchosValidator({
    required ProcessManager processManager,
    FileSystem? fileSystem,
    Platform? platform,
    OperatingSystemUtils? operatingSystemUtils,
  }) : _processManager = processManager,
       _fileSystem = fileSystem,
       _platform = platform,
       _operatingSystemUtils = operatingSystemUtils,
       super('watchOS toolchain - develop for Apple Watch devices');

  final ProcessManager _processManager;
  final FileSystem? _fileSystem;
  final Platform? _platform;
  final OperatingSystemUtils? _operatingSystemUtils;

  @override
  Future<ValidationResult> validate() async {
    ValidationType validationType = ValidationType.success;
    final messages = <ValidationMessage>[];

    // 1. Check Xcode installation
    final bool xcodeOk = await _checkXcode(messages);
    if (!xcodeOk) {
      return ValidationResult(ValidationType.missing, messages);
    }

    // 1b. Check the host architecture
    _checkHostArchitecture(messages);

    // 2. Check watchOS SDK
    await _checkWatchosSdk(messages);

    // 3. Check watchOS Simulator runtime
    await _checkSimulatorRuntime(messages);

    // 4. Check CocoaPods
    await _checkCocoaPods(messages);

    // 5. Check engine artifacts, and the account they come with
    final String statusInfo = _checkEngineArtifacts(messages);

    final bool hasErrors = messages.any(
      (ValidationMessage m) => m.type == const ValidationMessage.error('').type,
    );
    final bool hasHints = messages.any(
      (ValidationMessage m) => m.type == const ValidationMessage.hint('').type,
    );

    if (hasErrors) {
      validationType = ValidationType.partial;
    } else if (hasHints) {
      validationType = ValidationType.success;
    }

    return ValidationResult(validationType, messages, statusInfo: statusInfo);
  }

  /// Checks that Xcode is installed and reports its version.
  Future<bool> _checkXcode(List<ValidationMessage> messages) async {
    try {
      final ProcessResult result = await _processManager.run(<String>['xcodebuild', '-version']);
      if (result.exitCode == 0) {
        final String version = (result.stdout as String).split('\n').first;
        messages.add(ValidationMessage('Xcode installed ($version)'));
        return true;
      }
    } on ProcessException {
      // ignore
    }

    messages.add(
      const ValidationMessage.error(
        'Xcode is not installed. Install it from the Mac App Store.\n'
        'Xcode is required for watchOS development.',
      ),
    );
    return false;
  }

  /// Checks that this is an Apple Silicon Mac running a native shell.
  ///
  /// The engine's host tools — `gen_snapshot`, the `frontend_server`
  /// snapshot's Dart, the Simulator engine — ship as arm64-only Mach-O, so
  /// an Intel Mac cannot use them at all. An Apple Silicon Mac whose shell
  /// runs under Rosetta fails the same way one step later: the bootstrap
  /// picks the x86_64 Dart SDK for an x86_64 shell, and that VM cannot exec
  /// the arm64 tools either. Both used to surface as "bad CPU type" from deep
  /// inside an AOT build.
  void _checkHostArchitecture(List<ValidationMessage> messages) {
    final OperatingSystemUtils os = _operatingSystemUtils ?? globals.os;
    final Platform platform = _platform ?? globals.platform;
    if (os.hostPlatform == HostPlatform.darwin_x64) {
      messages.add(
        const ValidationMessage.error(
          'flutter-watchos needs an Apple Silicon Mac. The watchOS engine '
          'tools it downloads (gen_snapshot, the Simulator engine) are '
          'arm64-only and do not run on Intel.',
        ),
      );
      return;
    }
    // `hostPlatform` reports the hardware; the VM's own version string names
    // the architecture it was built for, which is what a Rosetta shell gets
    // wrong.
    if (platform.version.contains('macos_x64')) {
      messages.add(
        const ValidationMessage.error(
          'This shell runs under Rosetta (the Dart VM is x86_64), so the '
          'arm64-only watchOS engine tools cannot run from it. Open a native '
          'arm64 terminal (for example `arch -arm64 zsh`), delete '
          'flutter/bin/cache, and run flutter-watchos again.',
        ),
      );
      return;
    }
    messages.add(const ValidationMessage('Apple Silicon host (arm64)'));
  }

  /// Checks that the watchOS SDK is available in Xcode.
  Future<void> _checkWatchosSdk(List<ValidationMessage> messages) async {
    try {
      final ProcessResult result = await _processManager.run(<String>[
        'xcrun',
        '--sdk',
        'watchos',
        '--show-sdk-path',
      ]);
      if (result.exitCode == 0) {
        final String sdkPath = (result.stdout as String).trim();
        // Extract version from path like .../WatchOS11.0.sdk
        final versionRegex = RegExp(r'WatchOS(\d+\.\d+)\.sdk');
        final Match? match = versionRegex.firstMatch(sdkPath);
        final version = match != null ? ' ${match.group(1)}' : '';
        messages.add(ValidationMessage('watchOS SDK$version installed'));
        return;
      }
    } on ProcessException {
      // ignore
    }

    messages.add(
      const ValidationMessage.error(
        'watchOS SDK not found. Open Xcode → Settings → Platforms → download watchOS.',
      ),
    );
  }

  /// Checks that at least one watchOS Simulator runtime is installed.
  Future<void> _checkSimulatorRuntime(List<ValidationMessage> messages) async {
    try {
      final ProcessResult result = await _processManager.run(<String>[
        'xcrun',
        'simctl',
        'list',
        'runtimes',
        '--json',
      ]);
      if (result.exitCode == 0) {
        final stdout = result.stdout as String;
        if (stdout.contains('watchOS') ||
            stdout.contains('com.apple.CoreSimulator.SimRuntime.watchOS')) {
          final versionRegex = RegExp(r'"name"\s*:\s*"watchOS (\d+\.\d+)"');
          final Iterable<Match> matches = versionRegex.allMatches(stdout);
          if (matches.isNotEmpty) {
            final String latest = matches.last.group(1)!;
            messages.add(ValidationMessage('watchOS Simulator runtime (watchOS $latest)'));
          } else {
            messages.add(const ValidationMessage('watchOS Simulator runtime installed'));
          }
          return;
        }
      }
    } on ProcessException {
      // ignore
    }

    messages.add(
      const ValidationMessage.error(
        'No watchOS Simulator runtime found. Open Xcode → Settings → Platforms → '
        'download watchOS Simulator.',
      ),
    );
  }

  /// Checks that CocoaPods is installed (needed for plugin support).
  Future<void> _checkCocoaPods(List<ValidationMessage> messages) async {
    try {
      final ProcessResult result = await _processManager.run(<String>['pod', '--version']);
      if (result.exitCode == 0) {
        final String version = (result.stdout as String).trim();
        messages.add(ValidationMessage('CocoaPods $version'));
        return;
      }
    } on ProcessException {
      // ignore
    }

    messages.add(
      const ValidationMessage.hint(
        'CocoaPods not installed. Install with: brew install cocoapods\n'
        'CocoaPods is required for plugins with native watchOS code.',
      ),
    );
  }

  /// Reports which engines are installed, whether this machine is signed in,
  /// and which engines are still owed; returns the short summary doctor
  /// prints next to the title. Reads local files only — doctor makes no
  /// network request.
  String _checkEngineArtifacts(List<ValidationMessage> messages) {
    final FileSystem fs = _fileSystem ?? globals.fs;
    final Platform platform = _platform ?? globals.platform;
    // The directory precache and the builder use, which honours
    // WATCHOS_ENGINE_ARTIFACTS and a workspace-root engine_artifacts/.
    final Directory artifactDir = watchosArtifactDirectory(fs, platform: platform);
    final signedIn = readWatchosToken(fs, platform) != null;
    final account = signedIn ? 'signed in' : 'not signed in';

    final List<String> installed = installedEngineModes(artifactDir);
    if (installed.isEmpty) {
      messages.add(
        const ValidationMessage.hint(
          'watchOS engine artifacts not found. Run: flutter-watchos precache',
        ),
      );
    } else {
      final String? tag = readEngineVersionStamp(artifactDir);
      messages.add(
        ValidationMessage(
          'watchOS engine${tag == null ? '' : ' $tag'} at ${artifactDir.path}: '
          '${installed.join(', ')}',
          piiStrippedMessage: 'watchOS engine${tag == null ? '' : ' $tag'}: ${installed.join(', ')}',
        ),
      );
    }

    final String? login = readWatchosLogin(fs, platform);
    messages.add(
      signedIn
          ? ValidationMessage(
              'Signed in to flutterwatch.dev${login == null ? '' : ' as $login'}',
              piiStrippedMessage: 'Signed in to flutterwatch.dev',
            )
          : const ValidationMessage(
              'Not signed in: the Simulator engine works without an account; '
              '`flutter-watchos login` for a watch and release builds',
            ),
    );

    final List<String> owed = owedEngineModes(artifactDir);
    if (owed.isNotEmpty) {
      // Signed out, missing them is expected and said above; signed in, the
      // last download could not get them, which is worth a look.
      messages.add(
        signedIn
            ? ValidationMessage.hint(
                'Not installed yet: ${owed.join(', ')}. Run `flutter-watchos '
                'precache` to fetch them; it says why if it cannot.',
              )
            : ValidationMessage(
                'Not installed yet: ${owed.join(', ')} (they need an account: '
                '`flutter-watchos login`, then build or `flutter-watchos precache`)',
              ),
      );
    }

    return '${_enginesSummary(installed)}, $account';
  }

  /// "Simulator engine", "Simulator and profile engines", "all engines".
  static String _enginesSummary(List<String> installed) {
    if (installed.isEmpty) {
      return 'no engine yet';
    }
    if (installed.length == kWatchosEngineModes.length) {
      return 'all engines';
    }
    final List<String> names = installed.map((String mode) => mode.split(' ').first).toList();
    return names.length == 1
        ? '${names.single} engine'
        : '${names.take(names.length - 1).join(', ')} and ${names.last} engines';
  }

  @override
  Future<ValidationResult> validateImpl() async {
    return validate();
  }
}

/// The watchOS-specific implementation of a [Workflow].
class WatchosWorkflow extends Workflow {
  WatchosWorkflow({required OperatingSystemUtils operatingSystemUtils})
    : _operatingSystemUtils = operatingSystemUtils;

  final OperatingSystemUtils _operatingSystemUtils;

  @override
  bool get appliesToHostPlatform =>
      _operatingSystemUtils.hostPlatform == HostPlatform.darwin_x64 ||
      _operatingSystemUtils.hostPlatform == HostPlatform.darwin_arm64;

  @override
  bool get canLaunchDevices => true;

  @override
  bool get canListDevices => true;

  @override
  bool get canListEmulators => true;
}

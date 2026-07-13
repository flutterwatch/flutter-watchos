// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Pattern table mapping iOS / macOS APIs that don't exist on watchOS to
/// their status and human-readable explanation.
///
/// This is the data side of the Swift / Objective-C porter. The transformer
/// scans each line of a copied native source file against every entry here
/// and:
///   * `Severity.unsupported` → strips the matching import line if it's an
///     `import …`, otherwise stubs the enclosing `case "…":` body and
///     records a finding.
///   * `Severity.partial` → leaves the code in place and records a finding
///     so the report flags it for manual review.
///   * `Severity.info` → records a finding without modifying anything.
///
/// Adding patterns is intentionally pure-data: don't touch the porter or
/// the report emitter, just append to [compatibilityDatabase]. Patterns
/// are evaluated in declaration order; tightly-scoped patterns should
/// come before broader ones if a single line might match multiple entries
/// (today every entry is independent so order doesn't matter).
///
/// watchOS differs from the other Apple platforms in two directions at
/// once, and the table reflects both:
///   * **Less UIKit.** The UIKit *app* surface (UIApplication, UIView,
///     UIViewController, UIWindow, UIScreen, UIDevice, pasteboard,
///     feedback generators) does not exist — watchOS apps are WatchKit /
///     SwiftUI. Only the value types (UIColor, UIFont, UIImage, …) ship.
///   * **More services than tvOS.** CoreLocation, HealthKit, CoreMotion,
///     StoreKit purchasing, ASWebAuthenticationSession, and (from
///     watchOS 9) LocalAuthentication all work on the watch — so those
///     are `partial`/absent here rather than `unsupported`.
library;

/// How severely an API affects the port.
enum Severity {
  /// The API doesn't exist on watchOS. Code referencing it cannot compile
  /// or run; the porter stubs the enclosing handler with
  /// `result(FlutterMethodNotImplemented)` and records a finding.
  unsupported,

  /// The API compiles on watchOS but behaves differently or has a narrower
  /// surface (e.g. CoreLocation authorization mirrors the paired iPhone).
  /// Code is left in place; the report flags it so the user reviews each
  /// occurrence.
  partial,

  /// Worth flagging in the report but not enough to alter behaviour. Used
  /// for patterns where the user might want to know about a quirk but
  /// where leaving the code unchanged is the right default.
  info,
}

/// One iOS-API pattern in the compatibility database.
class ApiPattern {
  const ApiPattern({
    required this.name,
    required this.pattern,
    required this.severity,
    required this.note,
    this.stripSwiftImports = const <String>[],
  });

  /// Short, human-readable label that goes into the porting report
  /// (e.g. `WebKit`, `UIPasteboard`).
  final String name;

  /// Regex evaluated against each line of the source. We intentionally use
  /// String here (not RegExp) so the database is `const`-able. The porter
  /// compiles each entry once at startup.
  final String pattern;

  /// How the porter should react when [pattern] matches.
  final Severity severity;

  /// Multi-line note attached to each finding. Should explain why the API
  /// is unsupported and either suggest a watchOS replacement or explain why
  /// the feature must be omitted on watchOS.
  final String note;

  /// Optional list of Swift import lines (without the trailing newline) that
  /// should be stripped from the file when [pattern] is detected. Lets
  /// us drop, e.g., `import WebKit` when any `WKWebView` reference is
  /// found in the file.
  ///
  /// **Swift syntax only** — entries must use the Swift `import Foo` form
  /// (not ObjC `#import <Foo/Foo.h>` or `@import Foo;`). The ObjC porter
  /// derives the framework name by stripping the `import ` prefix.
  ///
  /// The porter does an exact-line match against trimmed source lines,
  /// so each entry should be the literal `import` directive.
  final List<String> stripSwiftImports;
}

/// Maps an iOS availability version to the watchOS version that shipped
/// alongside it. Used by the porters when widening `@available(iOS X, *)`
/// clauses — unlike tvOS (which tracks iOS version numbers exactly),
/// watchOS numbering is offset by 7 from iOS 9/watchOS 2 through
/// iOS 18/watchOS 11; from the 26 release Apple unified version numbers
/// across every platform.
///
/// Best-effort on minor versions (point releases mostly pair up, e.g.
/// iOS 16.4 ↔ watchOS 9.4, but not always) — the porting report tells the
/// user to review widened clauses anyway. Pre-iOS-9 availability maps to
/// `2.0`, the first real watchOS SDK.
String watchosVersionForIosVersion(String iosVersion) {
  final List<String> parts = iosVersion.split('.');
  final int? major = int.tryParse(parts.first);
  if (major == null) {
    return iosVersion;
  }
  if (major >= 26) {
    return iosVersion; // Unified numbering from the 26 release.
  }
  if (major >= 9) {
    return <String>['${major - 7}', ...parts.skip(1)].join('.');
  }
  return '2.0';
}

/// The database. Append-only; existing entries should not be removed when
/// a watchOS API gap closes — instead set the severity to [Severity.info]
/// and note the version it became available, so users porting on older OS
/// targets still see the warning.
const List<ApiPattern> compatibilityDatabase = <ApiPattern>[
  // -----------------------------------------------------------------------
  // UIKit app surface — the biggest difference from a tvOS/iOS port.
  // watchOS ships only UIKit's value types (UIColor, UIFont, UIImage, …);
  // the application/view layer below does not exist at all.
  // -----------------------------------------------------------------------
  ApiPattern(
    name: 'UIApplication',
    pattern: r'\bUIApplication\b',
    severity: Severity.unsupported,
    note:
        'UIApplication does not exist on watchOS — the app object is '
        'WKApplication (watchOS 7+) / WKExtension. For opening URLs, watchOS '
        'only supports `WKExtension.shared().openSystemURL(_:)` for tel: and '
        'sms: schemes; generic URL launching has no watchOS equivalent.',
  ),
  ApiPattern(
    name: 'UIKitViews',
    pattern: r'\bUIViewController\b|\bUIView\b|\bUIWindow\b|\bUIScreen\b'
        r'|\bUINavigationController\b|\bUIAlertController\b',
    severity: Severity.unsupported,
    note:
        'The UIKit view layer (UIView, UIViewController, UIWindow, UIScreen) '
        'does not exist on watchOS. watchOS UI is WatchKit / SwiftUI, and the '
        'Flutter watchOS embedder owns the whole screen — plugins cannot '
        'present native view controllers. Screen metrics come from '
        '`WKInterfaceDevice.current().screenBounds`.',
  ),
  ApiPattern(
    name: 'UIDevice',
    pattern: r'\bUIDevice\b',
    severity: Severity.unsupported,
    note:
        'UIDevice is not available on watchOS. Use '
        '`WKInterfaceDevice.current()` for the equivalent surface (name, '
        'model, systemVersion, screenBounds, battery — battery monitoring '
        'from watchOS 4).',
  ),
  ApiPattern(
    name: 'UIPasteboard',
    pattern: r'\bUIPasteboard\b',
    severity: Severity.unsupported,
    note:
        'watchOS has no pasteboard. Text input goes through the system '
        'dictation/scribble sheet; copy/paste is not a user-facing concept. '
        'Stubbing copy/paste handlers is safe — apps that exercise them on '
        'the watch should branch on `Platform.isWatchOS` and disable the UI.',
  ),
  ApiPattern(
    name: 'UIKitHaptics',
    pattern: r'\bUIFeedbackGenerator\b|\bUIImpactFeedbackGenerator\b'
        r'|\bUINotificationFeedbackGenerator\b|\bUISelectionFeedbackGenerator\b',
    severity: Severity.unsupported,
    note:
        'The UIKit feedback generators do not exist on watchOS. The watch '
        'DOES have haptics — port the handler to '
        '`WKInterfaceDevice.current().play(_:)` with the closest '
        '`WKHapticType` (.click, .success, .failure, .notification, …).',
  ),
  ApiPattern(
    name: 'StatusBar',
    pattern: r'\bsetStatusBarHidden\b|\bstatusBarStyle\b|\bstatusBarOrientation\b',
    severity: Severity.unsupported,
    note:
        'watchOS has no status bar (the system time overlay is not '
        'controllable by apps). These UIApplication-based setters do not '
        'exist on watchOS; the porter strips them so callers do not silently '
        'rely on broken behaviour.',
  ),
  // -----------------------------------------------------------------------
  // Frameworks absent from the watchOS SDK.
  // -----------------------------------------------------------------------
  ApiPattern(
    name: 'WebKit',
    pattern: r'\bWKWebView\b|\bWKNavigationDelegate\b|\bWKWebViewConfiguration\b',
    severity: Severity.unsupported,
    note:
        "WebKit is not available on watchOS (WatchKit's WK prefix is a "
        'different framework). There is no way to render arbitrary web '
        'content in a watchOS app; the feature must be omitted or handed '
        'off to the paired iPhone via WatchConnectivity.',
    stripSwiftImports: <String>['import WebKit'],
  ),
  ApiPattern(
    name: 'SafariServices',
    pattern: r'\bSFSafariViewController\b|\bSFSafariViewControllerDelegate\b'
        r'|\bSFAuthenticationSession\b',
    severity: Severity.unsupported,
    note:
        'SafariServices is not available on watchOS. For OAuth-style web '
        'auth, `ASWebAuthenticationSession` (AuthenticationServices) IS '
        'available from watchOS 6.2 — prefer porting the handler to that '
        'instead of dropping the feature.',
    stripSwiftImports: <String>['import SafariServices'],
  ),
  ApiPattern(
    name: 'UIImagePicker',
    pattern: r'\bUIImagePickerController\b|\bPHPickerViewController\b',
    severity: Severity.unsupported,
    note:
        'watchOS has no camera and no photo-picker UI. Plugins that surface '
        'those features should be no-ops or return errors on watchOS — the '
        'paired iPhone is the device for this.',
    stripSwiftImports: <String>['import PhotosUI'],
  ),
  ApiPattern(
    name: 'Photos',
    pattern: r'\bPHPhotoLibrary\b|\bPHAsset\b|\bPHFetchResult\b',
    severity: Severity.unsupported,
    note: 'The Photos library framework is not available on watchOS.',
    stripSwiftImports: <String>['import Photos'],
  ),
  ApiPattern(
    name: 'MailCompose',
    pattern: r'\bMFMailComposeViewController\b|\bMFMessageComposeViewController\b',
    severity: Severity.unsupported,
    note:
        'MessageUI composition UI is not available on watchOS. Hand the '
        'action off to the paired iPhone or omit the feature.',
    stripSwiftImports: <String>[
      'import MessageUI',
    ],
  ),
  ApiPattern(
    name: 'DocumentPicker',
    pattern: r'\bUIDocumentPickerViewController\b|\bUIDocumentInteractionController\b',
    severity: Severity.unsupported,
    note: 'No filesystem UI on watchOS. Apps cannot present a file browser.',
  ),
  ApiPattern(
    name: 'BackgroundFetch',
    pattern: r'\bBGTaskScheduler\b|\bBGAppRefreshTask\b|\bUIBackgroundModes\b',
    severity: Severity.unsupported,
    note:
        'BackgroundTasks (BGTaskScheduler) is an iOS API. watchOS has its '
        'own background model: scheduleBackgroundRefresh on WKApplication, '
        'delivering `WKRefreshBackgroundTask` subclasses to the extension '
        'delegate. Porting requires rethinking the scheduling contract, not '
        'a mechanical rename.',
    stripSwiftImports: <String>['import BackgroundTasks'],
  ),
  ApiPattern(
    name: 'CaptiveNetwork',
    pattern: r'\bCNCopyCurrentNetworkInfo\b|\bCNCopySupportedInterfaces\b'
        r'|\bkCNNetworkInfoKeySSID\b|\bkCNNetworkInfoKeyBSSID\b',
    severity: Severity.unsupported,
    note:
        'SystemConfiguration CaptiveNetwork (SSID/BSSID lookup) is not '
        'available on watchOS — there is no Wi-Fi network-name API. The '
        'Wi-Fi-name feature must be dropped on watchOS.',
  ),
  ApiPattern(
    name: 'SystemConfigurationReachability',
    pattern: r'\bSCNetworkReachability\w*',
    severity: Severity.unsupported,
    note:
        'The SystemConfiguration framework is not available on watchOS. For '
        'connectivity monitoring, use `NWPathMonitor` from the Network '
        'framework (available from watchOS 6) — a small, mechanical rewrite.',
    stripSwiftImports: <String>['import SystemConfiguration'],
  ),
  ApiPattern(
    name: 'NetworkExtensionHotspot',
    pattern: r'\bNEHotspotNetwork\b|\bNEHotspotConfiguration\b'
        r'|\bNEHotspotConfigurationManager\b',
    severity: Severity.unsupported,
    note:
        'NetworkExtension hotspot APIs (NEHotspotNetwork / '
        'NEHotspotConfiguration) are not available on watchOS. There is no '
        'watchOS replacement; the feature has to be omitted.',
    stripSwiftImports: <String>['import NetworkExtension'],
  ),
  ApiPattern(
    name: 'StoreKitUISurfaces',
    pattern: r'\bpresentCodeRedemptionSheet\b|\bSKStoreReviewController\b'
        r'|\bSKStoreProductViewController\b',
    severity: Severity.unsupported,
    note:
        'The StoreKit offer-code redemption sheet, review prompt, and product '
        'page UI are unavailable on watchOS (there is no in-app modal store '
        'UI). Core purchasing still works via StoreKit from watchOS 6.2; '
        'only these UI entry points must be removed.',
  ),
  ApiPattern(
    name: 'CoreTelephony',
    pattern: r'\bCTTelephonyNetworkInfo\b|\bCTCarrier\b|\bCTCellularData\b'
        r'|\bCTCellularPlanProvisioning\b',
    severity: Severity.unsupported,
    note:
        'CoreTelephony is not available on watchOS — even cellular watch '
        'models do not expose carrier/cellular-plan APIs to apps. There is '
        'no watchOS replacement; the feature must be omitted.',
    stripSwiftImports: <String>['import CoreTelephony'],
  ),
  ApiPattern(
    name: 'AVCaptureCamera',
    pattern: r'\bAVCaptureSession\b|\bAVCaptureDevice\b|\bAVCapturePhotoOutput\b'
        r'|\bAVCaptureVideoDataOutput\b|\bAVCaptureMovieFileOutput\b',
    severity: Severity.unsupported,
    note:
        'AVFoundation exists on watchOS but the capture stack does not — '
        'there is no camera. Camera features must be omitted; the rest of '
        "the plugin's AVFoundation use (players, audio) can stay.",
  ),
  ApiPattern(
    name: 'SpeechRecognition',
    pattern: r'\bSFSpeechRecognizer\b|\bSFSpeechAudioBufferRecognitionRequest\b'
        r'|\bSFSpeechURLRecognitionRequest\b',
    severity: Severity.unsupported,
    note:
        'The Speech framework is not available on watchOS. System dictation '
        'is reachable only through WatchKit text input '
        '(`presentTextInputController`), which the Flutter watchOS engine '
        'already drives for text fields — a custom speech pipeline has no '
        'watchOS port.',
    stripSwiftImports: <String>['import Speech'],
  ),
  ApiPattern(
    name: 'CallKit',
    pattern: r'\bCXProvider\b|\bCXCallController\b|\bCXProviderDelegate\b'
        r'|\bCXCallUpdate\b',
    severity: Severity.unsupported,
    note:
        'CallKit is not available on watchOS. Call UI on the watch is '
        'system-owned; the feature must be omitted.',
    stripSwiftImports: <String>['import CallKit'],
  ),
  ApiPattern(
    name: 'CoreNFC',
    pattern: r'\bNFCNDEFReaderSession\b|\bNFCTagReaderSession\b',
    severity: Severity.unsupported,
    note:
        'CoreNFC is not available on watchOS (the NFC radio is reserved for '
        'Apple Pay). The feature must be omitted.',
    stripSwiftImports: <String>['import CoreNFC'],
  ),
  ApiPattern(
    name: 'Vision',
    pattern: r'\bVNRequest\b|\bVNImageRequestHandler\b|\bVNRecognizedText\w*'
        r'|\bVNDetect\w+',
    severity: Severity.unsupported,
    note:
        'The Vision framework is not available on watchOS. CoreML itself IS '
        'available — a model-based pipeline may be portable without the '
        'Vision pre-processing layer, but that is a hand-port.',
    stripSwiftImports: <String>['import Vision'],
  ),
  ApiPattern(
    name: 'PDFKit',
    pattern: r'\bPDFDocument\b|\bPDFView\b|\bPDFPage\b',
    severity: Severity.unsupported,
    note: 'PDFKit is not available on watchOS.',
    stripSwiftImports: <String>['import PDFKit'],
  ),
  ApiPattern(
    name: 'ProcessInfoEnvironment',
    pattern: r'\bisiOSAppOnVision\b|\bisiOSAppOnMac\b',
    severity: Severity.unsupported,
    note:
        'NSProcessInfo.isiOSAppOnMac / isiOSAppOnVision are not declared in '
        'the watchOS SDK (they describe iOS-app-on-other-platform contexts '
        'that cannot occur on a watch). The reference fails to compile on '
        'watchOS and has no meaningful value — drop it.',
  ),
  ApiPattern(
    name: 'GoogleSignInSDK',
    pattern: r'\bGIDSignIn\b|\bGIDConfiguration\b|\bGIDGoogleUser\b'
        r'|\bGIDSignInResult\b',
    severity: Severity.unsupported,
    note:
        'The third-party GoogleSignIn SDK does not ship a watchOS slice, so '
        'the `GoogleSignIn` module cannot be imported when building for '
        'watchOS. Sign-in on the watch is typically delegated to the paired '
        'iPhone (WatchConnectivity) or a device-pairing OAuth flow — a '
        'different implementation, not a mechanical port.',
    stripSwiftImports: <String>['import GoogleSignIn'],
  ),
  ApiPattern(
    name: 'AVAudioSessionDefaultToSpeaker',
    pattern: r'\.defaultToSpeaker\b|AVAudioSessionCategoryOptionDefaultToSpeaker',
    severity: Severity.unsupported,
    note:
        '`.defaultToSpeaker` is an iOS-only AVAudioSession option (it '
        'describes earpiece-vs-speaker routing that watchOS does not have) '
        'and is unavailable in the watchOS SDK — referencing it fails to '
        'compile. Long-form audio on watchOS routes to Bluetooth headphones '
        'or the speaker via the system route picker instead.',
  ),
  ApiPattern(
    name: 'FlutterPlatformViews',
    pattern: r'\bFlutterPlatformViewFactory\b|registerViewFactory',
    severity: Severity.unsupported,
    note:
        'Platform views are not supported by the Flutter watchOS embedder — '
        'there is no native view hierarchy to embed into (watchOS has no '
        'UIKit view layer). Plugins built around a platform view (webviews, '
        'maps, native ads) have no watchOS port for that part.',
  ),
  // ---------------------------------------------------------------------
  // `partial` entries — these compile on watchOS but behave differently or
  // have a narrower API surface. Don't strip imports or stub method
  // bodies; just flag for manual review. Several of these were flatly
  // unavailable on tvOS — watchOS genuinely supports more.
  // ---------------------------------------------------------------------
  ApiPattern(
    name: 'CoreLocation',
    pattern: r'\bCLLocationManager\b|\bCLLocation\b',
    severity: Severity.partial,
    note:
        'CoreLocation IS available on watchOS: requestLocation, continuous '
        'updates, and heading (watchOS 6+) work, with GPS on cellular/GPS '
        'models and phone-assisted fixes otherwise. Differences to review: '
        'authorization is shared with the paired iPhone app when one exists, '
        'region monitoring is limited, and background location needs a '
        'workout or background-refresh context.',
  ),
  ApiPattern(
    name: 'LocalAuthentication',
    pattern: r'\bLAContext\b|\bLAPolicy\b',
    severity: Severity.partial,
    note:
        'LocalAuthentication is available on watchOS from 9.0 — but only '
        '`.deviceOwnerAuthentication` (passcode / wrist-detection unlock); '
        'there is no Face ID or Touch ID biometry on the watch, so '
        '`.deviceOwnerAuthenticationWithBiometrics` policies fail. Review '
        'each policy the plugin evaluates, and gate on `#available(watchOS '
        '9.0, *)` if the deployment target is lower.',
  ),
  ApiPattern(
    name: 'ASWebAuthenticationSession',
    pattern: r'\bASWebAuthenticationSession\b',
    severity: Severity.partial,
    note:
        'ASWebAuthenticationSession IS available on watchOS from 6.2 (unlike '
        'tvOS). The presentation is system-managed and '
        '`presentationContextProvider` / `prefersEphemeralWebBrowserSession` '
        'are not available on watchOS — review the configuration call sites.',
  ),
  ApiPattern(
    name: 'StoreKit',
    pattern: r'\bSKPaymentQueue\b|\bSKProduct\b|\bSKReceiptRefreshRequest\b',
    severity: Severity.partial,
    note:
        'StoreKit purchasing works on watchOS from 6.2 (StoreKit 2 from '
        'watchOS 8), but the UI surfaces (`SKStoreProductViewController`, '
        '`SKStoreReviewController`, code redemption) are missing. Audit each '
        'StoreKit call site by hand and check the deployment target.',
  ),
  ApiPattern(
    name: 'AVAudioSessionBluetoothOptions',
    pattern: r'\.allowBluetooth\b|\.allowBluetoothA2DP\b'
        r'|AVAudioSessionCategoryOptionAllowBluetooth(?:A2DP)?',
    severity: Severity.partial,
    note:
        'watchOS routes audio to Bluetooth automatically and its '
        'AVAudioSession category-options surface is narrower than iOS. '
        'Verify each option against the watchOS SDK for your deployment '
        'target; playback sessions on watchOS should use '
        '`activate(options:completionHandler:)` so the system can prompt '
        'the user to pick an output route.',
  ),
  ApiPattern(
    name: 'WatchConnectivity',
    pattern: r'\bWCSession\b',
    severity: Severity.info,
    note:
        'WCSession exists on watchOS, but code copied from an iOS plugin '
        'was written for the *phone* side of the session. On watchOS the '
        'roles flip (isPaired/watchAppInstalled are iOS-only; the watch '
        'side uses isCompanionAppInstalled/iOSDeviceNeedsUnlockAfterRebootForReachability). '
        'Review the session wiring rather than assuming it transfers.',
  ),
];

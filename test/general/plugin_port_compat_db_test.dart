// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_watchos/plugin_porting/compatibility_database.dart';

import '../src/common.dart';

/// For every entry in [compatibilityDatabase], one line of Swift that should
/// match (a real use of the API) and one that should NOT (a similarly named
/// but allowed symbol). Keyed by [ApiPattern.name]. The test fails if a
/// pattern is added without a corresponding sample — a deliberate guard so
/// the database can't grow untested.
const Map<String, ({String positive, String negative})> _samples =
    <String, ({String positive, String negative})>{
  'UIApplication': (
    positive: 'UIApplication.shared.open(url, options: [:], completionHandler: nil)',
    negative: 'let app = WKApplication.shared()',
  ),
  'UIKitViews': (
    positive: 'let vc = UIViewController()',
    negative: 'let controller = WKInterfaceController()',
  ),
  'UIDevice': (
    positive: 'let name = UIDevice.current.name',
    negative: 'let d = WKInterfaceDevice.current()',
  ),
  'UIPasteboard': (
    positive: 'UIPasteboard.general.string = value',
    negative: 'let p = CustomPasteboard()',
  ),
  'UIKitHaptics': (
    positive: 'let gen = UIImpactFeedbackGenerator(style: .medium)',
    negative: 'let gen = ScoreGenerator()',
  ),
  'StatusBar': (
    positive: 'app.setStatusBarHidden(true, with: .fade)',
    negative: 'updateStatusLabel(text)',
  ),
  'WebKit': (
    positive: 'let webView = WKWebView(frame: .zero)',
    negative: 'let view = MyWebViewContainer()',
  ),
  'SafariServices': (
    positive: 'let vc = SFSafariViewController(url: url)',
    negative: 'let vc = SafariLikeController()',
  ),
  'UIImagePicker': (
    positive: 'let picker = UIImagePickerController()',
    negative: 'let picker = ColorPickerController()',
  ),
  'Photos': (
    positive: 'PHPhotoLibrary.shared().performChanges({})',
    negative: 'let lib = AppPhotoStore()',
  ),
  'MailCompose': (
    positive: 'let mc = MFMailComposeViewController()',
    negative: 'let mc = MailDraftController()',
  ),
  'DocumentPicker': (
    positive: 'let dp = UIDocumentPickerViewController(forOpeningContentTypes: [])',
    negative: 'let dp = FileBrowserController()',
  ),
  'BackgroundFetch': (
    positive: 'BGTaskScheduler.shared.register(forTaskWithIdentifier: id)',
    negative: 'let task = AsyncWorkTask()',
  ),
  'CaptiveNetwork': (
    positive: 'let info = CNCopyCurrentNetworkInfo(interface)',
    negative: 'let info = CurrentNetworkInfoStore()',
  ),
  'SystemConfigurationReachability': (
    positive: 'let ref = SCNetworkReachabilityCreateWithName(nil, host)',
    negative: 'let r = ReachabilityMonitor()',
  ),
  'NetworkExtensionHotspot': (
    positive: 'NEHotspotNetwork.fetchCurrent { network in }',
    negative: 'let n = HotspotNetworkModel()',
  ),
  'StoreKitUISurfaces': (
    positive: 'SKPaymentQueue.default().presentCodeRedemptionSheet()',
    negative: 'showRedeemCodeUI()',
  ),
  'CoreTelephony': (
    positive: 'let info = CTTelephonyNetworkInfo()',
    negative: 'let info = TelephonyNetworkInfoStub()',
  ),
  'AVCaptureCamera': (
    positive: 'let session = AVCaptureSession()',
    negative: 'let session = AVAudioSession.sharedInstance()',
  ),
  'SpeechRecognition': (
    positive: 'let recognizer = SFSpeechRecognizer(locale: locale)',
    negative: 'let s = SpeechSynthesizerWrapper()',
  ),
  'CallKit': (
    positive: 'let provider = CXProvider(configuration: config)',
    negative: 'let p = CallProviderShim()',
  ),
  'CoreNFC': (
    positive: 'let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)',
    negative: 'let s = NfcLikeReader()',
  ),
  'Vision': (
    positive: 'let handler = VNImageRequestHandler(cgImage: image)',
    negative: 'let v = VisionaryModel()',
  ),
  'PDFKit': (
    positive: 'let doc = PDFDocument(url: url)',
    negative: 'let doc = PdfExportJob()',
  ),
  'ProcessInfoEnvironment': (
    positive: 'let v = ProcessInfo.processInfo.isiOSAppOnMac',
    negative: 'let v = processInfo.environment["X"]',
  ),
  'GoogleSignInSDK': (
    positive: 'GIDSignIn.sharedInstance.signIn(withPresenting: vc)',
    negative: 'let s = GoogleSignInController()',
  ),
  'AVAudioSessionDefaultToSpeaker': (
    positive: 'try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])',
    negative: 'session.setCategory(.playback, mode: .moviePlayback)',
  ),
  'FlutterPlatformViews': (
    positive: 'class MyFactory: NSObject, FlutterPlatformViewFactory {',
    negative: 'let f = PlatformViewLikeBuilder()',
  ),
  'CoreLocation': (
    positive: 'let manager = CLLocationManager()',
    negative: 'let manager = LocationServiceManager()',
  ),
  'LocalAuthentication': (
    positive: 'let context = LAContext()',
    negative: 'let label = makeLabel()',
  ),
  'ASWebAuthenticationSession': (
    positive: 'let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { _, _ in }',
    negative: 'let s = WebAuthHelper()',
  ),
  'StoreKit': (
    positive: 'SKPaymentQueue.default().add(payment)',
    negative: 'let q = JobPaymentQueue()',
  ),
  'AVAudioSessionBluetoothOptions': (
    positive: 'try session.setCategory(.playback, options: [.allowBluetoothA2DP])',
    negative: 'session.setCategory(.playback, mode: .moviePlayback)',
  ),
  'WatchConnectivity': (
    positive: 'if WCSession.isSupported() {',
    negative: 'let s = WatchSessionManager()',
  ),
};

void main() {
  group('compatibilityDatabase', () {
    testWithoutContext('every entry has a unique name', () {
      final Set<String> names =
          compatibilityDatabase.map((ApiPattern p) => p.name).toSet();
      expect(names.length, compatibilityDatabase.length,
          reason: 'duplicate ApiPattern.name would shadow report findings');
    });

    testWithoutContext('every entry has a positive and negative sample', () {
      for (final ApiPattern p in compatibilityDatabase) {
        expect(
          _samples.containsKey(p.name),
          isTrue,
          reason:
              'No test sample for new pattern "${p.name}". Add one to _samples.',
        );
      }
    });

    testWithoutContext('every regex compiles', () {
      for (final ApiPattern p in compatibilityDatabase) {
        expect(() => RegExp(p.pattern), returnsNormally,
            reason: '${p.name} has an invalid regex');
      }
    });

    for (final ApiPattern p in compatibilityDatabase) {
      testWithoutContext('${p.name}: matches a real use, ignores look-alikes', () {
        final re = RegExp(p.pattern);
        final ({String negative, String positive}) s = _samples[p.name]!;
        expect(re.hasMatch(s.positive), isTrue,
            reason: '${p.name} regex should match: ${s.positive}');
        expect(re.hasMatch(s.negative), isFalse,
            reason: '${p.name} regex should NOT match: ${s.negative}');
      });
    }

    testWithoutContext('unsupported entries carry an explanatory note', () {
      for (final ApiPattern p in compatibilityDatabase) {
        expect(p.note.trim(), isNotEmpty, reason: '${p.name} has no note');
        if (p.severity == Severity.unsupported) {
          // Unsupported entries should explain the watchOS situation, not just
          // name the API — the note is surfaced verbatim in the report.
          expect(p.note.length, greaterThan(20), reason: '${p.name} note too thin');
        }
      }
    });
  });

  group('watchosVersionForIosVersion', () {
    testWithoutContext('maps the offset era (iOS 9–18 → watchOS 2–11)', () {
      expect(watchosVersionForIosVersion('9'), '2');
      expect(watchosVersionForIosVersion('13.0'), '6.0');
      expect(watchosVersionForIosVersion('15.0'), '8.0');
      expect(watchosVersionForIosVersion('16.4'), '9.4');
      expect(watchosVersionForIosVersion('18'), '11');
    });

    testWithoutContext('unified numbering from 26 passes through', () {
      expect(watchosVersionForIosVersion('26.0'), '26.0');
      expect(watchosVersionForIosVersion('27.1'), '27.1');
    });

    testWithoutContext('pre-iOS-9 availability floors to the first SDK', () {
      expect(watchosVersionForIosVersion('8.0'), '2.0');
      expect(watchosVersionForIosVersion('7'), '2.0');
    });

    testWithoutContext('non-numeric input is returned unchanged', () {
      expect(watchosVersionForIosVersion('x.y'), 'x.y');
    });
  });
}

// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';

/// Writes the shared, platform-agnostic part of a Flutter app (the bits
/// `flutter create` would put in `lib/`, `test/`, `pubspec.yaml`, …) so a
/// watchOS-only project can be produced WITHOUT scaffolding — and then
/// deleting — an unwanted iOS/Android app.
///
/// The caller renders `watchos/` on top of this. Nothing here references any
/// other platform, so the result is watchOS-only by construction.
class WatchosAppScaffold {
  WatchosAppScaffold(this._fs);

  final FileSystem _fs;

  /// Generates the app shell at [projectDirPath] for package [name].
  /// Files that already exist are left untouched (so re-runs are safe).
  void write(String projectDirPath, String name) {
    final Directory root = _fs.directory(projectDirPath)..createSync(recursive: true);

    _put(root.childFile('pubspec.yaml'), _pubspec(name));
    _put(root.childDirectory('lib').childFile('main.dart'), _mainDart());
    _put(root.childDirectory('test').childFile('widget_test.dart'), _widgetTest(name));
    _put(root.childFile('analysis_options.yaml'), _analysisOptions());
    _put(root.childFile('.gitignore'), _gitignore());
    _put(root.childFile('README.md'), _readme(name));
  }

  void _put(File f, String contents) {
    if (f.existsSync()) {
      return;
    }
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(contents);
  }

  String _pubspec(String name) => '''
name: $name
description: "A watchOS example app for $name."
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
''';

  String _mainDart() => r'''
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter-watchos run".
        // You'll see the counter is styled with a deep-purple accent. Then,
        // without quitting the app, try changing the seedColor below to
        // Colors.green and invoke "hot reload" (save your changes, or press
        // "r" in the console where you started the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter Demo'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('Pushes:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
''';

  String _widgetTest(String name) => '''
// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:$name/main.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that our counter starts at 0.
    expect(find.text('0'), findsOneWidget);
    expect(find.text('1'), findsNothing);

    // Tap the '+' icon and trigger a frame.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    // Verify that our counter has incremented.
    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });
}
''';

  String _analysisOptions() => '''
include: package:flutter_lints/flutter.yaml
''';

  String _gitignore() => '''
.dart_tool/
.packages
build/
.flutter-plugins
.flutter-plugins-dependencies
*.iml
.idea/
.DS_Store

# watchOS / CocoaPods
watchos/Pods/
watchos/Podfile.lock
watchos/.symlinks/
watchos/Flutter/Flutter.framework
''';

  String _readme(String name) => '''
# $name

A watchOS-only example app. Run it on an Apple Watch simulator with:

```sh
flutter-watchos run
```
''';
}

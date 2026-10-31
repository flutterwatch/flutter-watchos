// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter_tools/src/base/file_system.dart';

File watchosPackageConfigFile(Directory projectDirectory) {
  final Directory resolutionRoot = pubWorkspaceRootOf(projectDirectory) ?? projectDirectory;
  return resolutionRoot.childDirectory('.dart_tool').childFile('package_config.json');
}

Directory? pubWorkspaceRootOf(Directory projectDirectory) {
  final File workspaceRef = projectDirectory
      .childDirectory('.dart_tool')
      .childDirectory('pub')
      .childFile('workspace_ref.json');
  if (!workspaceRef.existsSync()) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = json.decode(workspaceRef.readAsStringSync());
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
  if (decoded case {'workspaceRoot': final String workspaceRoot}) {
    final FileSystem fileSystem = projectDirectory.fileSystem;
    return fileSystem.directory(
      fileSystem.path.normalize(fileSystem.path.join(workspaceRef.parent.path, workspaceRoot)),
    );
  }
  return null;
}

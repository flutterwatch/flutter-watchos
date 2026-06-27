// swift-tools-version:5.9
// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import PackageDescription

let package = Package(
    name: "flutter_watchos",
    platforms: [
        .watchOS(.v7),
    ],
    products: [
        .library(name: "flutter-watchos", targets: ["flutter_watchos"]),
    ],
    targets: [
        .target(
            name: "flutter_watchos",
            path: "Classes",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
            ],
            linkerSettings: [
                .linkedFramework("WatchKit"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)

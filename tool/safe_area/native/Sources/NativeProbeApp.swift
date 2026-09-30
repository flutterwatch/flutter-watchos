// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Native SwiftUI safe-area probe. Page picked by $HOME/Documents/nprobe_PAGE.txt
//   0 plain view (+ a host-like overlay measurement)
//   1 NavigationStack + navigationTitle
//   2 List
//   3 ScrollView
//   4 NavigationStack + List + navigationTitle (the canonical watch app)
//   5 List scrolled so row 3 is at the top
//   6 ScrollView scrolled so row 3 is at the top
//   7 NavigationStack + List + title, scrolled
//   8 plain view with .persistentSystemOverlays(.hidden)
//   9 NavigationStack + List with .persistentSystemOverlays(.hidden)
// Every page overlays the ROOT safe rect (green) and the screen edge (red).
import SwiftUI
import WatchKit

func cfg(_ key: String) -> String {
    let env = ProcessInfo.processInfo.environment
    if let v = env["NPROBE_\(key)"], !v.isEmpty { return v }
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/nprobe_\(key).txt")
    if let s = try? String(contentsOf: url, encoding: .utf8) {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}

let page = Int(cfg("PAGE")) ?? 0
let dev = cfg("DEV")

func ei(_ e: EdgeInsets) -> String {
    String(format: "L%.2f,T%.2f,R%.2f,B%.2f", e.leading, e.top, e.trailing, e.bottom)
}
func rs(_ r: CGRect) -> String {
    String(format: "%.2f,%.2f %.2fx%.2f", r.minX, r.minY, r.width, r.height)
}
func plog(_ tag: String, _ s: String) {
    NSLog("NPROBE|dev=%@|page=%d|%@|%@", dev, page, tag, s)
}

@main
struct NativeProbeApp: App {
    init() {
        let d = WKInterfaceDevice.current()
        plog("device", "screenBounds=\(rs(d.screenBounds))|screenScale=\(d.screenScale)|model=\(d.model)|os=\(d.systemVersion)|name=\(d.name)")
    }
    var body: some Scene {
        WindowGroup { Root() }
    }
}

/// A GeometryReader that logs its size, safe-area insets and global frame.
struct Probe: View {
    let tag: String
    var body: some View {
        GeometryReader { p in
            Color.clear
                .onAppear {
                    report(p)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { report(p) }
                }
                .onChange(of: p.safeAreaInsets) { _, _ in report(p) }
                .onChange(of: p.size) { _, _ in report(p) }
        }
        .allowsHitTesting(false)
    }
    func report(_ p: GeometryProxy) {
        plog(tag, "size=\(String(format: "%.2fx%.2f", p.size.width, p.size.height))|safeAreaInsets=\(ei(p.safeAreaInsets))|global=\(rs(p.frame(in: .global)))")
    }
}

extension View {
    /// Log this view's global frame whenever it changes.
    func logFrame(_ tag: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
            plog(tag, "global=\(rs(r))")
        }
    }
}

struct Root: View {
    var body: some View {
        content
            // Root safe rect: the overlay's bounds ARE the safe rect of the
            // page's root, since nothing here ignores the safe area.
            .overlay {
                ZStack {
                    Rectangle().stroke(Color.green, lineWidth: 2)
                    Probe(tag: "root-overlay")
                }
                .allowsHitTesting(false)
            }
            .overlay {
                Rectangle().stroke(Color.red, lineWidth: 2)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder var content: some View {
        switch page {
        case 1: NavPage()
        case 2: ListPage(scrollTo: nil)
        case 3: ScrollPage(scrollTo: nil)
        case 4: NavListPage(scrollTo: nil)
        case 5: ListPage(scrollTo: 3)
        case 6: ScrollPage(scrollTo: 3)
        case 7: NavListPage(scrollTo: 3)
        case 8: PlainPage().persistentSystemOverlays(.hidden)
        case 9: NavListPage(scrollTo: nil).persistentSystemOverlays(.hidden)
        default: PlainPage()
        }
    }
}

struct PlainPage: View {
    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
            // The host module's measurement: an overlay on a full-bleed view.
            Color.clear.ignoresSafeArea().overlay(Probe(tag: "hostlike-overlay"))
            Probe(tag: "plain")
            VStack(spacing: 2) {
                Text("native p0").font(.system(size: 12))
                Text("plain view").font(.system(size: 12))
            }
        }
    }
}

struct NavPage: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Probe(tag: "nav-content")
                Text("nav content").font(.system(size: 12))
            }
            .navigationTitle("Title")
        }
    }
}

struct Rows: View {
    var body: some View {
        ForEach(0..<30, id: \.self) { i in
            HStack(spacing: 0) {
                Text("L\(i)")
                Spacer(minLength: 0)
                Text("Row text").font(.system(size: 13))
                Spacer(minLength: 0)
                Text("R\(i)")
            }
            .id(i)
            .modifier(FirstRowLogger(index: i))
            .listRowBackground(rowColor(i))
        }
    }
}

func rowColor(_ i: Int) -> Color {
    i == 0 ? Color(red: 0.88, green: 0.56, blue: 0)
        : (i.isMultiple(of: 2) ? Color(red: 0.12, green: 0.35, blue: 0.66)
                                : Color(red: 0.09, green: 0.5, blue: 0.43))
}

struct FirstRowLogger: ViewModifier {
    let index: Int
    func body(content: Content) -> some View {
        if index == 0 { content.logFrame("row0") }
        else if index == 3 { content.logFrame("row3") }
        else { content }
    }
}

struct ListPage: View {
    let scrollTo: Int?
    var body: some View {
        ScrollViewReader { proxy in
            List { Rows() }
                .background(Probe(tag: "list-background"))
                .onAppear {
                    guard let t = scrollTo else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        proxy.scrollTo(t, anchor: .top)
                    }
                }
        }
    }
}

struct ScrollPage: View {
    let scrollTo: Int?
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    Probe(tag: "scroll-content").frame(height: 1)
                    ForEach(0..<30, id: \.self) { i in
                        HStack(spacing: 0) {
                            Text("L\(i)")
                            Spacer(minLength: 0)
                            Text("Row text").font(.system(size: 13))
                            Spacer(minLength: 0)
                            Text("R\(i)")
                        }
                        .frame(height: 40)
                        .background(rowColor(i))
                        .id(i)
                        .modifier(FirstRowLogger(index: i))
                    }
                }
            }
            .background(Probe(tag: "scroll-background"))
            .onAppear {
                guard let t = scrollTo else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    proxy.scrollTo(t, anchor: .top)
                }
            }
        }
    }
}

struct NavListPage: View {
    let scrollTo: Int?
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List { Rows() }
                    .background(Probe(tag: "navlist-background"))
                    .navigationTitle("Title")
                    .onAppear {
                        guard let t = scrollTo else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            proxy.scrollTo(t, anchor: .top)
                        }
                    }
            }
        }
    }
}

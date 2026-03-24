//
//  SurProxyApp.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import SwiftUI
import AppKit

final class SurProxyAppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct SurProxyApp: App {
    @NSApplicationDelegateAdaptor(SurProxyAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel

    init() {
        _viewModel = StateObject(wrappedValue: AppViewModel(service: ProxyService()))
    }

    var body: some Scene {
        Window("SurProxy", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear {
                    appDelegate.onTerminate = { viewModel.shutdown() }
                }
        }
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra("SurProxy", systemImage: "bolt.horizontal.circle") {
            TrayMenuContent(viewModel: viewModel)
        }
    }
}

private struct TrayMenuContent: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open SurProxy") {
            DispatchQueue.main.async {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button(viewModel.snapshot.runtimeState == .running ? "Stop Service" : "Start Service") {
            Task {
                if viewModel.snapshot.runtimeState == .running {
                    await viewModel.stopProxy()
                } else {
                    await viewModel.startProxy()
                }
            }
        }
        .disabled(viewModel.isLoading)

        Divider()

        Button("Quit SurProxy") {
            viewModel.shutdown()
            NSApp.terminate(nil)
        }
    }
}

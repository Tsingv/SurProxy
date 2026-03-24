//
//  SurProxyApp.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import SwiftUI
import AppKit

@main
struct SurProxyApp: App {
    @StateObject private var viewModel: AppViewModel

    init() {
        _viewModel = StateObject(wrappedValue: AppViewModel(service: ProxyService()))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1040, minHeight: 680)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    viewModel.shutdown()
                }
        }
    }
}

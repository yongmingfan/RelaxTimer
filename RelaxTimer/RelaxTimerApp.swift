//
//  RelaxTimerApp.swift
//  RelaxTimer
//
//  Created by Yongming Fan on 3/6/26.
//

import SwiftUI

@main
struct RelaxTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup => no main interface
        Settings {
            EmptyView()
        }
    }
}

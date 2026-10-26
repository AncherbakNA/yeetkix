import SwiftUI
import AppKit
import LumaCore

@main
struct YeetkixApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    init() { ScanWorkerHost.runIfRequested(); UtilityWorkerHost.runIfRequested() }
    var body: some Scene {
        WindowGroup("YEETKIX") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1050, minHeight: 730)
                .preferredColorScheme(.light)
                .tint(Palette.accent)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { model.navigate(.settings) }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Руководство YEETKIX") { model.showHelp = true }
            }
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { model.updater.check() }.disabled(!model.updater.ready)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Очистка") {
                Button("Сканировать Mac") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning || model.isCleaning || model.utilities.isBusy || model.showConfirmation || model.utilities.showReviewConfirmation || model.utilities.showManagedConfirmation)
                Button("Остановить сканирование") { model.cancelScan() }
                    .disabled(!model.isScanning)
                Divider()
                Button("Отчёт о сканировании…") { model.showScanDetails() }.disabled(model.report == nil || model.isScanning || model.isCleaning)
                Button("Сохранить отчёт…") { model.exportScanReport() }.disabled(model.report == nil || model.isScanning || model.isCleaning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isCleaning else { return .terminateNow }
        model.cancelCleanup()
        Task { await model.waitForOperation(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Palette.background)
            window.isMovableByWindowBackground = true
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

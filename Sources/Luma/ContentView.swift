import SwiftUI
import LumaCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Group {
                    if model.destination == .overview { DashboardView() }
                    else if model.destination == .settings { PreferencesView() }
                    else if model.destination == .history { HistoryView() }
                    else if model.destination == .applications { ApplicationsView() }
                    else if model.destination == .diskMap { DiskMapView() }
                    else if model.destination == .backups { BackupsView() }
                    else if model.destination == .tools { ManagedResourcesView() }
                    else if model.isScanning { ScanProgressView() }
                    else if model.needsScan { ScanWelcomeView() }
                    else if model.destination == .duplicates { DuplicateResultsView() }
                    else { FileBrowserView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Palette.background)
        }
        .foregroundStyle(Palette.ink)
        .environmentObject(model.utilities)
        .environmentObject(model.updater)
        .sheet(isPresented: $model.showConfirmation) { TrashConfirmationView() }
        .sheet(isPresented: $model.showWelcome) { WelcomeView() }
        .sheet(isPresented: $model.showScanReport) { ScanReportView() }
        .sheet(isPresented: $model.showHelp) { HelpView() }
        .sheet(isPresented: Binding(get: { model.utilities.showReviewConfirmation }, set: { model.utilities.showReviewConfirmation = $0 })) { ReviewedItemsConfirmation() .environmentObject(model.utilities) }
        .sheet(isPresented: Binding(get: { model.utilities.showManagedConfirmation }, set: { model.utilities.showManagedConfirmation = $0 })) { ManagedConfirmation() .environmentObject(model.utilities) }
        .onAppear { if !model.hasSeenWelcome { model.showWelcome = true }; model.updater.startIfConfigured() }
        .alert("YEETKIX", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("Понятно", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .onChange(of: model.destination) { _, _ in model.query = ""; model.selection.removeAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancelScan() }
        .animation(.easeInOut(duration: 0.18), value: model.destination)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.destination.title).font(.system(size: 23, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button { model.showHelp = true } label: { Image(systemName: "questionmark.circle").font(.system(size: 16)) }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary).help("Руководство YEETKIX").accessibilityLabel("Руководство YEETKIX")
            HStack(spacing: 7) {
                Circle().fill(Palette.mint).frame(width: 6, height: 6)
                Text("Локальная утилита").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.8), in: Capsule())
        }
        .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 24)
    }
    private var subtitle: String {
        switch model.destination {
        case .overview: return "Использование диска и поиск файлов для очистки."
        case .cleanup: return "Старые кэши и журналы в доступных папках."
        case .large: return "Файлы от 100 МБ в личных папках."
        case .downloads: return "Файлы в папке Downloads."
        case .trash: return "Просмотр Корзины и переход в Finder."
        case .duplicates: return "Группы файлов с одинаковым содержимым."
        case .leftovers: return "Данные приложений, которые не найдены на Mac."
        case .developer: return "Сгенерированные сборки, индексы и кэши Xcode."
        case .toolCaches: return "Загруженные архивы и кэши инструментов разработки."
        case .applications: return "Состав приложения и связанные файлы."
        case .diskMap: return "Размеры выбранной папки и её содержимого."
        case .backups: return "Завершённые локальные резервные копии iPhone и iPad."
        case .tools: return "Симуляторы и Docker — через их штатные инструменты."
        case .history: return "Записи операций и доступное восстановление."
        case .settings: return "Доступ к папкам, исключения и параметры проверки."
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("YEETKIX").font(.system(size: 25, weight: .bold, design: .rounded)).tracking(-0.8)
                    Text("Утилита для macOS").font(.system(size: 8.5)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.leading, 23).padding(.top, 50).padding(.bottom, 27)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: "РАЗДЕЛЫ").padding(.leading, 25).padding(.bottom, 10)
                    navItem(.overview)
                    navItem(.cleanup)
                    Eyebrow(text: "ПОИСК").padding(.leading, 25).padding(.top, 22).padding(.bottom, 10)
                    navItem(.duplicates)
                    navItem(.leftovers)
                    navItem(.developer)
                    navItem(.toolCaches)
                    navItem(.applications)
                    navItem(.diskMap)
                    navItem(.backups)
                    navItem(.tools)
                    navItem(.large)
                    navItem(.downloads)
                    Eyebrow(text: "СИСТЕМА").padding(.leading, 25).padding(.top, 22).padding(.bottom, 10)
                    navItem(.trash)
                    navItem(.history)
                }
            }.scrollIndicators(.hidden)
            Label("Только с вашим подтверждением", systemImage: "lock.shield")
                .font(.system(size: 9)).foregroundStyle(Palette.secondary).padding(.horizontal, 22).padding(.vertical, 17)
            navItem(.settings)
            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer").font(.system(size: 11))
                Text(model.computerName).font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(Palette.secondary).padding(.horizontal, 25).padding(.top, 21).padding(.bottom, 24)
        }
        .frame(width: 218)
        .background(Palette.sidebar)
    }

    private func navItem(_ target: Destination) -> some View {
        let selected = model.destination == target
        return Button { model.navigate(target) } label: {
            HStack(spacing: 11) {
                Image(systemName: target.symbol).font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .frame(width: 20)
                Text(target.title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if target == model.destination && model.isScanning {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else if target == .cleanup, let report = model.report, report.cleanupBytes > 0 {
                    Circle().fill(Palette.accent).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(selected ? Palette.accent : Color(hex: 0x77768B))
            .padding(.horizontal, 13).frame(height: 41)
            .background(selected ? Color(hex: 0xE4DEF7) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 13).padding(.vertical, 2)
        .accessibilityIdentifier("nav-" + target.rawValue)
    }
}

import SwiftUI
import Sparkle

@MainActor final class UpdaterModel: ObservableObject {
    @Published var ready = false
    @Published var automatic = false
    private var controller: SPUStandardUpdaterController?
    private var initialized = false
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    func startIfConfigured() {
        guard !initialized else { return }; initialized = true
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, Data(base64Encoded: key)?.count == 32 else { return }
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller = updater; updater.startUpdater(); ready = true; automatic = updater.updater.automaticallyChecksForUpdates
    }
    func check() { guard ready else { return }; controller?.checkForUpdates(nil) }
    func setAutomatic(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled; automatic = enabled }
}

struct UpdatesPreferences: View {
    @EnvironmentObject var updater: UpdaterModel
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 15) {
                Label("Обновления", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 15, weight: .semibold))
                if updater.ready {
                    Toggle("Автоматически проверять обновления", isOn: Binding(get: { updater.automatic }, set: { updater.setAutomatic($0) })).font(.system(size: 12))
                    Text("Загрузка проверяется по подписи разработчика. Установка — через системное окно Sparkle.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Button("Проверить обновления…") { updater.check() }.buttonStyle(QuietButton())
                } else {
                    Text("Локальная сборка. Канал обновлений пока не подключён.").font(.system(size: 12, weight: .medium))
                    Text("Новые версии можно собрать из исходников в репозитории проекта.").font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                }
            }
        }
    }
}

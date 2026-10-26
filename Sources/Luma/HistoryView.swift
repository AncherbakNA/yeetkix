import SwiftUI
import LumaCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var showManaged = false
    private var filtered: [HistoryEntry] {
        search.isEmpty ? model.history : model.history.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.originalURL.path.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 17) {
                IconTile(symbol: "clock.arrow.circlepath", color: Palette.mint, size: 54)
                VStack(alignment: .leading, spacing: 7) {
                    Text("История операций").font(.system(size: 24, weight: .bold))
                    Text("История сохраняется между запусками. Восстановление не перезаписывает существующие файлы.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }.padding(22).background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            if let error = model.historyError {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.orange).padding(18)
                Button("Показать журнал в Finder") { model.reveal(model.historyURL.deletingLastPathComponent()) }.buttonStyle(QuietButton())
            }
            if !model.historyReady && model.historyError == nil {
                HStack { ProgressView().controlSize(.small); Text("Проверяем журнал операций…").font(.system(size: 12)); Spacer() }
            }
            if model.isCleaning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.operationProgress).font(.system(size: 12))
                    Spacer()
                    Button("Остановить") { model.cancelCleanup() }.buttonStyle(QuietButton())
                }
            }
            if !model.managedHistory.isEmpty {
                DisclosureGroup("Docker и симуляторы · \(model.managedHistory.count)", isExpanded: $showManaged) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.managedHistory) { event in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.resource.name + " · " + event.state).font(.system(size: 11, weight: .semibold))
                                    Text(event.date, format: .dateTime.day().month().hour().minute()).font(.system(size: 9)).foregroundStyle(Palette.secondary)
                                    Text(event.detail).font(.system(size: 10)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(maxHeight: 180)
                }.font(.system(size: 12)).padding(13).background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Операции · \(model.history.count)").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField("Поиск в истории", text: $search).textFieldStyle(.plain).font(.system(size: 11)).frame(width: 180)
                }.padding(18)
                Divider().overlay(Palette.line)
                if filtered.isEmpty {
                    VStack(spacing: 13) {
                        IconTile(symbol: "clock", color: Palette.mint, size: 54)
                        Text(search.isEmpty ? "Пока ни одного перемещения" : "Ничего не найдено").font(.system(size: 18, weight: .semibold))
                        Text("Здесь появятся только операции, которые вы подтвердили.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { entry in
                                HStack(spacing: 14) {
                                    IconTile(symbol: entry.state == .restored ? "arrow.uturn.backward" : "doc.text", color: entry.state == .restored ? Palette.mint : Palette.accent, size: 33)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                        Text(entry.originalURL.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                                        HStack(spacing: 7) {
                                            Text(entry.state.title)
                                            Text("·")
                                            Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                                            Text("· " + FileSize.string(entry.bytes))
                                        }.font(.system(size: 9)).foregroundStyle(entry.state == .restored ? Palette.mint : Palette.secondary)
                                        if let error = entry.error { Text(error).font(.system(size: 9)).foregroundStyle(Palette.orange).lineLimit(2) }
                                    }
                                    Spacer(minLength: 5)
                                    if entry.state == .trashed {
                                        Button("Восстановить") { model.restore(entry) }.buttonStyle(QuietButton())
                                            .disabled(model.isCleaning || model.isScanning)
                                    }
                                    Button { model.reveal(entry.state == .restored ? entry.originalURL : entry.trashURL ?? entry.originalURL) } label: {
                                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                                    }.buttonStyle(.plain).help("Показать в Finder")
                                }.padding(17)
                                Divider().overlay(Palette.line).padding(.leading, 64)
                            }
                        }
                    }
                }
            }.background(.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line)).clipShape(RoundedRectangle(cornerRadius: 16))
            Label("Очистка Корзины в Finder окончательна: после неё восстановление здесь недоступно.", systemImage: "info.circle")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.padding(.horizontal, 36).padding(.bottom, 26)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            BrandMark(size: 65)
            Text("YEETKIX — утилита для macOS").font(.system(size: 29, weight: .bold)).tracking(-0.6)
            VStack(alignment: .leading, spacing: 17) {
                feature("checkmark.shield", "Очистка только по вашему выбору", "Сначала список файлов, затем подтверждение.")
                feature("arrow.uturn.backward", "Восстановление из истории", "Файлы перемещаются в Корзину и сохраняются в журнале.")
                feature("folder.badge.gearshape", "Понятный доступ к папкам", "Защищённые папки можно подключить отдельно в Настройках.")
            }
            HStack {
                Button("Начать с обзора") { finish(.overview) }.buttonStyle(QuietButton())
                Spacer()
                Button("Настроить папки") { finish(.settings) }.buttonStyle(PrimaryButton())
            }.padding(.top, 5)
        }.padding(32).frame(width: 500).foregroundStyle(Palette.ink)
    }
    private func finish(_ destination: Destination) { model.hasSeenWelcome = true; model.showWelcome = false; model.navigate(destination) }
    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            IconTile(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
            }
        }
    }
}

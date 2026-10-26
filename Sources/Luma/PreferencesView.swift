import SwiftUI
import LumaCore

struct PreferencesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showFolders = false
    @State private var folderQuery = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                UpdatesPreferences()
                Surface {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Параметры проверки", systemImage: "checkmark.shield").font(.system(size: 15, weight: .semibold))
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Возраст кэша и журналов").font(.system(size: 12, weight: .medium))
                                Text("Старый файл — кандидат на просмотр, а не гарантия ненужности.")
                                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Picker("Возраст файлов", selection: $model.minimumAgeDays) {
                                Text("7 дней").tag(7); Text("14 дней").tag(14); Text("30 дней").tag(30)
                            }.labelsHidden().frame(width: 115).disabled(model.isScanning || model.isCleaning)
                        }
                        Text("Данные работающих приложений, базы данных, настройки, системные кэши Apple и символические ссылки защищены. Перед переносом файл проверяется повторно.")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack {
                            Label("Исключения", systemImage: "hand.raised").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Button("Добавить…") { model.addExclusion() }.buttonStyle(QuietButton()).disabled(model.isCleaning || model.isScanning)
                        }
                        Text("Выбранные файлы и папки не попадут в результаты очистки. Изменения применятся при следующем сканировании.")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                        if model.exclusions.isEmpty {
                            Text("Пользовательских исключений пока нет.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                        ForEach(model.exclusions, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(Palette.accent)
                                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { model.removeExclusion(path) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                    .disabled(model.isCleaning || model.isScanning).help("Убрать из исключений")
                            }
                        }
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Доступ к папкам", systemImage: "folder.badge.gearshape").font(.system(size: 15, weight: .semibold))
                        Text("Каждый раздел можно сканировать отдельно. Выберите защищённую папку через системное окно, если macOS ограничивает доступ. Доступ сохраняется для следующих запусков.")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                        DisclosureGroup("Папки для проверки · \(model.permissionRoots.count)", isExpanded: $showFolders) {
                            TextField("Поиск папки по имени или пути", text: $folderQuery).textFieldStyle(.roundedBorder).padding(.vertical, 8)
                            ForEach(model.permissionRoots.filter { folderQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(folderQuery) || $0.url.path.localizedCaseInsensitiveContains(folderQuery) }) { root in
                            HStack {
                                IconTile(symbol: root.category.symbol, size: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(root.title).font(.system(size: 11, weight: .medium))
                                    let result = model.report?.roots.first { $0.root.relativePath == root.relativePath }
                                    Text(result?.status.title ?? (model.grantedFolders[root.id] != nil ? "Папка подключена" : "Доступ ещё не проверен"))
                                        .font(.system(size: 9)).foregroundStyle(result?.status == .denied || result?.status == .timedOut ? Palette.orange : Palette.secondary)
                                }
                                Spacer()
                                if root.relativePath != ".Trash" {
                                    Button(model.grantedFolders[root.id] == nil ? "Подключить…" : "Выбрать снова…") { model.connectFolder(root) }
                                        .buttonStyle(QuietButton()).disabled(model.isScanning || model.isCleaning)
                                }
                            }
                            }
                        }.font(.system(size: 12))
                        Text("Для Корзины и отдельных системных ограничений может понадобиться Полный доступ к диску. Вы решаете, предоставлять ли его.")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
                        HStack {
                            Button("Открыть настройки macOS") { model.openPrivacy() }.buttonStyle(QuietButton())
                            Text("После изменения перезапустите YEETKIX").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                Surface {
                    HStack(spacing: 18) {
                        BrandMark(size: 52)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YEETKIX").font(.system(size: 21, weight: .bold, design: .rounded))
                            Text("Версия \(model.updater.version) · Локальная сборка").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            Text("Все операции выполняются на вашем Mac.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            Text("Разработано с помощью ИИ — OpenAI Codex.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            Button("Руководство") { model.showHelp = true }.buttonStyle(QuietButton())
                        }
                        Spacer()
                    }
                }
            }.padding(.horizontal, 36).padding(.bottom, 30)
        }.scrollIndicators(.hidden)
    }
}

import SwiftUI
import AppKit
import LumaCore

struct FileBrowserView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            if let error = model.historyError {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.orange).padding(12)
            }
            if model.isCleaning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Перемещаем: " + model.operationProgress).font(.system(size: 12))
                    Spacer()
                    Button("Остановить") { model.cancelCleanup() }.buttonStyle(QuietButton())
                }
            }
            if model.destination == .cleanup { categoryCards }
            else { collectionSummary }
            if let report = model.report, !report.inaccessible.isEmpty || report.truncated || report.isPartial || report.roots.contains(where: { $0.status == .protected }) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(report.truncated ? "Достигнут лимит. Показана проверенная часть файлов." : !report.inaccessible.isEmpty ? "Не все папки доступны. Показаны частичные результаты." : report.roots.contains(where: { $0.status == .protected }) ? "Часть данных защищена: используются приложением или находятся в исключениях." : "Показаны результаты проверенных папок.")
                        .lineLimit(2)
                    Spacer()
                    Button("Подробнее") { model.showScanDetails() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
                .font(.system(size: 10.5)).foregroundStyle(Palette.secondary)
                .padding(12).background(Palette.lavender.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(spacing: 0) {
                listToolbar
                Rectangle().fill(Palette.line).frame(height: 1)
                if model.visibleItems.isEmpty {
                    VStack(spacing: 12) {
                        IconTile(symbol: model.query.isEmpty && accessLimited ? "folder.badge.questionmark" : model.query.isEmpty ? "checkmark" : "magnifyingglass", color: Palette.mint, size: 55)
                        Text(!model.query.isEmpty ? "Ничего не найдено" : accessLimited ? "Проверьте доступ к папкам" : "Подходящих файлов нет").font(.system(size: 18, weight: .semibold))
                        Text(model.query.isEmpty ? emptyMessage : "Попробуйте другое имя или часть пути.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                        if accessLimited && model.query.isEmpty { Button("Настроить доступ") { model.navigate(.settings) }.buttonStyle(QuietButton()) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.visibleItems) { item in
                                FileRow(item: item)
                                Rectangle().fill(Palette.line.opacity(0.7)).frame(height: 1).padding(.leading, 65)
                            }
                        }
                    }
                }
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            bottomBar
        }
        .padding(.horizontal, 36).padding(.bottom, 26)
    }

    private var categoryCards: some View {
        HStack(spacing: 14) {
            ForEach([FileCategory.cache, .logs, .toolCaches]) { category in
                let items = model.report?.items(for: category) ?? []
                let active = model.cleanupFilter == category
                Button {
                    model.cleanupFilter = active ? nil : category
                    model.selection.removeAll()
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            IconTile(symbol: category.symbol, color: category == .cache ? Palette.accent : Palette.blue, size: 32)
                            Spacer(minLength: 4)
                            Text(FileSize.string(items.reduce(0) { $0 + $1.bytes })).font(.system(size: 19, weight: .semibold)).tracking(-0.4)
                        }
                        Text(category.title).font(.system(size: 12, weight: .semibold))
                        Text("Файлов: \(items.count) · от \(model.report?.ageDays ?? model.minimumAgeDays) дн.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(active ? Palette.lavender : .white, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(active ? Palette.accent.opacity(0.4) : Palette.line))
                }.buttonStyle(.plain)
            }
        }
    }

    private var collectionSummary: some View {
        HStack(spacing: 16) {
            IconTile(symbol: model.destination.symbol, color: model.destination == .trash ? Palette.mint : Palette.orange, size: 54)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.destination == .trash ? "Содержимое Корзины" : model.destination == .leftovers ? "Остатки приложений" : model.destination == .developer ? "Данные Xcode" : FileSize.string(model.totalVisibleBytes))
                    .font(.system(size: 25, weight: .bold)).tracking(-0.5)
                Text(summaryText)
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Spacer()
        }.padding(21).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.lavender.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
    }

    private var summaryText: String {
        switch model.destination {
        case .large: return "Файлы от 100 МБ в Загрузках, Документах, Фильмах и на Рабочем столе"
        case .trash: return "Файлы, перемещённые приложением, можно вернуть через Историю."
        case .leftovers: return "Предполагаемые остатки по идентификатору приложения. Здесь могут быть нужные настройки и данные — проверьте список."
        case .developer: return "Сборки, индексы, кэш и старые символы устройств. Архивы релизов и исходники не предлагаются."
        case .toolCaches: return "npm, pnpm, pip, Yarn, Homebrew и архивы Cargo. Только старые файлы; конфигурация, исходники и данные работающих инструментов защищены. Кэш uv очищается его штатной командой."
        default: return "Файлы из папки Загрузки. Проверьте их перед удалением."
        }
    }
    private var listToolbar: some View {
        HStack(spacing: 12) {
            if model.destination != .trash {
                Button { model.toggleVisible() } label: {
                    let all = !model.visibleItems.isEmpty && Set(model.visibleItems.map(\.id)).isSubset(of: model.selection)
                    Image(systemName: all ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16)).foregroundStyle(all ? Palette.accent : Palette.secondary.opacity(0.55))
                }.buttonStyle(.plain).help("Выбрать все видимые файлы").accessibilityLabel("Выбрать все файлы")
            }
            Text("Файлы · \(model.visibleItems.count)").font(.system(size: 11, weight: .medium))
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                TextField("Поиск файлов", text: $model.query).textFieldStyle(.plain).font(.system(size: 11))
            }
            .padding(.horizontal, 10).frame(width: 175, height: 29).background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
            Menu {
                Button("Сначала большие") { model.sortByDate = false }
                Button("Сначала старые") { model.sortByDate = true }
            } label: {
                Label(model.sortByDate ? "По дате" : "По размеру", systemImage: "arrow.up.arrow.down").font(.system(size: 10))
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(Palette.secondary)
        }.padding(.horizontal, 17).frame(height: 54)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                if model.destination == .trash {
                    Text("Файлы в системной Корзине").font(.system(size: 12, weight: .medium))
                    Text("Размер папок в Корзине не подсчитывается.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                } else {
                    Text(model.selectedItems.isEmpty ? "Выберите файлы для очистки" : "Выбрано: \(model.selectedItems.count) · \(FileSize.string(model.selectedBytes))")
                        .font(.system(size: 12, weight: .medium))
                    Text(model.destination == .cleanup ? "Возраст файла не гарантирует ненужность. Проверьте список." : "Выбранные файлы будут перемещены в Корзину.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }
            Spacer()
            Button("Отчёт…") { model.showScanDetails() }.buttonStyle(QuietButton()).disabled(model.isCleaning)
            Button { model.startScan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(QuietButton()).help("Сканировать заново").disabled(model.isCleaning)
            if model.destination == .trash {
                Button("Открыть в Finder") { model.openTrash() }.buttonStyle(PrimaryButton())
            } else {
                Button { model.showConfirmation = true } label: {
                    HStack(spacing: 7) {
                        if model.isCleaning { ProgressView().controlSize(.small) } else { Image(systemName: "trash") }
                        Text(model.isCleaning ? "Перемещаем…" : "В Корзину")
                    }
                }.buttonStyle(PrimaryButton()).disabled(model.selectedItems.isEmpty || model.isCleaning || !model.historyReady)
                    .accessibilityIdentifier("trash-selection")
            }
        }
    }
    private var emptyMessage: String {
        if model.destination == .developer && model.developerBusy { return "Xcode или процесс сборки сейчас работает. Завершите его и повторите сканирование." }
        if accessLimited { return "Некоторые папки не удалось проверить. Это не означает, что они пусты." }
        if model.destination == .cleanup { return "Старых файлов для очистки в доступных папках не найдено." }
        if model.destination == .trash { return "В доступной части Корзины файлов не найдено." }
        return "В доступных папках подходящих файлов не найдено."
    }
    private var accessLimited: Bool { model.report?.roots.contains { $0.status == .denied || $0.status == .timedOut || $0.status == .cancelled } == true }
}

struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let item: FileItem
    var body: some View {
        HStack(spacing: 12) {
            if model.destination != .trash {
                Button { model.toggle(item) } label: {
                    Image(systemName: model.selection.contains(item.id) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16)).foregroundStyle(model.selection.contains(item.id) ? Palette.accent : Palette.secondary.opacity(0.4))
                }.buttonStyle(.plain).accessibilityLabel("Выбрать \(item.name)").disabled(model.isCleaning || item.duplicateEvidence?.keeperURL.standardizedFileURL == item.url.standardizedFileURL)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().interpolation(.high).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let bundleID = item.leftoverBundleID {
                    Text(bundleID + " · приложение не найдено").font(.system(size: 9)).foregroundStyle(Palette.orange).lineLimit(1)
                }
                if item.orphanEvidence?.containsPersonalData == true { Text("Может содержать документы или виртуальные машины").font(.system(size: 9)).foregroundStyle(Palette.orange).lineLimit(1) }
                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9.5)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Text(item.modified, format: .dateTime.day().month(.abbreviated).year()).font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(width: 95, alignment: .trailing)
            Text(item.category == .trash && item.isDirectory ? "Папка" : FileSize.string(item.bytes)).font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button { model.reveal(item.url) } label: { Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                .buttonStyle(.plain).help("Показать в Finder").accessibilityLabel("Показать \(item.name) в Finder").padding(.leading, 5)
        }
        .padding(.horizontal, 17).frame(height: item.orphanEvidence?.containsPersonalData == true ? 94 : item.leftoverBundleID == nil ? 65 : 78)
        .background(model.selection.contains(item.id) ? Palette.lavender.opacity(0.28) : .clear)
        .contextMenu {
            Button("Показать в Finder") { model.reveal(item.url) }
            Button("Исключить из очистки") { model.exclude(item.url) }.disabled(model.isCleaning)
            Button("Скопировать путь") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.path, forType: .string) }
        }
    }
}

struct TrashConfirmationView: View {
    @EnvironmentObject var model: AppModel
    @State private var acknowledgeData = false
    private var hasDocuments: Bool { model.selectedItems.contains { $0.orphanEvidence?.containsPersonalData == true } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            IconTile(symbol: "trash", color: Palette.accent, size: 54)
            VStack(alignment: .leading, spacing: 9) {
                Text("Переместить в Корзину?").font(.system(size: 23, weight: .bold))
                Text("Файлов: \(model.selectedItems.count) · \(FileSize.string(model.selectedBytes))")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                Text("Файлы можно будет вернуть через «Историю очистки». Для освобождения места Корзину нужно очистить отдельно в Finder.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.selectedItems.prefix(5))) { item in
                    Label(item.name, systemImage: "doc").font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                }
                if model.selectedItems.count > 5 { Text("И ещё \(model.selectedItems.count - 5) файлов").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
            if hasDocuments { Toggle("Я понимаю, что в остатках могут быть личные документы и виртуальные машины.", isOn: $acknowledgeData).font(.system(size: 12)).foregroundStyle(Palette.orange) }
            HStack {
                Spacer()
                Button("Отмена") { model.showConfirmation = false }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("Переместить") { model.moveSelectionToTrash() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).disabled(hasDocuments && !acknowledgeData)
            }
        }.padding(30).frame(width: 460).foregroundStyle(Palette.ink)
    }
}

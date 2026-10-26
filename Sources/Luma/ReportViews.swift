import SwiftUI
import AppKit
import LumaCore

struct ScanReportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var onlyProblems = false
    private var roots: [RootResult] {
        (model.report?.roots ?? []).filter {
            (!onlyProblems || ![.complete, .missing].contains($0.status)) &&
            (query.isEmpty || $0.root.title.localizedCaseInsensitiveContains(query) || $0.root.url.path.localizedCaseInsensitiveContains(query) || $0.status.title.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Отчёт о сканировании").font(.system(size: 23, weight: .semibold))
                    if let report = model.report {
                        Text(report.scope.title + " · " + report.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        Text("Папок в отчёте: \(report.roots.count) · Проверено объектов: \(report.visitedCount) · Защищено: \(report.protectedCount)")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Поиск по пути или статусу", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Только ограничения", isOn: $onlyProblems).toggleStyle(.checkbox).font(.system(size: 11))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(roots) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.root.title).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(entry.status.title).font(.system(size: 10, weight: .medium))
                                    .foregroundStyle([.denied, .timedOut, .limited, .cancelled].contains(entry.status) ? Palette.orange : entry.status == .complete ? Palette.mint : Palette.secondary)
                            }
                            Text(entry.root.url.path).font(.system(size: 10)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                            if let detail = entry.detail { Text(detail).font(.system(size: 10)).foregroundStyle(Palette.secondary).textSelection(.enabled) }
                        }.padding(.vertical, 12)
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 14).background(.white, in: RoundedRectangle(cornerRadius: 12))
            Text("Неотвечающие, недоступные и непроверенные папки не считаются пустыми. Отчёт содержит локальные пути; перед публикацией проверьте его содержимое.")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            HStack {
                Button("Настройки доступа") { dismiss(); model.navigate(.settings) }.buttonStyle(QuietButton())
                Spacer()
                Button("Сохранить JSON…") { model.exportScanReport() }.buttonStyle(PrimaryButton()).disabled(model.isScanning || model.isCleaning)
            }
        }.padding(26).frame(width: 760, height: 610).background(Palette.background).foregroundStyle(Palette.ink)
    }
}

struct HelpView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let sections: [(String, String)] = [
        ("Проверка и перенос", "Выберите раздел и запустите сканирование. Просмотрите найденные пути, отметьте ненужное и подтвердите перенос в Корзину. Сканирование само по себе ничего не удаляет."),
        ("Восстановление", "Откройте «История очистки» и нажмите «Восстановить». Существующие файлы не перезаписываются. Изменённые объекты и конфликты нужно проверить в Finder. После окончательной очистки Корзины восстановление здесь недоступно."),
        ("Доступ к папкам", "Недоступная папка не означает пустую папку. Подробности видны в «Отчёт…». В настройках можно подключить точную папку. Отдельными разрешениями управляет macOS в разделе конфиденциальности; после их изменения перезапустите приложение."),
        ("Приложения и виртуальные машины", "В разделе «Приложения» связанные данные выбираются отдельно. VM UTM показываются целыми пакетами и не отмечаются автоматически. Для другого места хранения используйте выбор папки с .utm или «Добавить файл или папку…»."),
        ("Что защищено", "Исключения, данные работающих приложений и инструментов, системные кэши, ключи, неизвестные общие данные и ссылки защищаются. Возраст файла не гарантирует ненужность. Произвольные документы любого приложения автоматически распознать нельзя."),
        ("Место на диске", "Перенос в Корзину не освобождает место до её очистки в Finder. Размеры логические: APFS-клоны и разреженные виртуальные диски могут занимать физически меньше места."),
        ("Docker и симуляторы", "Эти действия выполняются штатными инструментами, могут быть необратимыми и требуют отдельного подтверждения. Docker volumes не очищаются. Нужны работающий локальный Docker или полный Xcode соответственно."),
        ("Отчёты и данные приложения", "Отчёт JSON сохраняется только в выбранный вами файл и содержит локальные пути. История лежит в ~/Library/Application Support/local.luma.cleaner/. Исключения и параметры хранятся локально через UserDefaults."),
        ("О проекте", "YEETKIX — утилита для macOS на Apple Silicon. Проект разработан с помощью ИИ — OpenAI Codex. В текущей локальной сборке нет настроенного канала автоматических обновлений.")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Руководство YEETKIX").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sections, id: \.0) { title, body in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(title).font(.system(size: 14, weight: .semibold))
                            Text(body).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let guide = Bundle.main.url(forResource: "GUIDE", withExtension: "md") {
                    Button("Открыть полную инструкцию") { NSWorkspace.shared.open(guide) }.buttonStyle(QuietButton())
                }
                Spacer()
                Link("Репозиторий проекта", destination: URL(string: "https://github.com/AncherbakNA/yeetkix")!).font(.system(size: 12))
            }
        }.padding(28).frame(width: 720, height: 630).background(Palette.background).foregroundStyle(Palette.ink)
    }
}

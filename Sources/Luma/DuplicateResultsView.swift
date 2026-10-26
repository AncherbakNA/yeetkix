import SwiftUI
import LumaCore

struct DuplicateResultsView: View {
    @EnvironmentObject var model: AppModel
    private var groups: [DuplicateGroup] {
        guard !model.query.isEmpty else { return model.duplicateGroups }
        return model.duplicateGroups.filter { $0.files.contains { $0.name.localizedCaseInsensitiveContains(model.query) || $0.url.path.localizedCaseInsensitiveContains(model.query) } }
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                IconTile(symbol: "doc.on.doc", color: Palette.accent, size: 50)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Дубликаты файлов").font(.system(size: 24, weight: .bold)).tracking(-0.5)
                    Text("Групп: \(model.duplicateGroups.count) · Копий для просмотра: \(FileSize.string(model.duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }))")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Text("Содержимое проверено целиком. Одну копию в каждой группе сохраняем.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Spacer()
            }.padding(21).background(Palette.lavender.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
            if let report = model.report, !report.inaccessible.isEmpty || report.isPartial || report.truncated {
                HStack {
                    Label("Проверены доступные файлы. Часть данных могла быть пропущена.", systemImage: "info.circle").font(.system(size: 10))
                    Spacer()
                    Button("Подробнее") { model.showScanDetails() }.buttonStyle(.plain).foregroundStyle(Palette.accent).font(.system(size: 10))
                }.foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 12) {
                Button("Выбрать копии") { model.selectDuplicateCopies(groups) }.buttonStyle(QuietButton()).disabled(model.isCleaning || groups.isEmpty)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                TextField("Поиск в группах", text: $model.query).textFieldStyle(.plain).font(.system(size: 11)).frame(width: 230)
            }
            if groups.isEmpty {
                VStack(spacing: 13) {
                    IconTile(symbol: "doc.on.doc", color: Palette.mint, size: 58)
                    Text(model.query.isEmpty ? "Повторов среди проверенных файлов нет" : "Группы не найдены").font(.system(size: 18, weight: .semibold))
                    Text("Облачные файлы без локальной копии и недоступные папки не сравниваются.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(groups) { group in
                            VStack(spacing: 0) {
                                HStack {
                                    Text(group.files.first?.name ?? "Группа").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text("\(group.files.count) копии · по \(FileSize.string(group.files.first?.bytes ?? 0))").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                                }.padding(15)
                                ForEach(group.files) { item in
                                    Divider().overlay(Palette.line)
                                    HStack(spacing: 8) {
                                        FileRow(item: item)
                                        if item.duplicateEvidence?.keeperURL.standardizedFileURL == item.url.standardizedFileURL {
                                            Label("Сохраняем", systemImage: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.mint).frame(width: 105)
                                        } else {
                                            Button("Оставить эту") { model.keepDuplicate(item, groupID: group.id) }.buttonStyle(QuietButton()).disabled(model.isCleaning)
                                        }
                                    }.padding(.trailing, 14)
                                }
                            }.background(.white, in: RoundedRectangle(cornerRadius: 15))
                                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line)).clipShape(RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.isCleaning ? "Перемещаем: " + model.operationProgress : "Выбрано: \(model.selectedItems.count) · \(FileSize.string(model.selectedBytes))")
                        .font(.system(size: 12, weight: .medium))
                    Text("Перед переносом совпадение проверяется повторно.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if model.isCleaning {
                    Button("Остановить") { model.cancelCleanup() }.buttonStyle(QuietButton())
                } else {
                    Button("Отчёт…") { model.showScanDetails() }.buttonStyle(QuietButton())
                    Button { model.startScan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(QuietButton())
                    Button("В Корзину") { model.showConfirmation = true }.buttonStyle(PrimaryButton())
                        .disabled(model.selectedItems.isEmpty || !model.historyReady)
                }
            }
        }.padding(.horizontal, 36).padding(.bottom, 26)
    }
}

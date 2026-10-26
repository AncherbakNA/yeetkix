import SwiftUI
import LumaCore

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(spacing: 15) {
                hero
                HStack(alignment: .top, spacing: 18) {
                    storageCard.frame(maxWidth: .infinity)
                    deviceCard.frame(width: 248)
                }
                VStack(spacing: 14) {
                    SectionHeading(title: "Разделы проверки")
                    HStack(spacing: 14) {
                        toolCard(.duplicates, symbol: "doc.on.doc.fill", color: Palette.orange, text: "Сравнение содержимого\nи выбор сохраняемой копии.")
                        toolCard(.leftovers, symbol: "app.badge", color: Palette.blue, text: "Данные удалённых\nприложений.")
                        toolCard(.developer, symbol: "hammer.fill", color: Palette.mint, text: "Сгенерированные сборки,\nиндексы и кэши.")
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield").font(.system(size: 11))
                    Text("Файлы переносятся в Корзину только после подтверждения.").font(.system(size: 10))
                    Spacer()
                    Text("ARM64 · macOS 14+").font(.system(size: 10))
                }.foregroundStyle(Palette.secondary).padding(.top, 2)
            }
            .padding(.horizontal, 36).padding(.bottom, 18)
        }.scrollIndicators(.hidden)
    }

    private var hero: some View {
        Surface(padding: 24) {
            HStack(spacing: 24) {
                IconTile(symbol: "externaldrive.badge.magnifyingglass", size: 76)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Проверка диска").font(.system(size: 26, weight: .semibold))
                    Text("Поиск старых кэшей, дубликатов и связанных данных приложений.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    if let report = model.report {
                        Text("Последняя проверка: " + report.scope.title + " · " + report.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        Text(report.isPartial || report.truncated ? "Результат частичный. Подробности доступны в отчёте." : "Найдено объектов: \(report.items.count). Подробности доступны в отчёте.")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                    HStack(spacing: 12) {
                        Button { model.isScanning ? model.navigate(.cleanup) : model.startScan() } label: {
                            Label(model.isScanning ? "Идёт сканирование" : "Сканировать Mac", systemImage: "magnifyingglass")
                        }.buttonStyle(PrimaryButton()).accessibilityIdentifier("start-scan")
                        if model.report != nil && !model.isScanning {
                            Button("Отчёт…") { model.showScanDetails() }.buttonStyle(QuietButton())
                        }
                    }.padding(.top, 6)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var storageCard: some View {
        Surface(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Image(systemName: "internaldrive").font(.system(size: 15)).foregroundStyle(Palette.secondary)
                    Text(model.disk.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("SSD").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 4).background(Palette.background, in: RoundedRectangle(cornerRadius: 5))
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(FileSize.string(model.disk.available)).font(.system(size: 28, weight: .bold)).tracking(-0.8)
                    Text("свободно").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.line)
                        Capsule().fill(LinearGradient(colors: [Color(hex: 0xA993E9), Palette.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geometry.size.width * model.disk.usedFraction))
                    }
                }.frame(height: 9)
                HStack {
                    legend("Занято " + FileSize.string(model.disk.used), color: Palette.accent)
                    Spacer()
                    Text("из " + FileSize.string(model.disk.total)).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }.frame(height: 134, alignment: .top)
        }.frame(height: 174)
    }

    private var deviceCard: some View {
        Surface(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Ваш Mac").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "laptopcomputer").font(.system(size: 16)).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 9) {
                    Circle().fill(Palette.mint).frame(width: 6, height: 6)
                    Text("Apple Silicon · ARM64").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.mint)
                }
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ПАМЯТЬ").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(Palette.secondary)
                        Text(model.memory).font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("СИСТЕМА").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(Palette.secondary)
                        Text(model.systemVersion).font(.system(size: 12, weight: .medium))
                    }
                }
            }.frame(height: 134, alignment: .top)
        }.frame(height: 174)
    }

    private func toolCard(_ destination: Destination, symbol: String, color: Color, text: String) -> some View {
        Button { model.navigate(destination) } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack { IconTile(symbol: symbol, color: color, size: 35); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Palette.secondary.opacity(0.6)) }
                VStack(alignment: .leading, spacing: 7) {
                    Text(destination.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(text).font(.system(size: 10.5)).lineSpacing(4).foregroundStyle(Palette.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func legend(_ label: String, color: Color) -> some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 5, height: 5); Text(label).font(.system(size: 10)).foregroundStyle(Palette.secondary) }
    }
}

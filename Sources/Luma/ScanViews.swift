import SwiftUI

struct ScanWelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            IconTile(symbol: model.destination.symbol, size: 96).padding(.vertical, 42)
            Text("Проверка файлов").font(.system(size: 28, weight: .bold)).tracking(-0.6).padding(.top, 8)
            Text("Будут проверены доступные папки выбранного раздела.\nЗатем вы сами выберете файлы для очистки.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).lineSpacing(6).padding(.top, 13)
            Button { model.startScan() } label: { Label("Проверить: " + (model.destination.scope?.title ?? "Mac"), systemImage: "sparkle.magnifyingglass") }
                .buttonStyle(PrimaryButton()).padding(.top, 27)
            Label("Ничего не удаляется автоматически", systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 19)
            Spacer(minLength: 30)
        }.frame(maxWidth: .infinity).padding(.top, 15)
    }
}

struct ScanProgressView: View {
    @EnvironmentObject var model: AppModel
    @State private var rotating = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(Palette.lavender, lineWidth: 2).frame(width: 204, height: 204)
                Circle().trim(from: 0, to: 0.22).stroke(Palette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 204, height: 204).rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 4).repeatForever(autoreverses: false), value: rotating)
                BrandMark(size: 96)
                Circle().fill(Palette.mint).frame(width: 12, height: 12).overlay(Circle().stroke(Palette.background, lineWidth: 3)).offset(x: 82, y: 61)
            }.padding(.bottom, 37)
            Text("Сканирование").font(.system(size: 27, weight: .bold)).tracking(-0.5)
            Text("Проверяем: " + model.scanLocation).font(.system(size: 13)).foregroundStyle(Palette.secondary).padding(.top, 12)
            ProgressView(value: model.progress).tint(Palette.accent).frame(width: 320).padding(.top, 28)
            HStack {
                Text("Проверено объектов: \(model.visited.formatted())")
                Spacer()
                Text("\(Int(model.progress * 100)) %").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(width: 320).padding(.top, 10)
            HStack(spacing: 10) {
                Button("Пропустить папку") { model.skipFolder() }.buttonStyle(QuietButton())
                Button("Остановить") { model.cancelScan() }.buttonStyle(QuietButton())
            }.padding(.top, 30)
            Label("Ваши файлы остаются на месте", systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 25)
            Text("При остановке результаты проверенных папок сохранятся.")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 8)
            Text("Неотвечающие папки пропускаются автоматически.")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 60)
            .onAppear { rotating = true }
    }
}

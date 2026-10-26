import SwiftUI

enum Palette {
    static let background = Color(hex: 0xF8F9FC)
    static let sidebar = Color(hex: 0xF0F1F7)
    static let ink = Color(hex: 0x25243B)
    static let secondary = Color(hex: 0x8B8B9F)
    static let accent = Color(hex: 0x7760DB)
    static let lavender = Color(hex: 0xEDE8FC)
    static let line = Color(hex: 0xEAEBF2)
    static let mint = Color(hex: 0x62B19B)
    static let orange = Color(hex: 0xECA76B)
    static let blue = Color(hex: 0x729BE7)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

struct Surface<Content: View>: View {
    var padding: CGFloat = 24
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).background(.white, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line, lineWidth: 1))
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).frame(height: 43)
            .background(Palette.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 11))
            .shadow(color: Palette.accent.opacity(enabled ? 0.18 : 0), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            .padding(.horizontal, 14).frame(height: 34)
            .background(configuration.isPressed ? Palette.line : .white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
    }
}

struct IconTile: View {
    let symbol: String
    var color = Palette.accent
    var size: CGFloat = 42
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(color).frame(width: size, height: size)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

struct BrandMark: View {
    var size: CGFloat = 38
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29)
                .fill(LinearGradient(colors: [Color(hex: 0xA18AF2), Palette.accent, Color(hex: 0x6950C8)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "bolt.fill").font(.system(size: size * 0.61, weight: .medium))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-8))
        }.frame(width: size, height: size)
            .shadow(color: Palette.accent.opacity(0.22), radius: 8, y: 4)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.secondary)
    }
}

struct SectionHeading: View {
    let title: String
    var caption: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
        }
    }
}

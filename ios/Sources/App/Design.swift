import SwiftUI

extension Color {
    static let paper = Color("neutral50")
    static let ink = Color("neutral900")
    static let lavender = Color("buttonPurple")
}
struct ParlaMark: View {
    var size: CGFloat = 30
    var body: some View {
        HStack(spacing: size * 0.16) {
            // The desktop Parla waveform (Scripts/make_icon.sh), tinted like the wordmark.
            Image("ParlaLogo").renderingMode(.template).resizable().scaledToFit().frame(height: size)
            Text("Parla").font(.custom("Manrope-ExtraLight", size: size).weight(.bold))
        }.foregroundStyle(Color.ink).accessibilityElement(children: .ignore).accessibilityLabel("Parla")
    }
}
struct ParlaButtonStyle: ButtonStyle {
    var dark = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.custom("Figtree-Light", size: 17).weight(.semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(dark ? Color.ink : Color.lavender).foregroundStyle(dark ? .white : Color.ink)
            .clipShape(RoundedRectangle(cornerRadius: 18)).opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct EmptyCard: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundStyle(Color("primary500"))
            Text(title).font(.custom("EBGaramond-Regular", size: 30))
            Text(detail).font(.custom("Figtree-Light", size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(30).background(.white).clipShape(RoundedRectangle(cornerRadius: 24))
    }
}
struct Waveform: View {
    let active: Bool
    var body: some View {
        // State indicator, not a claimed audio amplitude visualization.
        HStack(spacing: 5) {
            ForEach(Array([12.0, 22, 32, 20, 42, 28, 18, 34, 24, 12].enumerated()), id: \.offset) { _, height in
                Capsule().frame(width: 5, height: active ? height : 7)
            }
        }.frame(height: 48).accessibilityHidden(true)
    }
}

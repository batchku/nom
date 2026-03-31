import SwiftUI

struct HUDView: View {
    let spaceIndex: Int
    let spaceName: String

    var body: some View {
        HStack(spacing: 16) {
            Text("\(spaceIndex)")
                .font(.system(size: 52, weight: .thin, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))

            Circle()
                .fill(.white.opacity(0.2))
                .frame(width: 6, height: 6)

            Text(spaceName)
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 48)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(white: 0.12))
        }
    }
}

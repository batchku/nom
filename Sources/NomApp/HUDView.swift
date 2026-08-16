import SwiftUI

struct HUDView: View {
    /// nil while a switch is in flight and the destination isn't known yet.
    let spaceIndex: Int?
    let spaceName: String

    var body: some View {
        HStack(spacing: 16) {
            if let spaceIndex {
                Text("\(spaceIndex)")
                    .font(.system(size: 52, weight: .thin, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))

                Circle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 6, height: 6)
            }

            Text(spaceName)
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(spaceIndex == nil ? 0.5 : 0.95))
                .lineLimit(1)
                // Only engages when the panel hits its screen-width cap.
                .minimumScaleFactor(0.4)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 48)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(white: 0.12))
        }
    }
}

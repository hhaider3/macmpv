import SwiftUI

struct SeekPreviewPopover: View {
    let preview: SeekPreviewModel
    let seconds: Double

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = preview.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else if preview.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(height: 108)

            Text(seconds.playbackTime)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .frame(width: 192)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

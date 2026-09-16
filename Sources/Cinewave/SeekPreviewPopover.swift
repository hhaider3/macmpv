import SwiftUI

struct SeekPreviewPopover: View {
    let preview: SeekPreviewModel
    let seconds: Double

    var width: CGFloat { preview.image == nil ? 76 : 192 }
    var height: CGFloat { preview.image == nil ? 28 : 136 }

    var body: some View {
        VStack(spacing: 0) {
            if let image = preview.image {
                ZStack {
                    Color.black
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                }
                .frame(height: 108)
            }

            // A retained frame keeps its own time until the next one is ready.
            Text((preview.imageSecond ?? seconds).playbackTime)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
        }
        .frame(width: width)
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

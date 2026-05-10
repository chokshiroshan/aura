import SwiftUI
import AppKit

/// Renders the current `MemeReactionEngine.Reaction` as an emerging cat
/// image, positioned off-center along the reaction's emergence angle.
struct CatReactionOverlay: View {
    @ObservedObject var engine: MemeReactionEngine

    var body: some View {
        ZStack {
            if let reaction = engine.current {
                ReactionImageView(reaction: reaction)
                    .id(reaction.id)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0).combined(with: .opacity),
                        removal: .scale(scale: 0.85).combined(with: .opacity)
                    ))
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.32, dampingFraction: 0.55), value: engine.current?.id)
    }
}

private struct ReactionImageView: View {
    let reaction: MemeReactionEngine.Reaction

    @State private var offset: CGFloat = 0
    @State private var rotation: Double = Double.random(in: -6...6)

    private let imageSize: CGFloat = 88
    private let emergeRadius: CGFloat = 26
    private let driftDistance: CGFloat = 6

    var body: some View {
        let dx = cos(reaction.angle) * emergeRadius
        let dy = -sin(reaction.angle) * emergeRadius  // SwiftUI y is flipped
        let driftX = cos(reaction.angle) * driftDistance * offset
        let driftY = -sin(reaction.angle) * driftDistance * offset

        AssetImage(url: reaction.imageURL)
            .frame(width: imageSize, height: imageSize)
            .rotationEffect(.degrees(rotation))
            .offset(x: dx + driftX, y: dy + driftY)
            .onAppear {
                withAnimation(.easeOut(duration: 0.22)) { offset = 1 }
            }
    }
}

/// Loads a still image (PNG/JPG) via SwiftUI, or wraps `NSImageView` for
/// animated GIFs (NSImage handles GIF animation natively).
private struct AssetImage: View {
    let url: URL

    var body: some View {
        if url.pathExtension.lowercased() == "gif" {
            AnimatedNSImageView(url: url)
        } else if let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
        } else {
            // Asset missing — render an empty box rather than crashing
            Color.clear
        }
    }
}

private struct AnimatedNSImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        if let img = NSImage(contentsOf: url) {
            view.image = img
        }
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image == nil, let img = NSImage(contentsOf: url) {
            nsView.image = img
        }
    }
}

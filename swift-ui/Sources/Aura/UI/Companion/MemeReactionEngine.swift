import Foundation
import SwiftUI

/// Picks bundled cat-meme assets and publishes a short-lived `Reaction`
/// for the overlay view to render. Enforces a 1.5s cooldown so error storms
/// don't spam the user.
@MainActor
final class MemeReactionEngine: ObservableObject {
    enum Category: String, CaseIterable {
        case success, error, startled, bored
    }

    struct Reaction: Identifiable, Equatable {
        let id = UUID()
        let imageURL: URL
        let category: Category
        let angle: Double  // emergence angle in radians, upper hemisphere
    }

    @Published private(set) var current: Reaction?

    private var lastFireDate: Date?
    private var clearTask: Task<Void, Never>?
    private var lastImageURLByCategory: [Category: URL] = [:]
    private let cooldown: TimeInterval = 1.5
    private let displayDuration: TimeInterval = 1.6

    /// Try to fire a reaction. Returns silently if on cooldown or no asset.
    func fire(_ category: Category) {
        if let last = lastFireDate, Date().timeIntervalSince(last) < cooldown {
            return
        }
        guard let url = pickURL(for: category) else { return }

        lastFireDate = Date()
        lastImageURLByCategory[category] = url

        // Random angle on the upper hemisphere: -45° to 225° (i.e. above the
        // nucleus, biased so the meme reads like a thought bubble).
        let angle = Double.random(in: -.pi / 4 ... 5 * .pi / 4)

        clearTask?.cancel()
        current = Reaction(imageURL: url, category: category, angle: angle)

        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.displayDuration ?? 1.6) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.current = nil }
        }
    }

    private func pickURL(for category: Category) -> URL? {
        let urls = assetURLs(for: category)
        guard !urls.isEmpty else { return nil }
        if urls.count == 1 { return urls[0] }
        // Avoid repeating the same image twice in a row.
        let last = lastImageURLByCategory[category]
        let candidates = urls.filter { $0 != last }
        return candidates.randomElement() ?? urls.randomElement()
    }

    private func assetURLs(for category: Category) -> [URL] {
        let folder = "CatMemes/\(category.rawValue)"
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.resourceURL?.appendingPathComponent("Aura_Aura.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Aura_Aura.bundle")
        ].compactMap { $0 }

        for root in roots {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }
            let found = urls
                .filter { ["png", "gif", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !found.isEmpty { return found }
        }

        return []
    }
}

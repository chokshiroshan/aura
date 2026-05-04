import AppKit
import Foundation

/// Builds the prompt context used by the direct Realtime fallback path.
final class ContextManager {
    static let shared = ContextManager()

    private init() {}

    func buildInstructions(config: FlowConfig) -> String {
        var sections = [config.systemInstructions]

        let userContext = config.userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userContext.isEmpty {
            sections.append("User context:\n\(userContext)")
        }

        if config.includeAppContext,
           let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName {
            sections.append("Active app: \(activeApp)")
        }

        if config.includeVocabulary,
           let vocabulary = loadVocabulary(),
           !vocabulary.isEmpty {
            sections.append("Vocabulary:\n\(vocabulary)")
        }

        return sections.joined(separator: "\n\n")
    }

    private func loadVocabulary() -> String? {
        let url = FlowConfig.configDir.appendingPathComponent("vocabulary.json")
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let value = try? JSONSerialization.jsonObject(with: data),
           let summary = summarizeVocabulary(value) {
            return summary
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func summarizeVocabulary(_ value: Any) -> String? {
        if let terms = value as? [String] {
            return terms.joined(separator: ", ")
        }

        if let dict = value as? [String: Any] {
            return dict.keys.sorted().compactMap { key in
                guard let value = dict[key],
                      let formatted = summarizeVocabulary(value) ?? scalarDescription(value) else {
                    return nil
                }
                return "\(key): \(formatted)"
            }
            .joined(separator: "\n")
        }

        if let values = value as? [Any] {
            return values.compactMap { summarizeVocabulary($0) ?? scalarDescription($0) }
                .joined(separator: ", ")
        }

        return scalarDescription(value)
    }

    private func scalarDescription(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

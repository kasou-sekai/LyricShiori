import Foundation

struct LyricsFilter {
    var enabled: Bool
    var smartFilterEnabled: Bool
    var blockedPatterns: [String]

    func apply(to document: LyricsDocument) -> LyricsDocument {
        guard enabled else { return document }
        var copy = document
        copy.lines = document.lines.filter { line in
            let trimmed = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if smartFilterEnabled, trimmed.count == 1, CharacterSet.punctuationCharacters.isSuperset(of: CharacterSet(charactersIn: trimmed)) {
                return false
            }
            for pattern in blockedPatterns {
                if pattern.hasPrefix("/"), pattern.count > 1 {
                    let body = String(pattern.dropFirst())
                    if trimmed.range(of: body, options: .regularExpression) != nil {
                        return false
                    }
                } else if trimmed.localizedCaseInsensitiveContains(pattern) {
                    return false
                }
            }
            return true
        }
        return copy
    }
}


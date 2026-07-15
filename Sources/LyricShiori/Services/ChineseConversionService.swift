import Foundation

struct FoundationChineseConversionService: ChineseConversionService {
    func convert(_ text: String, mode: ChineseConversionMode) -> String {
        switch mode {
        case .disabled:
            text
        case .simplified:
            text.applyingTransform(.traditionalToSimplified, reverse: false) ?? text
        case .traditional:
            text.applyingTransform(.simplifiedToTraditional, reverse: false) ?? text
        }
    }
}

struct PassthroughChineseConversionService: ChineseConversionService {
    func convert(_ text: String, mode: ChineseConversionMode) -> String {
        text
    }
}

extension StringTransform {
    fileprivate static let traditionalToSimplified = StringTransform(
        rawValue: "Traditional-Simplified"
    )
    fileprivate static let simplifiedToTraditional = StringTransform(
        rawValue: "Simplified-Traditional"
    )
}

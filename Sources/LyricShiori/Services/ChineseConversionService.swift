import Foundation

struct PassthroughChineseConversionService: ChineseConversionService {
    func convert(_ text: String, mode: ChineseConversionMode) -> String {
        text
    }
}

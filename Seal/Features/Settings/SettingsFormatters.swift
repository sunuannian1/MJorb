import Foundation

extension Int64 {
    var sealFormattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

enum SealSettingsDateFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

enum TeamNameDisplayFormatter {
    static func string(from name: String) -> String {
        let parts = name
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 2,
              parts.allSatisfy(isCJKText) else {
            return name
        }
        return "\(parts[1]) \(parts[0])"
    }

    private static func isCJKText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }
}

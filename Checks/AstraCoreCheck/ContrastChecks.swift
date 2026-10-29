import Foundation
import AstraCore

// Section 4.1: every colored text token reaches 4.5:1 (7:1 in Increase
// Contrast) on the backgrounds it can sit on, every fill reaches 3:1, and a
// white label reaches 4.5:1 on accent.fill in all four variants. The hex
// values are the table of section 4.1; M0b mirrors them in
// AstraApp/App/Design/Tokens.swift and the asset catalog, which this
// package cannot see, so the table is repeated here and is the contract.

private struct ColorToken {
    enum Kind { case text, fill }

    var name: String
    var kind: Kind
    var light: String
    var dark: String
    var lightIncreased: String
    var darkIncreased: String
}

private let tokens: [ColorToken] = [
    ColorToken(name: "accent.text", kind: .text, light: "#2F5BEA", dark: "#7C9BFF", lightIncreased: "#1A3DB8", darkIncreased: "#A3BAFF"),
    ColorToken(name: "status.ok.fill", kind: .fill, light: "#248A3D", dark: "#30D158", lightIncreased: "#1B6B30", darkIncreased: "#30DB5B"),
    ColorToken(name: "status.ok.text", kind: .text, light: "#1F7A35", dark: "#30D158", lightIncreased: "#145A26", darkIncreased: "#5BE37D"),
    ColorToken(name: "status.warn.fill", kind: .fill, light: "#C93400", dark: "#FF9F0A", lightIncreased: "#A12A00", darkIncreased: "#FFB340"),
    ColorToken(name: "status.warn.text", kind: .text, light: "#B25000", dark: "#FF9F0A", lightIncreased: "#803800", darkIncreased: "#FFB340"),
    ColorToken(name: "status.fail.fill", kind: .fill, light: "#E0281E", dark: "#FF453A", lightIncreased: "#B8000F", darkIncreased: "#FF6961"),
    ColorToken(name: "status.fail.text", kind: .text, light: "#D70015", dark: "#FF7A72", lightIncreased: "#A00010", darkIncreased: "#FFA39E"),
]

/// accent.fill per variant: light, dark, light Increase Contrast, dark Increase Contrast.
private let accentFill = ["#2F5BEA", "#2F5BEA", "#1A3DB8", "#2F5BEA"]
/// destructive.fill per variant, the T4 primary button. System red under a
/// white label is about 3.5:1, so the destructive button has its own fill.
private let destructiveFill = ["#D70015", "#D70015", "#A00010", "#D70015"]

/// Light cells and the light grouped background (section footers).
private let lightBackgrounds = ["#FFFFFF", "#F2F2F7"]
/// Dark base cells and dark elevated cells (sheets such as Review).
private let darkBackgrounds = ["#1C1C1E", "#2C2C2E"]

public func checkContrast() async throws {
    var failures: [String] = []
    for token in tokens {
        let base = token.kind == .text ? 4.5 : 3.0
        let increased = token.kind == .text ? 7.0 : 3.0
        let variants: [(String, String, [String], Double)] = [
            ("light", token.light, lightBackgrounds, base),
            ("dark", token.dark, darkBackgrounds, base),
            ("light Increase Contrast", token.lightIncreased, lightBackgrounds, increased),
            ("dark Increase Contrast", token.darkIncreased, darkBackgrounds, increased),
        ]
        for (variant, color, backgrounds, minimum) in variants {
            for background in backgrounds {
                let ratio = try contrast(color, background)
                if ratio < minimum {
                    failures.append("\(token.name) \(variant) \(color) on \(background): \(format(ratio)) < \(format(minimum))")
                }
            }
        }
    }
    for (index, fill) in accentFill.enumerated() {
        let ratio = try contrast("#FFFFFF", fill)
        if ratio < 4.5 { failures.append("white on accent.fill variant \(index) \(fill): \(format(ratio)) < 4.5") }
    }
    for (index, fill) in destructiveFill.enumerated() {
        let ratio = try contrast("#FFFFFF", fill)
        if ratio < 4.5 { failures.append("white on destructive.fill variant \(index) \(fill): \(format(ratio)) < 4.5") }
    }
    try expect(failures.isEmpty, "contrast targets of section 4.1:\n" + failures.joined(separator: "\n"))

    // The figures section 4.1 quotes.
    try expectEqual(format(try contrast("#FFFFFF", "#2F5BEA")), "5.52", "white on accent.fill")
    try expectEqual(format(try contrast("#FFFFFF", "#1A3DB8")), "8.74", "white on accent.fill in Light Increase Contrast")
    try expectEqual(format(try contrast("#FF7A72", "#2C2C2E")), "5.49", "dark status.fail.text on elevated cells")
    try expectEqual(format(try contrast("#FFA39E", "#2C2C2E")), "7.29", "dark Increase Contrast status.fail.text on elevated cells")
    // The ratio itself, against the WCAG reference pair.
    try expectEqual(format(try contrast("#000000", "#FFFFFF")), "21.00", "black on white is 21:1")
}

/// WCAG 2 contrast ratio of two sRGB colors written as #RRGGBB.
private func contrast(_ first: String, _ second: String) throws -> Double {
    let a = try luminance(first)
    let b = try luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func luminance(_ hex: String) throws -> Double {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
        throw CheckFailure.failed("not a #RRGGBB color: \(hex)")
    }
    func channel(_ shift: UInt32) -> Double {
        let c = Double((value >> shift) & 0xFF) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
}

private func format(_ ratio: Double) -> String {
    String(format: "%.2f", ratio)
}

import AppKit

/// Persisted names for the menu-bar text treatments. Keep raw values stable so
/// an appearance selected in an older build continues to resolve.
enum StatusColorStyle: String, CaseIterable, Identifiable, Sendable {
    case rainbow
    case aurora
    case ocean
    case sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rainbow: "Rainbow"
        case .aurora: "Aurora"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        }
    }

    var subtitle: String {
        switch self {
        case .rainbow: "Full spectrum"
        case .aurora: "Mint and violet"
        case .ocean: "Cyan and blue"
        case .sunset: "Pink and amber"
        }
    }
}

enum StatusAppearance {
    static let defaultStyle = StatusColorStyle.rainbow.rawValue
    static let defaultSpeed = 1.0
    static let defaultIntensity = 0.92
    static let defaultTextPadding = 2.0

    static let speedRange = 0.25...2.0
    static let intensityRange = 0.45...1.0
    /// Zero is safe because itemLength still reserves the complete measured
    /// width of "listening"; this only removes otherwise-empty outer space.
    static let textPaddingRange = 0.0...18.0

    static func style(named name: String) -> StatusColorStyle {
        StatusColorStyle(rawValue: name) ?? .rainbow
    }

    static func speed(_ value: Double) -> Double {
        min(max(value, speedRange.lowerBound), speedRange.upperBound)
    }

    static func intensity(_ value: Double) -> Double {
        min(max(value, intensityRange.lowerBound), intensityRange.upperBound)
    }

    static func textPadding(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, textPaddingRange.lowerBound), textPaddingRange.upperBound))
    }

    static func itemLength(font: NSFont, padding: Double) -> CGFloat {
        let textWidth = ("listening" as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + textPadding(padding)
    }

    /// One complete palette pass takes about seven seconds at normal speed.
    static func phase(at date: Date, speed rawSpeed: Double) -> Double {
        positiveRemainder(date.timeIntervalSinceReferenceDate * 0.14 * speed(rawSpeed))
    }

    static func attributedTitle(
        _ text: String,
        font: NSFont,
        styleName: String,
        phase: Double,
        intensity rawIntensity: Double
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .kern: 0.05]
        )
        let count = max((text as NSString).length, 1)
        for index in 0..<count {
            let position = count == 1 ? 0.5 : Double(index) / Double(count - 1)
            output.addAttribute(
                .foregroundColor,
                value: color(
                    style: style(named: styleName),
                    position: position,
                    phase: phase,
                    intensity: rawIntensity
                ),
                range: NSRange(location: index, length: 1)
            )
        }
        return output
    }

    static func previewColors(
        styleName: String,
        phase: Double,
        intensity: Double,
        samples: Int = 9
    ) -> [NSColor] {
        let count = max(samples, 2)
        return (0..<count).map { index in
            color(
                style: style(named: styleName),
                position: Double(index) / Double(count - 1),
                phase: phase,
                intensity: intensity
            )
        }
    }

    static func color(
        style: StatusColorStyle,
        position: Double,
        phase: Double,
        intensity rawIntensity: Double
    ) -> NSColor {
        let value = positiveRemainder(position + phase)
        let strength = intensity(rawIntensity)

        if style == .rainbow {
            return NSColor(
                calibratedHue: CGFloat(value),
                saturation: CGFloat(0.38 + strength * 0.60),
                brightness: 1,
                alpha: 1
            )
        }

        let palette = palette(for: style)
        let scaled = value * Double(palette.count)
        let lower = Int(floor(scaled)) % palette.count
        let upper = (lower + 1) % palette.count
        let fraction = CGFloat(scaled - floor(scaled))
        let sampled = palette[lower].blended(withFraction: fraction, of: palette[upper]) ?? palette[lower]
        return sampled.blended(withFraction: CGFloat((1 - strength) * 0.55), of: .white) ?? sampled
    }

    private static func palette(for style: StatusColorStyle) -> [NSColor] {
        switch style {
        case .rainbow:
            return [.systemRed, .systemYellow, .systemGreen, .systemCyan, .systemBlue, .systemPurple]
        case .aurora:
            return [.systemMint, .systemCyan, .systemPurple, .systemPink]
        case .ocean:
            return [.systemCyan, .systemBlue, .systemIndigo, .systemTeal]
        case .sunset:
            return [.systemPink, .systemRed, .systemOrange, .systemYellow]
        }
    }

    private static func positiveRemainder(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

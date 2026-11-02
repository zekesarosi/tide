import SwiftUI
import TideKit

/// "Slack Water": the app's design system. White space and hairlines carry
/// the layout; harbor blue is measured water, swell amber is forecast or
/// extra water, and flood colors appear only for flood risk.
///
/// Compiled into both the app and the widget extension.
enum Theme {
    // Grounds
    static let surface = Color(light: 0xFFFFFF, dark: 0x0B1820)
    static let mist = Color(light: 0xF5F8F9, dark: 0x060F15)
    static let card = Color(light: 0xFFFFFF, dark: 0x12232D)
    static let hairline = Color(light: 0xE3EAEE, dark: 0x1F3340)
    static let neutralWash = Color(light: 0xF1F5F7, dark: 0x16272F)
    static let searchField = Color(light: 0xE9EFF2, dark: 0x16272F)

    // Ink
    static let ink = Color(light: 0x0D2230, dark: 0xE8F0F4)
    static let inkSecondary = Color(light: 0x4E6575, dark: 0x9DB2BF)

    // Water
    static let harbor = Color(light: 0x1F6FA6, dark: 0x6FB3E3)
    static let swell = Color(light: 0xD9772E, dark: 0xF0A266)
    static let swellDot = Color(light: 0xE08A3C, dark: 0xF0A266)
    static let swellBand = Color(light: 0xF4A259, dark: 0xF0A266)
    static let swellText = Color(light: 0x9A4A10, dark: 0xF4B27F)
    static let swellWash = Color(light: 0xFDF1E7, dark: 0x3A2414)
    static let tideTable = Color(light: 0x7F95A3, dark: 0x6F8794)

    // Flood
    static let floodLine = Color(light: 0xC4552B, dark: 0xE7835A)
    static let floodText = Color(light: 0x9E3F1C, dark: 0xF09A76)
    static let calloutText = Color(light: 0x7A3A0C, dark: 0xF6C29A)

    // Layout
    static let margin: CGFloat = 20
    static let sectionGap: CGFloat = 26
    static let cardRadius: CGFloat = 18
}

extension FloodCategory {
    /// Text/mark color for this category.
    var tint: Color {
        switch self {
        case .none: return Theme.inkSecondary
        case .action: return Color(light: 0x8A6D00, dark: 0xE2C45A)
        case .minor: return Color(light: 0xB35612, dark: 0xF0A266)
        case .moderate: return Color(light: 0xB3261E, dark: 0xF08A84)
        case .major: return Color(light: 0x6E3AA0, dark: 0xC5A2EC)
        }
    }

    /// Soft fill behind badges for this category.
    var wash: Color {
        switch self {
        case .none: return Theme.neutralWash
        case .action: return Color(light: 0xF6EED0, dark: 0x332A08)
        case .minor: return Color(light: 0xFBE3D5, dark: 0x3A2414)
        case .moderate: return Color(light: 0xF6D6D3, dark: 0x3A1614)
        case .major: return Color(light: 0xE9DDF3, dark: 0x2A1A3A)
        }
    }
}

extension Color {
    /// A color with separate light and dark appearances (sRGB hex).
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Type

extension Font {
    /// The big water-level reading: SF Pro Rounded, thin.
    static func reading(_ size: CGFloat) -> Font { .system(size: size, weight: .thin, design: .rounded) }
    /// Values on cards and widgets.
    static let cardValue = Font.system(size: 34, weight: .thin, design: .rounded)
    /// Values in rows and grids.
    static let rowValue = Font.system(size: 20, weight: .light, design: .rounded)
}

/// Small uppercase label that opens a section.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .tracking(1.0)
            .foregroundStyle(Theme.inkSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A 1-pt rule.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

/// Status pill. Swell: extra/forecast water; neutral: calm facts; harbor: below normal.
struct Chip: View {
    enum Style { case swell, neutral, harbor }
    let text: String
    var style: Style = .neutral

    var body: some View {
        HStack(spacing: 6) {
            if style != .neutral {
                Circle().fill(style == .swell ? Theme.swellDot : Theme.harbor).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.footnote.weight(style == .neutral ? .regular : .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(style == .swell ? Theme.swellText : (style == .harbor ? Theme.harbor : Theme.inkSecondary))
        .background(style == .swell ? Theme.swellWash : Theme.neutralWash, in: Capsule())
    }
}

/// Flood category or probability badge.
struct FloodBadge: View {
    let category: FloodCategory
    var probability: Double?

    var body: some View {
        let shown = category > .none ? category : .minor
        Text(category > .none ? category.shortLabel : Fmt.percent(probability ?? 0))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(shown.tint)
            .background(shown.wash, in: Capsule())
            .accessibilityLabel(category > .none ? category.label : "\(Fmt.percent(probability ?? 0)) chance of minor flooding")
    }
}

/// The one tinted block a screen may carry: flood risk, an NWS alert or a storm.
struct RiskCallout: View {
    let title: String
    let message: String?
    var systemImage = "water.waves"
    var tint: Color = Theme.calloutText
    var wash: Color = Theme.swellWash

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                if let message { Text(message).font(.subheadline) }
            }
            .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Rising / falling arrow.
struct TrendArrow: View {
    let rising: Bool

    var body: some View {
        Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.harbor)
            .accessibilityLabel(rising ? "Rising" : "Falling")
    }
}

/// Plain-language phrasing shared by app and widget.
enum Phrase {
    /// "1.2 ft above the tide table" / "near the tide table".
    static func anomaly(_ meters: Double, _ unit: LengthUnit, short: Bool = false) -> String {
        let tail = short ? "table" : "the tide table"
        if abs(meters) < 0.03 { return "Near \(tail)" }
        let v = Fmt.length(abs(meters), unit)
        return meters > 0 ? "\(v) above \(tail)" : "\(v) below \(tail)"
    }

    static func eventName(_ kind: TideExtremeKind) -> String { kind == .high ? "High" : "Low" }
}

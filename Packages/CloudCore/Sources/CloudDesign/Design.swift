// Apache 2 license - developer@infinitecontext.com

import SwiftUI

/// The look both apps share: small capital labels above rounded cards, rows with an icon, a title
/// and a control, big tiles for the main actions, and red only for what can't be undone. Colors
/// come from the system's primary color, so light and dark both work.
public enum Design {
    public static let cardRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 12
    public static let sectionGap: CGFloat = 14
    public static let labelGap: CGFloat = 6
    public static let cardFill = Color.primary.opacity(0.05)
    public static let cardLine = Color.primary.opacity(0.10)
    public static let controlFill = Color.primary.opacity(0.08)
}

/// The app's name and version, with the overall state on the right.
public struct PanelHeader<Trailing: View>: View {
    let title: String
    let detail: String?
    let trailing: Trailing

    public init(title: String, detail: String?, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

/// A state in a word, with a dot, so color is never the only cue.
public struct StatusPill: View {
    let text: String
    let color: Color

    public init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Design.controlFill))
    }
}

/// The small capitals above a card.
public struct SectionLabel: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// The fill and hairline that every card and list shares.
    public func cardSurface() -> some View {
        background(RoundedRectangle(cornerRadius: Design.cardRadius).fill(Design.cardFill))
            .overlay {
                RoundedRectangle(cornerRadius: Design.cardRadius)
                    .strokeBorder(Design.cardLine)
            }
    }
}

public struct Card<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(Design.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// A label and the card it names.
public struct CardSection<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.labelGap) {
            SectionLabel(title)
            Card { content }
        }
    }
}

/// A feature in a card: what it is on the left, and its control on the right.
public struct IconRow<Control: View>: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let tint: Color?
    let control: Control

    public init(
        _ symbol: String, _ title: String, subtitle: String? = nil, tint: Color? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.control = control()
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 34)
    }
}

/// A fact: a gray key on the left and its value on the right.
public struct KeyValueRow: View {
    let key: String
    let value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

/// How much of something is used, with what the numbers mean underneath.
public struct UsageBar: View {
    let share: Double
    let used: String
    let limit: String

    public init(share: Double, used: String, limit: String) {
        self.share = share
        self.used = used
        self.limit = limit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Design.controlFill)
                    Capsule()
                        .fill(.blue)
                        .frame(width: max(4, proxy.size.width * min(max(share, 0), 1)))
                }
            }
            .frame(height: 6)
            HStack(spacing: 12) {
                legend(used, color: .blue)
                legend(limit, color: Color.primary.opacity(0.3))
            }
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// One of the main actions: an icon above its name.
public struct Tile: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    public init(_ title: String, symbol: String, tint: Color = .blue, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint == .red ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Design.cardRadius)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06)))
            .overlay {
                RoundedRectangle(cornerRadius: Design.cardRadius)
                    .strokeBorder(Design.cardLine)
            }
    }
}

/// A compact action on the right of a row.
public struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.10)))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A square button that holds one icon.
public struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A full-width tinted bar: blue for the main action, and red for what can't be undone.
public struct BarButtonStyle: ButtonStyle {
    let tint: Color

    public init(tint: Color) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(configuration.isPressed ? 0.28 : 0.16)))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    public static var pill: PillButtonStyle { PillButtonStyle() }
}

extension ButtonStyle where Self == IconButtonStyle {
    public static var icon: IconButtonStyle { IconButtonStyle() }
}

extension ButtonStyle where Self == BarButtonStyle {
    public static func bar(_ tint: Color) -> BarButtonStyle { BarButtonStyle(tint: tint) }
}

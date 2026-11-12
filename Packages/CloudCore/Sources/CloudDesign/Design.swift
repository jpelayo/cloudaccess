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

// Text a person reads works as SwiftUI's `Text` does: a literal is a key, looked up in the calling
// app's own strings, and a `String` value is shown as it is, so a drive called "Drives" is never
// translated. Swift picks one form for a whole call, so where a component takes two texts, each
// one says how a literal beside a value is read.

/// The app's name and version, with the overall state on the right.
public struct PanelHeader<Trailing: View>: View {
    let title: Text
    let detail: String?
    let trailing: Trailing

    /// - Parameter detail: A value, such as the version, shown as it is.
    public init(title: LocalizedStringKey, detail: String?, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.detail = detail
        self.trailing = trailing()
    }

    @_disfavoredOverload
    public init(title: some StringProtocol, detail: String?, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: String(title))
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 6) {
            title
                .font(.system(size: 15, weight: .bold))
            if let detail {
                Text(verbatim: detail)
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
    let text: Text
    let color: Color

    public init(text: LocalizedStringKey, color: Color) {
        self.text = Text(text)
        self.color = color
    }

    @_disfavoredOverload
    public init(text: some StringProtocol, color: Color) {
        self.text = Text(verbatim: String(text))
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            text
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Design.controlFill))
    }
}

/// The small capitals above a card. They're made capitals as they're drawn, in the language
/// shown, so the words themselves stay as written.
public struct SectionLabel: View {
    let text: Text

    public init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    @_disfavoredOverload
    public init(_ text: some StringProtocol) {
        self.text = Text(verbatim: String(text))
    }

    init(text: Text) {
        self.text = text
    }

    public var body: some View {
        text
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
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
    let title: Text
    let content: Content

    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }

    @_disfavoredOverload
    public init(_ title: some StringProtocol, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: String(title))
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.labelGap) {
            SectionLabel(text: title)
            Card { content }
        }
    }
}

/// A feature in a card: what it is on the left, and its control on the right.
///
/// A literal title and subtitle are both keys, and a `String` title and subtitle are both shown as
/// they are. A literal title with a `String` subtitle takes the second form, so to translate that
/// title, pass `String(localized:)`.
public struct IconRow<Control: View>: View {
    let symbol: String
    let title: Text
    let subtitle: Text?
    let tint: Color?
    let control: Control

    public init(
        _ symbol: String, _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, tint: Color? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.symbol = symbol
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.tint = tint
        self.control = control()
    }

    @_disfavoredOverload
    public init(
        _ symbol: String, _ title: some StringProtocol, subtitle: String? = nil, tint: Color? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.symbol = symbol
        self.title = Text(verbatim: String(title))
        self.subtitle = subtitle.map { Text(verbatim: $0) }
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
                title
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    subtitle
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
///
/// The value is data, such as a version or a date, and is shown as it is, the way `LabeledContent`
/// shows its value. A fixed value that needs translating is passed as `String(localized:)`.
public struct KeyValueRow: View {
    let key: Text
    let value: String

    public init(_ key: LocalizedStringKey, _ value: String) {
        self.key = Text(key)
        self.value = value
    }

    @_disfavoredOverload
    public init(_ key: some StringProtocol, _ value: String) {
        self.key = Text(verbatim: String(key))
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 8) {
            key
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

/// How much of something is used, with what the numbers mean underneath. Both captions are
/// literals, such as "Limit \(size)", or both are values.
public struct UsageBar: View {
    let share: Double
    let used: Text
    let limit: Text

    public init(share: Double, used: LocalizedStringKey, limit: LocalizedStringKey) {
        self.share = share
        self.used = Text(used)
        self.limit = Text(limit)
    }

    @_disfavoredOverload
    public init(share: Double, used: String, limit: String) {
        self.share = share
        self.used = Text(verbatim: used)
        self.limit = Text(verbatim: limit)
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

    private func legend(_ text: Text, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            text
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// One of the main actions: an icon above its name.
public struct Tile: View {
    let title: Text
    let symbol: String
    let tint: Color
    let action: () -> Void

    public init(_ title: LocalizedStringKey, symbol: String, tint: Color = .blue, action: @escaping () -> Void) {
        self.title = Text(title)
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    @_disfavoredOverload
    public init(_ title: some StringProtocol, symbol: String, tint: Color = .blue, action: @escaping () -> Void) {
        self.title = Text(verbatim: String(title))
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
                title
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

/// The loop button: checks a connection again now, while the app goes on checking by itself. Its
/// words come from the app's own strings.
public struct CheckAgainButton: View {
    let isChecking: Bool
    let action: () -> Void

    public init(isChecking: Bool, action: @escaping () -> Void) {
        self.isChecking = isChecking
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isChecking ? LocalizedStringKey("Checking…") : LocalizedStringKey("Check Again"))
            }
        }
        .disabled(isChecking)
    }
}

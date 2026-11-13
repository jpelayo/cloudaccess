// Apache 2 license - developer@infinitecontext.com

import AppKit
import CloudCore
import CloudDesign
import SwiftUI

/// The sizes every settings window and sheet is built to. They're chosen, never measured from
/// what's inside, so nothing that loads later can resize a window or push it off the screen.
enum Pane {
    /// A sheet. The Settings window is wider, so a sheet sits inside it rather than filling it.
    static let width: CGFloat = 600
    static let height: CGFloat = 640
    static let padding: CGFloat = 16

    /// The Settings window, which sheets hang from.
    static let windowWidth: CGFloat = 680
    static let windowHeight: CGFloat = 760
    /// A drive's sheet: tall enough for its longest page, Advanced, with nothing to scroll on a
    /// screen that has the room.
    static let driveHeight: CGFloat = 920
    /// Adding a drive.
    static let formHeight: CGFloat = 680
    /// A sheet hung from another sheet, such as choosing a folder, a little narrower than it.
    static let innerWidth: CGFloat = 520

    /// The column every row's popup lines up in, all the same width.
    static let valueColumn: CGFloat = 200
    /// A text field's column, wider so an address fits.
    static let fieldColumn: CGFloat = 300

    /// The height, made shorter on a screen that can't hold it.
    @MainActor static func fitting(_ height: CGFloat) -> CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return CGFloat(PaneHeight.fitting(Double(height), screenHeight: Double(screen)))
    }
}

/// One settings window or sheet: what stays at the top, a body that scrolls only when it's taller
/// than the room left, and what stays at the bottom, such as Done. Its size is fixed, so a list
/// that arrives late moves nothing but what's under it.
struct SheetPage<Header: View, Content: View, Footer: View>: View {
    var width: CGFloat = Pane.width
    var height: CGFloat = Pane.height
    /// Less for a window whose header shares the title bar with its close button.
    var headerTop: CGFloat = Pane.padding
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    /// Each part gets exactly the page's width. Left to size themselves, one part wider than the
    /// page, such as a row of tabs in Spanish, made the whole column wider, and the column, centered
    /// in the page, was cut on the left with a gap on the right.
    var body: some View {
        let inner = width - Pane.padding * 2
        VStack(alignment: .leading, spacing: 0) {
            if Header.self != EmptyView.self {
                header
                    .frame(width: inner, alignment: .leading)
                    .padding(.horizontal, Pane.padding)
                    .padding(.top, headerTop)
                    .padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Design.sectionGap) {
                    content
                }
                .frame(width: inner, alignment: .leading)
                .padding(.horizontal, Pane.padding)
                .padding(.top, Header.self == EmptyView.self ? Pane.padding : 2)
                .padding(.bottom, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: width)
            if Footer.self != EmptyView.self {
                footer
                    .frame(width: inner, alignment: .leading)
                    .padding(.horizontal, Pane.padding)
                    .padding(.top, 12)
                    .padding(.bottom, Pane.padding)
            }
        }
        .frame(width: width, height: Pane.fitting(height), alignment: .top)
    }
}

extension SheetPage where Header == EmptyView {
    init(
        width: CGFloat = Pane.width, height: CGFloat = Pane.height,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.init(width: width, height: height, header: { EmptyView() }, content: content, footer: footer)
    }
}

extension SheetPage where Header == EmptyView, Footer == EmptyView {
    /// For a sheet whose buttons are in its toolbar.
    init(width: CGFloat = Pane.width, height: CGFloat = Pane.height, @ViewBuilder content: () -> Content) {
        self.init(width: width, height: height, header: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}

extension SheetPage where Footer == EmptyView {
    init(
        width: CGFloat = Pane.width, height: CGFloat = Pane.height, headerTop: CGFloat = Pane.padding,
        @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content
    ) {
        self.init(
            width: width, height: height, headerTop: headerTop, header: header, content: content,
            footer: { EmptyView() })
    }
}

/// A titled card of settings, one per row, with a hairline between rows as System Settings has.
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.labelGap) {
            if let title {
                SectionLabel(title)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Divider()
                        }
                        row
                            .padding(.vertical, 7)
                    }
                }
            }
            .padding(.horizontal, Design.cardPadding)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

/// The heights rows in a list come in. A list works out its own height from these, so it always
/// shows whole rows and never cuts one in half.
enum RowHeight {
    static let single: CGFloat = 30
    static let double: CGFloat = 42
}

/// A list that can grow, with a scroll area of its own: a drive can have a thousand folders. A
/// short list shrinks to fit, and a long one shows `visibleRows` whole rows. One that loads after
/// the window opens `reserves` its whole height from the start, so it moves nothing when it arrives.
struct BoundedList<Content: View>: View {
    let rows: Int
    let rowHeight: CGFloat
    let visibleRows: Int
    var reserves = false
    @ViewBuilder let content: Content

    private static var padding: CGFloat { 6 }

    private var height: CGFloat {
        let shown = reserves ? visibleRows : min(max(rows, 1), visibleRows)
        return CGFloat(shown) * rowHeight + Self.padding * 2
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Self.padding)
        }
        .frame(height: height)
        .cardSurface()
    }
}

/// A name in a list, with its controls on the right. Only a name is cut, and in the middle, which
/// keeps both ends of something like "Fotos 2024 copia" readable. Settings never use this: their
/// labels wrap, in `SettingRow`.
struct ListRow<Label: View, Controls: View>: View {
    let height: CGFloat
    @ViewBuilder let label: Label
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(spacing: 8) {
            label
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            controls
        }
        .frame(height: height)
    }
}

/// One setting: its label on the left, wrapping onto more lines rather than being cut, an optional
/// caption under it, and its control on the right, at the size it needs.
struct SettingRow<Control: View>: View {
    let label: Text
    let caption: Text?
    let captionColor: Color
    @ViewBuilder let control: Control

    /// The label and caption are looked up in the app's strings.
    init(
        _ label: LocalizedStringKey, caption: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control
    ) {
        self.init(Text(label), caption: caption.map { Text($0) }, control: control)
    }

    /// Words already in the language shown, or a name, appear as they are.
    @_disfavoredOverload
    init(_ label: some StringProtocol, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(Text(verbatim: String(label)), caption: caption.map { Text(verbatim: $0) }, control: control)
    }

    init(
        _ label: Text, caption: Text? = nil, captionColor: Color = .secondary, @ViewBuilder control: () -> Control
    ) {
        self.label = label
        self.caption = caption
        self.captionColor = captionColor
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                label
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    caption
                        .font(.caption)
                        .foregroundStyle(captionColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .labelsHidden()
                .fixedSize()
        }
        .frame(minHeight: 24)
    }
}

/// A setting chosen from a popup. Every popup is the same width, so a card's popups share one
/// right edge and one left edge.
struct PickerRow<Value: Hashable, Options: View>: View {
    let label: Text
    let caption: Text?
    let captionColor: Color
    @Binding var selection: Value
    @ViewBuilder let options: Options

    init(
        _ label: LocalizedStringKey, selection: Binding<Value>, caption: Text? = nil,
        captionColor: Color = .secondary, @ViewBuilder options: () -> Options
    ) {
        self.label = Text(label)
        self.caption = caption
        self.captionColor = captionColor
        _selection = selection
        self.options = options()
    }

    var body: some View {
        SettingRow(label, caption: caption, captionColor: captionColor) {
            Picker(selection: $selection) {
                options
            } label: {
                label
            }
            .frame(width: Pane.valueColumn)
        }
    }
}

/// A switch that lines up with the other controls, as tall as a button in a row.
struct RowSwitch: View {
    let label: Text
    @Binding var isOn: Bool

    /// The label is looked up in the app's strings. It's hidden, and read out by VoiceOver.
    init(label: LocalizedStringKey, isOn: Binding<Bool>) {
        self.label = Text(label)
        _isOn = isOn
    }

    @_disfavoredOverload
    init(label: some StringProtocol, isOn: Binding<Bool>) {
        self.label = Text(verbatim: String(label))
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

/// The blurred surface a window sits on. A window with no frame needs the blur itself rounded,
/// because SwiftUI can't clip what's behind the window.
struct WindowBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        if cornerRadius > 0 {
            view.maskImage = roundedMask
        }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private var roundedMask: NSImage {
        let radius = cornerRadius
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A text field that sits on the card instead of in a sunken box. Its label wraps, like every
/// setting's, and every field is the same width.
struct FieldRow: View {
    let label: Text
    @Binding var text: String
    let prompt: Text?
    let isSecure: Bool

    static let width: CGFloat = Pane.fieldColumn

    /// The label and the prompt are looked up in the app's strings.
    init(label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey? = nil, isSecure: Bool = false) {
        self.label = Text(label)
        _text = text
        self.prompt = prompt.map { Text($0) }
        self.isSecure = isSecure
    }

    /// A prompt that's a value, such as a port number, is shown as it is.
    @_disfavoredOverload
    init(label: LocalizedStringKey, text: Binding<String>, prompt: some StringProtocol, isSecure: Bool = false) {
        self.label = Text(label)
        _text = text
        self.prompt = Text(verbatim: String(prompt))
        self.isSecure = isSecure
    }

    var body: some View {
        SettingRow(label) {
            field
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: Self.width)
                .background(RoundedRectangle(cornerRadius: 6).fill(Design.controlFill))
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(text: $text, prompt: prompt) { label }
        } else {
            TextField(text: $text, prompt: prompt) { label }
        }
    }
}

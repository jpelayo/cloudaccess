// Apache 2 license - developer@infinitecontext.com

import AppKit
import CloudDesign
import SwiftUI

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

/// A text field that sits on the card instead of in a sunken box.
struct FieldRow: View {
    let label: Text
    @Binding var text: String
    let prompt: Text?
    let isSecure: Bool

    static let width: CGFloat = 270

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

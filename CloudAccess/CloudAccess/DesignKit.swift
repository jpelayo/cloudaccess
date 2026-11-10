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
    let label: String
    @Binding var text: String
    var prompt: String?
    var isSecure = false

    static let width: CGFloat = 270

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
            SecureField(label, text: $text, prompt: prompt.map { Text($0) })
        } else {
            TextField(label, text: $text, prompt: prompt.map { Text($0) })
        }
    }
}

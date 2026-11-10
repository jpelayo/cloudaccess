// Apache 2 license - developer@infinitecontext.com

import SwiftUI

/// A password field with an eye button that shows what's being typed. It only ever shows what
/// was typed here: a saved password is never shown. It starts hidden each time a screen opens.
struct SecretField: View {
    private let title: Text
    @Binding var text: String
    private let prompt: Text?

    @State private var isShown = false

    /// Words from this app's catalog, the way SwiftUI's own fields take them.
    init(_ title: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey? = nil) {
        self.title = Text(title)
        _text = text
        self.prompt = prompt.map { Text($0) }
    }

    /// Words already in the language shown, which are shown as they are.
    @_disfavoredOverload
    init<Title: StringProtocol>(_ title: Title, text: Binding<String>, prompt: String? = nil) {
        self.title = Text(verbatim: String(title))
        _text = text
        self.prompt = prompt.map { Text(verbatim: $0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isShown {
                    TextField(text: $text, prompt: prompt) { title }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(text: $text, prompt: prompt) { title }
                }
            }
            .textContentType(.password)
            Button {
                isShown.toggle()
            } label: {
                if isShown {
                    Label("Hide Password", systemImage: "eye.slash")
                } else {
                    Label("Show Password", systemImage: "eye")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}

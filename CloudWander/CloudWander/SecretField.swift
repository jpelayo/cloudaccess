// Apache 2 license - developer@infinitecontext.com

import SwiftUI

/// A password field with an eye button that shows what's being typed. It only ever shows what
/// was typed here: a saved password is never shown. It starts hidden each time a screen opens.
struct SecretField: View {
    let title: String
    @Binding var text: String
    var prompt: String?

    @State private var isShown = false

    init(_ title: String, text: Binding<String>, prompt: String? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isShown {
                    TextField(title, text: $text, prompt: prompt.map { Text($0) })
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(title, text: $text, prompt: prompt.map { Text($0) })
                }
            }
            .textContentType(.password)
            Button(isShown ? "Hide Password" : "Show Password", systemImage: isShown ? "eye.slash" : "eye") {
                isShown.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}

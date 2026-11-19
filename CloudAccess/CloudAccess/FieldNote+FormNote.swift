// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import SwiftUI

extension FieldNote {
    /// A form's problem, with what checking found under Details.
    init(_ note: FormNote, actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.init(
            note.text, details: note.details, steps: note.steps.map { (title: $0.title, result: $0.result) },
            actionTitle: actionTitle, action: action)
    }
}

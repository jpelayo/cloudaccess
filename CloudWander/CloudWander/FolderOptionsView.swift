// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import SwiftUI

/// How folders are listed, for every folder. The switches come first, so they're in view at
/// half height on any iPhone.
struct FolderOptionsView: View {
    @Binding var order: FolderOrder
    @Binding var foldersFirst: Bool
    @Binding var showsHidden: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Folders at the top", isOn: $foldersFirst)
                    Toggle("Show hidden files", isOn: $showsHidden)
                } footer: {
                    Text("Hidden files have names that start with a dot.")
                }
                Section {
                    // One order at a time, so a checkmark here, not a switch.
                    Picker("Sort by", selection: $order) {
                        ForEach(FolderOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    SectionLabel("Sort by")
                }
            }
            .navigationTitle("View Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

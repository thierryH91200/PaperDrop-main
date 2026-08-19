import SwiftUI

/// Epson Scan 2 style "File Name Settings" sheet: build the save name from a
/// prefix plus optional date, time and counter, with a live preview. Edits are
/// staged in local state and only written back to the model on OK, so Cancel
/// leaves the current scheme untouched.
struct FileNameSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var prefix = ""
    @State private var addDate = true
    @State private var addTime = true
    @State private var useCounter = false
    @State private var digits = 4
    @State private var start = 1
    @State private var overwrite = false

    private var previewName: String {
        FileNameFormat(
            prefix: prefix, addDate: addDate, addTime: addTime,
            useCounter: useCounter, digits: digits
        )
        .base(counter: start) + ".pdf"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Filename preview")
                    .foregroundStyle(.secondary)
                Text(verbatim: previewName)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Form {
                Section {
                    TextField("Prefix", text: $prefix)
                    Toggle("Add date", isOn: $addDate)
                    Toggle("Add time", isOn: $addTime)
                        .padding(.leading, 16)
                        .disabled(!addDate)
                }
                Section {
                    Toggle("Use a counter", isOn: $useCounter)
                    Stepper(value: $digits, in: 1...8) {
                        LabeledContent("Digits") { Text(verbatim: "\(digits)") }
                    }
                    .padding(.leading, 16)
                    .disabled(!useCounter)
                    Stepper(value: $start, in: 1...999_999) {
                        LabeledContent("Start at") { Text(verbatim: "\(start)") }
                    }
                    .padding(.leading, 16)
                    .disabled(!useCounter)
                }
                Section {
                    Toggle("Overwrite files with the same name", isOn: $overwrite)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear(perform: load)
    }

    private func load() {
        prefix = model.namePrefix
        addDate = model.nameAddDate
        addTime = model.nameAddTime
        useCounter = model.nameUseCounter
        digits = model.nameCounterDigits
        start = model.nameCounterNext
        overwrite = model.nameOverwrite
    }

    private func apply() {
        model.namePrefix = prefix
        model.nameAddDate = addDate
        model.nameAddTime = addTime
        model.nameUseCounter = useCounter
        model.nameCounterDigits = digits
        model.nameCounterNext = start
        model.nameOverwrite = overwrite
    }
}

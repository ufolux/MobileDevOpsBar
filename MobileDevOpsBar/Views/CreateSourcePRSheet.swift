import SwiftUI

struct CreateSourcePRSheet: View {
    @Environment(\.dismiss) private var dismiss

    let ticketID: String
    let branchName: String
    let baseBranches: [String]
    let defaultBaseBranch: String
    let onCreate: (String, String, String) -> Void

    @State private var selectedBaseBranch: String = ""
    @State private var title: String = ""
    @State private var prBody: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Source PR")
                .font(.title3)

            LabeledContent("Ticket", value: ticketID)
            LabeledContent("Head Branch", value: branchName)

            Picker("Base Branch", selection: $selectedBaseBranch) {
                ForEach(baseBranches, id: \.self) { branch in
                    Text(branch).tag(branch)
                }
            }

            TextField("PR title", text: $title)
            TextEditor(text: $prBody)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Create PR") {
                    onCreate(selectedBaseBranch, title, prBody)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBaseBranch.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            selectedBaseBranch = baseBranches.contains(defaultBaseBranch) ? defaultBaseBranch : (baseBranches.first ?? "")
            if title.isEmpty {
                title = "\(ticketID): work in progress"
            }
            if prBody.isEmpty {
                prBody = "Automated PR for \(ticketID)."
            }
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacAppCore
import MacAppSettings
import LaunchpodCore

enum LegalDocument: String, CaseIterable, Identifiable {
    case terms, privacy
    var id: String { rawValue }
    var title: String {
        self == .terms ? L10n.text("Terms of Use", "이용약관") : L10n.text("Privacy Policy", "개인정보 처리방침")
    }
    func text(language: String = AppLocalizer.current.languageCode) throws -> String {
        guard let url = Bundle.module.url(forResource: "\(rawValue).\(language)", withExtension: "md", subdirectory: "Legal") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The library's agreement pages accept plain text, not Markdown.
    func plainText() throws -> String {
        try text()
            .replacingOccurrences(of: "(?m)^#{1,6} ", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\(mailto:[^)]+\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "$1: $2", options: .regularExpression)
    }
}

struct LegalSettingsSection: View {
    @State private var document: LegalDocument? = nil
    var body: some View {
        SettingsSection(L10n.text("Legal documents", "법률 문서"), footer: L10n.text("These documents are included with the app and can be read offline. Viewing or saving them does not record consent.", "앱에 포함된 문서로, 인터넷 연결 없이 읽을 수 있습니다. 열람하거나 저장해도 동의로 기록되지 않습니다.")) {
            ForEach(LegalDocument.allCases) { item in
                SettingsRow(item.title) {
                    Button(L10n.text("Read…", "읽기…")) { document = item }
                        .accessibilityLabel(item.title)
                }
            }
        }
        .sheet(item: $document) { LegalDocumentView(document: $0) }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var error: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(document.title).font(.title2.bold())
            if let error { Text(error).foregroundColor(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(content.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                        if block.hasPrefix("# ") {
                            Text(String(block.dropFirst(2))).font(.title2.bold())
                        } else if block.hasPrefix("## ") {
                            Text(String(block.dropFirst(3))).font(.headline)
                        } else {
                            Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 10)
            }
            HStack {
                Button(L10n.text("Copy", "복사")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content, forType: .string)
                }.disabled(content.isEmpty)
                Button(L10n.text("Save…", "저장…"), action: save).disabled(content.isEmpty)
                Spacer()
                Button(L10n.text("Done", "완료")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 610, height: 430)
        .onExitCommand { dismiss() }
        .onAppear {
            do { content = try document.text() }
            catch { self.error = L10n.text("Unable to open this document: ", "문서를 열 수 없습니다: ") + error.localizedDescription }
        }
    }
    private func save() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Launchpod-\(document.rawValue)-\(AppLocalizer.current.languageCode).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}

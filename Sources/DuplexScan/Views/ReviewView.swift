import AppKit
import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var session: ScanSession

    var body: some View {
        ReviewContent(editor: session.editor)
    }
}

private struct ReviewContent: View {
    @EnvironmentObject private var session: ScanSession
    @ObservedObject var editor: PDFEditor
    @AppStorage(SettingsKey.uploadToDrive) private var uploadToDrive = false
    @AppStorage(SettingsKey.saveLocally) private var saveLocally = true

    var body: some View {
        VStack(spacing: 0) {
            if let warning = session.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.yellow.opacity(0.2))
            }
            HStack(spacing: 0) {
                HostedView(view: editor.thumbnailView)
                    .frame(width: 160)
                Divider()
                HostedView(view: editor.pdfView)
            }
            Divider()
            toolbar
        }
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("File name")
                TextField("File name", text: Binding(get: { session.fileName }, set: { session.setFileName($0) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.save() }
                Text(".pdf").foregroundStyle(.secondary)
                Button {
                    session.resetFileName()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Rebuild the name from the naming pattern")
                .disabled(!session.nameEdited)
            }
            HStack {
                Button {
                    session.removeSelectedPages()
                } label: {
                    Label("Remove Pages", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Remove the pages selected in the sidebar (⌘⌫). ⌘/⇧-click to select several.")
                .disabled(editor.pageCount < 2)

                Button {
                    session.undoRemoval()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!editor.canUndo)

                Button {
                    session.scanMorePages()
                } label: {
                    Label("Scan More Pages", systemImage: "plus.rectangle.on.rectangle")
                }

                Text("\(editor.pageCount) page(s)")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)

                if let aiStatus = session.aiStatus {
                    ProgressView().controlSize(.small)
                    Text(aiStatus).foregroundStyle(.secondary)
                }

                Spacer()

                Button("Discard", role: .destructive) { session.discard() }
                Button(saveTitle) { session.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
                    .disabled(!saveLocally && !uploadToDrive)
            }
            Divider()
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Estimated PDF").font(.caption).foregroundStyle(.secondary)
                    Text(formattedSize).monospacedDigit().fixedSize()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tag").font(.caption).foregroundStyle(.secondary)
                    Picker("Tag", selection: Binding(
                        get: { session.selectedTag ?? "" },
                        set: { session.selectTag($0.isEmpty ? nil : $0) }
                    )) {
                        Text("None").tag("")
                        ForEach(session.tagChoices, id: \.self) { tag in
                            Text(tag == session.displayedAITag ? "\(tag) (AI)" : tag).tag(tag)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .disabled(session.tagChoices.isEmpty)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("AI summary").font(.caption).foregroundStyle(.secondary)
                ScrollView(.vertical) {
                    Text(session.displayedSummary ?? summaryStatus)
                        .font(.callout)
                        .foregroundStyle(session.displayedSummary == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.trailing, 4)
                }
                .frame(height: 54)
            }
        }
        .padding(12)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: session.estimatedPDFSize, countStyle: .file) + " approx."
    }

    private var summaryStatus: String {
        if session.aiStatus != nil { return "Generating…" }
        return "Not generated"
    }

    private var saveTitle: String {
        switch (saveLocally, uploadToDrive) {
        case (true, true): "Save & Upload"
        case (false, true): "Upload"
        default: "Save"
        }
    }
}

/// Embeds an existing AppKit view owned elsewhere.
struct HostedView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

import AppKit
import PDFKit
import SwiftUI

struct SearchBar: View {
    @Bindable var session: DocumentSession
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索", text: $session.search.query)
                .textFieldStyle(.plain)
                .frame(width: 220)
                .focused($fieldFocused)
                .onSubmit {
                    submit()
                }
                .onChange(of: session.search.query) { _, newValue in
                    if newValue.isEmpty {
                        session.search.clear()
                    } else {
                        scheduleSearch()
                    }
                }

            if session.search.hasResults {
                Text("\(session.search.currentNumber) / \(session.search.totalResultsLabel)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .font(.system(size: 12))
                    .help(countHelp)

                if session.search.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                Divider().frame(height: 14)

                Button {
                    session.search.previous()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("上一个匹配 (⇧⌘G，或 ⇧Return)")
                .accessibilityLabel("上一个匹配")

                Button {
                    session.search.next()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("下一个匹配 (⌘G，或 Return)")
                .accessibilityLabel("下一个匹配")
            } else if session.search.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !session.search.query.isEmpty {
                Text("无结果")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }

            Divider().frame(height: 14)

            Button {
                session.toggleSearch(open: false)
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .help("关闭搜索 (Esc)")
            .accessibilityLabel("关闭搜索")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        .shadow(radius: 4, y: 2)
        .onAppear {
            DispatchQueue.main.async { focusField() }
        }
        .onChange(of: session.searchFocusRequest) { _, _ in
            focusField()
        }
    }

    /// Tooltip on the counter; when the list was cut off it says why and what to do about it.
    private var countHelp: String {
        session.search.isCapped
            ? "匹配过多，仅列出前 \(session.search.totalResults) 个；请输入更具体的关键词"
            : "当前匹配 / 全部匹配"
    }

    /// Return steps to the next match, ⇧Return to the previous one (see `SearchService.submit`).
    /// `onSubmit` doesn't report modifiers, so read Shift from the key event that triggered it.
    private func submit() {
        guard let document = session.document else { return }
        let shiftDown = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
        session.search.submit(in: document, backwards: shiftDown)
    }

    private func scheduleSearch() {
        guard let document = session.document else { return }
        session.search.scheduleSearch(in: document)
    }

    /// Focus the field and select its whole text, so ⌘F always leaves the user ready to type a
    /// replacement query (Safari / Preview behaviour).
    private func focusField() {
        let wasFocused = fieldFocused
        fieldFocused = true
        if wasFocused {
            // Focus is already in the field, so SwiftUI will not re-focus it: select directly.
            selectAllInFieldEditor()
        } else {
            // SwiftUI installs the field editor on its next update pass; select once it has.
            DispatchQueue.main.async { selectAllInFieldEditor() }
        }
    }

    /// While a text field is being edited, the window's first responder is the shared field
    /// editor (an `NSTextView` with `isFieldEditor == true`); `selectAll(_:)` on it selects the
    /// field's text. Non-field-editor text views (selectable labels) are left alone.
    /// https://developer.apple.com/documentation/appkit/nstext/isfieldeditor
    /// https://developer.apple.com/documentation/appkit/nstextview/selectall(_:)
    private func selectAllInFieldEditor() {
        guard let window = session.hostWindow ?? NSApp.keyWindow,
              let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else { return }
        editor.selectAll(nil)
    }
}

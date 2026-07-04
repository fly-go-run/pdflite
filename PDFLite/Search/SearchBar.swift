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
                    runSearch()
                }
                .onChange(of: session.search.query) { _, newValue in
                    if newValue.isEmpty {
                        session.search.clear()
                    } else {
                        scheduleSearch()
                    }
                }

            if session.search.hasResults {
                Text("\(session.search.currentNumber) / \(session.search.totalResults)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .font(.system(size: 12))

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

                Button {
                    session.search.next()
                } label: {
                    Image(systemName: "chevron.down")
                }
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
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        .shadow(radius: 4, y: 2)
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func runSearch() {
        guard let document = session.document else { return }
        session.search.search(in: document)
    }

    private func scheduleSearch() {
        guard let document = session.document else { return }
        session.search.scheduleSearch(in: document)
    }
}

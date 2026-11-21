import SwiftUI

struct LearnedWordsView: View {
    @ObservedObject private var status = LibraryStatus.shared
    @State private var words: [String]?
    @State private var deleting = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(words ?? [], id: \.self) { word in
                HStack {
                    Text(word)
                    Spacer()
                    Button(role: .destructive) { delete(word) } label: {
                        Label(L10n.delete, systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
        }
        .disabled(deleting)
        .overlay {
            if words == nil && error == nil { ProgressView() }
            else if words?.isEmpty == true { ContentUnavailableView(L10n.noLearnedWords, systemImage: "text.book.closed") }
        }
        .modifier(LibraryPageStyle())
        .navigationTitle(L10n.learnedWords)
        .task {
            // A local snapshot also needs refreshing when cloud sync is disabled.
            do { try await LibraryOperations.shared.exportLearned(automatic: true) }
            catch is MaintenanceDeferred {}
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            await reload()
        }
        .onChange(of: status.revision) { Task { await reload() } }
        .alert(L10n.cannotCompleteThisChange, isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {} message: { Text(error ?? "") }
    }

    private func reload() async {
        do { words = try await LibraryOperations.shared.learnedWords() }
        catch {
            words = words ?? []
            self.error = error.localizedDescription
        }
    }

    private func delete(_ word: String) {
        guard !deleting else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await LibraryOperations.shared.deleteLearnedWord(word)
                status.revision += 1
                Task { await status.sync(force: true) }
            } catch {
                await reload()
                self.error = error.localizedDescription
            }
        }
    }
}

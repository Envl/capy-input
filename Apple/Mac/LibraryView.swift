import SwiftUI
import CloudKit

@MainActor
final class LibraryStatus: ObservableObject {
    static let shared = LibraryStatus()
    @Published private(set) var busy = false
    @Published var resourceMessage = ""
    @Published var learnedMessage = ""
    @Published var revision = 0
    @Published private(set) var conflict: LibraryConflict?
    private var resolutions: [LibraryResolution] = []

    func resolve(useLocal: Bool) async {
        guard !busy, let conflict else { return }
        resolutions.removeAll { $0.conflict == conflict }
        resolutions.append(.init(conflict: conflict, useLocal: useLocal))
        await sync(force: true)
    }

    func sync(force: Bool = false) async {
        guard LibraryCloud.enabled, !busy else { return }
        if !force && !SquirrelMaintenance.canRunAutomatically { return }
        busy = true
        defer { busy = false }
        if LearnedSyncService.selected == .icloud && (force || LibraryCloud.isDue(.resources)) {
            do {
                try await LibraryOperations.shared.syncResources(resolutions: resolutions, automatic: !force)
                resourceMessage = ""
                conflict = nil
                resolutions = []
                revision += 1
            } catch is MaintenanceDeferred { return } catch let collision as LibraryConflict {
                conflict = collision
                resourceMessage = ""
            } catch {
                if Self.isCancellation(error) { return }
                resourceMessage = Self.message(error)
            }
        }
        guard !Task.isCancelled else { return }
        if LibraryCloud.enabled && (LearnedSyncService.selected == .server || force || LibraryCloud.isDue(.learned)) {
            do {
                try await LibraryOperations.shared.syncLearned(automatic: !force)
                learnedMessage = ""
                revision += 1
            } catch is MaintenanceDeferred { return } catch {
                if Self.isCancellation(error) { return }
                learnedMessage = Self.message(error)
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if let cloud = error as? CKError, cloud.code == .operationCancelled { return true }
        return Task.isCancelled
    }

    private static func message(_ error: Error) -> String {
        if let cloud = error as? CKError {
            #if DEBUG
            NSLog("CloudKit sync failed: %@", (cloud as NSError).debugDescription)
            #endif
            switch cloud.code {
            case .networkFailure, .networkUnavailable: return L10n.offlineChanges
            case .notAuthenticated: return L10n.signInToSync
            case .permissionFailure, .badContainer, .missingEntitlement: return L10n.icloudIsNotConfiguredForThisBuild
            case .quotaExceeded: return L10n.iCloudStorageFull
            case .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost:
                return L10n.errorCloudUnavailable
            default: break
            }
        }
        return AppError.userMessage(for: error)
    }
}

struct LibrarySection: View {
    var body: some View {
        Section {
            NavigationLink {
                LearnedWordsView()
            } label: {
                Label(L10n.learnedWords, systemImage: "books.vertical")
            }
            .accessibilityIdentifier("open-rime-library")
        } header: {
            Text(L10n.rimeLibrary)
        }
    }
}

struct LibraryPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

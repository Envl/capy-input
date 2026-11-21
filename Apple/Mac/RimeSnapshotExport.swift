import Foundation

/// Squirrel exports every live dictionary asynchronously after one notification.
final class RimeSnapshotExport: @unchecked Sendable {
    private let files: [URL: String]
    private let queue = DispatchQueue(label: "com.capyinput.snapshot-export", qos: .utility)
    private var reply: CheckedContinuation<Void, Error>?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSources = [URL: DispatchSourceFileSystemObject]()
    private var settle: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var original = [URL: Stamp]()

    private struct Stamp: Equatable {
        let date: Date
        let size: Int
        let inode: UInt64
    }

    private init(files: [URL: String], reply: CheckedContinuation<Void, Error>) {
        self.files = files
        self.reply = reply
    }

    static func wait(files: [URL: String], timeout: TimeInterval = 15, trigger: @escaping @Sendable () -> Void) async throws {
        guard !files.isEmpty else { return }
        try await withCheckedThrowingContinuation { continuation in
            let observer = RimeSnapshotExport(files: files, reply: continuation)
            observer.queue.async { observer.start(timeout: timeout, trigger: trigger) }
        }
    }

    private func stamp(_ url: URL) -> Stamp? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = values[.modificationDate] as? Date, let size = values[.size] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber else { return nil }
        return Stamp(date: date, size: size.intValue, inode: inode.uint64Value)
    }

    private func start(timeout seconds: TimeInterval, trigger: @escaping @Sendable () -> Void) {
        do {
            let directory = files.keys.first!.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { throw AppError(L10n.cannotObserveRimeSLearnedWordExport) }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { self.watchFiles(); self.changed() }
            source.setCancelHandler { close(descriptor) }
            directorySource = source
            source.resume()
            for file in files.keys { original[file] = stamp(file) }
            watchFiles()
            let deadline = DispatchWorkItem { self.finish(.failure(AppError(L10n.exportDidNotFinish))) }
            timeout = deadline
            queue.asyncAfter(deadline: .now() + seconds, execute: deadline)
            trigger()
        } catch { finish(.failure(error)) }
    }

    private func watchFiles() {
        guard reply != nil else { return }
        for file in files.keys where fileSources[file] == nil {
            let descriptor = open(file.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: queue)
            source.setEventHandler {
                guard let current = self.fileSources[file] else { return }
                if !current.data.intersection([.rename, .delete]).isEmpty {
                    current.cancel()
                    self.fileSources.removeValue(forKey: file)
                    self.watchFiles()
                }
                self.changed()
            }
            source.setCancelHandler { close(descriptor) }
            fileSources[file] = source
            source.resume()
        }
    }

    private func changed() {
        guard reply != nil else { return }
        settle?.cancel()
        let check = DispatchWorkItem {
            for (file, name) in self.files {
                guard let current = self.stamp(file), current != self.original[file],
                      let data = try? Data(contentsOf: file),
                      (try? LearnedDictionary(data: data, expectedName: name)) != nil else { return }
            }
            self.finish(.success(()))
        }
        settle = check
        queue.asyncAfter(deadline: .now() + 0.2, execute: check)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let reply else { return }
        self.reply = nil
        settle?.cancel(); settle = nil
        timeout?.cancel(); timeout = nil
        directorySource?.cancel(); directorySource = nil
        for source in fileSources.values { source.cancel() }
        fileSources.removeAll()
        reply.resume(with: result)
    }
}

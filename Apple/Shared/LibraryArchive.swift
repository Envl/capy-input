import Foundation
import Compression

enum LibraryArchive {
    static let maximumBytes = 256 * 1024 * 1024
    private static let magic = Data("RIMELIB2".utf8)

    static func encode(_ files: [String: LibraryFile], compressed: Bool = false, limit: Int = maximumBytes) throws -> Data {
        try RimeLibrary.verify(files)
        var document = LibraryDocument()
        document.files = files
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let raw = try encoder.encode(document)
        guard raw.count <= limit else { throw AppError(L10n.thisLibraryPackageExceedsItsSizeLimit) }
        guard compressed, !raw.isEmpty else { return raw }
        var output = Data(count: raw.count + raw.count / 16 + 65536)
        let capacity = output.count
        let count = output.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0, count + 16 < raw.count else { return raw }
        var size = UInt64(raw.count).littleEndian
        var packed = magic
        withUnsafeBytes(of: &size) { packed.append(contentsOf: $0) }
        packed.append(output.prefix(count))
        return packed
    }

    static func decode(_ data: Data, limit: Int = maximumBytes) throws -> [String: LibraryFile] {
        guard data.count <= limit else { throw AppError(L10n.thisLibraryPackageExceedsItsSizeLimit) }
        let raw: Data
        if data.starts(with: magic) {
            guard data.count > 16 else { throw AppError(L10n.theLibraryPackageIsIncomplete) }
            let expected = data[8..<16].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            guard expected > 0, expected <= UInt64(limit) else { throw AppError(L10n.theLibraryPackageHasAnInvalidSize) }
            var output = Data(count: Int(expected))
            let count = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, Int(expected),
                                              source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 16), data.count - 16, nil, COMPRESSION_LZFSE)
                }
            }
            guard count == Int(expected) else { throw AppError(L10n.theLibraryPackageIsDamaged) }
            raw = output
        } else { raw = data }
        let document = try PropertyListDecoder().decode(LibraryDocument.self, from: raw)
        guard document.version == 1 else { throw AppError(L10n.updateToOpenArchive) }
        try RimeLibrary.verify(document.files)
        return document.files
    }
}

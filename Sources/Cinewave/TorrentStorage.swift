import CryptoKit
import Foundation

/// Resolves a torrent source to the directory used by WebTorrent's durable store.
enum TorrentStorage {
    static func infoHash(for source: URL) -> String? {
        if source.isFileURL {
            if source.pathExtension.lowercased() == "torrent" {
                guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0, size <= 20 * 1_048_576,
                      let data = try? Data(contentsOf: source),
                      let infoRange = BencodeReader(data).infoRange else { return nil }
                return Insecure.SHA1.hash(data: data.subdata(in: infoRange))
                    .map { String(format: "%02x", $0) }.joined()
            }
            guard let text = try? String(contentsOf: source, encoding: .utf8) else { return nil }
            return infoHash(inMagnetText: text)
        }
        return infoHash(inMagnetText: source.absoluteString)
    }

    static func downloadDirectory(for source: URL, under root: URL) -> URL? {
        guard let hash = infoHash(for: source) else { return nil }
        return root.appendingPathComponent(hash, isDirectory: true)
    }

    static func downloadedFileURL(for file: TorrentFile, in directory: URL) -> URL? {
        let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let url = components.reduce(directory) { $0.appendingPathComponent(String($1)) }
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedDirectory.path + "/") else { return nil }
        return url
    }

    private static func infoHash(inMagnetText text: String) -> String? {
        guard let start = text.range(of: "magnet:?", options: .caseInsensitive) else { return nil }
        let magnet = text[start.lowerBound...]
            .prefix { !$0.isWhitespace && $0 != "\"" && $0 != "'" && $0 != "<" && $0 != ">" }
        guard let components = URLComponents(string: String(magnet)),
              components.scheme?.lowercased() == "magnet",
              let xt = components.queryItems?.first(where: { $0.name.lowercased() == "xt" })?.value,
              xt.lowercased().hasPrefix("urn:btih:") else { return nil }
        let value = String(xt.dropFirst("urn:btih:".count)).lowercased()
        if value.count == 40, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            return value
        }
        guard value.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var buffer = 0
        var bitCount = 0
        for character in value.utf8 {
            let digit: Int
            switch character {
            case 97...122: digit = Int(character - 97)
            case 50...55: digit = Int(character - 50) + 26
            default: return nil
            }
            buffer = (buffer << 5) | digit
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((buffer >> bitCount) & 0xff))
                buffer &= (1 << bitCount) - 1
            }
        }
        guard bytes.count == 20 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct BencodeReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var infoRange: Range<Int>? {
        var reader = self
        guard reader.take(100) else { return nil } // root dictionary
        var result: Range<Int>?
        while reader.offset < reader.bytes.count, reader.bytes[reader.offset] != 101 {
            guard let key = reader.readString() else { return nil }
            let start = reader.offset
            guard reader.skipValue(depth: 0) else { return nil }
            if key == Array("info".utf8) { result = start..<reader.offset }
        }
        guard reader.take(101), reader.offset == reader.bytes.count else { return nil }
        return result
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    private mutating func readString() -> [UInt8]? {
        var length = 0
        var hasDigit = false
        while offset < bytes.count, bytes[offset] >= 48, bytes[offset] <= 57 {
            hasDigit = true
            let digit = Int(bytes[offset] - 48)
            guard length <= (Int.max - digit) / 10 else { return nil }
            length = length * 10 + digit
            offset += 1
        }
        guard hasDigit, take(58), length <= bytes.count - offset else { return nil }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }

    private mutating func skipValue(depth: Int) -> Bool {
        guard depth < 64, offset < bytes.count else { return false }
        switch bytes[offset] {
        case 105: // integer
            offset += 1
            let start = offset
            while offset < bytes.count, bytes[offset] != 101 { offset += 1 }
            guard offset > start else { return false }
            return take(101)
        case 108: // list
            offset += 1
            while offset < bytes.count, bytes[offset] != 101 {
                guard skipValue(depth: depth + 1) else { return false }
            }
            return take(101)
        case 100: // dictionary
            offset += 1
            while offset < bytes.count, bytes[offset] != 101 {
                guard readString() != nil, skipValue(depth: depth + 1) else { return false }
            }
            return take(101)
        case 48...57:
            return readString() != nil
        default:
            return false
        }
    }
}

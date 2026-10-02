import Compression
import Foundation

/// A minimal, read-only ZIP reader for DOCX files, on Apple frameworks alone (no ZIPFoundation dependency).
///
/// It reads the central directory at the end of the file and inflates entries stored (method 0) or deflated
/// (method 8, raw DEFLATE, decoded in 64 KB steps with the Compression framework's `COMPRESSION_ZLIB` stream),
/// checking each entry's CRC-32. ZIP64, encryption and other methods are refused. Memory stays bounded even for a
/// malicious archive: an entry may declare at most `maximumEntrySize`, and inflation stops as soon as the output
/// passes the size the entry declares (a "zip bomb" that declares 1 KB is refused after its first 64 KB).
struct ZipArchiveReader {
    enum ZipError: Error, Equatable {
        case notAZipFile
        case unsupported(String)
        case damaged(String)
        case missingEntry(String)
        case tooLarge
    }

    struct Entry: Equatable {
        var name: String
        var method: UInt16
        var flags: UInt16
        var crc32: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    /// The largest single entry this reader inflates (a DOCX body is a few MB at most).
    static let maximumEntrySize = 128 * 1_024 * 1_024

    let data: Data
    let entries: [Entry]

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    /// The uncompressed bytes of the entry named `name`.
    func contents(of name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else { throw ZipError.missingEntry(name) }
        return try contents(of: entry)
    }

    func contents(of entry: Entry) throws -> Data {
        if entry.flags & 0x1 != 0 { throw ZipError.unsupported("encrypted entries") }
        guard entry.uncompressedSize <= Self.maximumEntrySize, entry.compressedSize <= Self.maximumEntrySize else {
            throw ZipError.tooLarge
        }
        let header = entry.localHeaderOffset
        guard Self.uint32(data, at: header) == 0x0403_4b50,
            let nameLength = Self.uint16(data, at: header + 26), let extraLength = Self.uint16(data, at: header + 28)
        else {
            throw ZipError.damaged("a file header is missing")
        }
        let start = header + 30 + Int(nameLength) + Int(extraLength)
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, start <= end else { throw ZipError.damaged("an entry is truncated") }
        let compressed = data[(data.startIndex + start)..<(data.startIndex + end)]

        let output: Data
        switch entry.method {
        case 0:
            output = Data(compressed)
        case 8:
            guard entry.uncompressedSize > 0 else {
                output = Data()
                break
            }
            output = try Self.inflate(compressed, limit: entry.uncompressedSize)
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard output.count == entry.uncompressedSize else { throw ZipError.damaged("an entry has the wrong size") }
        guard CRC32.checksum(output) == entry.crc32 else { throw ZipError.damaged("an entry failed its checksum") }
        return output
    }

    /// The bytes of a raw DEFLATE stream, decoded in 64 KB steps. Throws `.damaged("an entry has the wrong size")` as
    /// soon as the output would pass `limit` (the size the entry declares, at most `maximumEntrySize`), so memory never
    /// grows past it, and `.damaged("an entry could not be decompressed")` for a broken or truncated stream.
    static func inflate(_ compressed: Data, limit: Int) throws -> Data {
        let chunkSize = 64 * 1_024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { destination.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else {
            throw ZipError.damaged("an entry could not be decompressed")
        }
        defer { compression_stream_destroy(stream) }

        var output = Data()
        output.reserveCapacity(min(limit, maximumEntrySize))
        try compressed.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress, !source.isEmpty else {
                throw ZipError.damaged("an entry could not be decompressed")
            }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunkSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 {
                    guard output.count + produced <= limit else {
                        throw ZipError.damaged("an entry has the wrong size")
                    }
                    output.append(destination, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK where produced > 0 || stream.pointee.src_size > 0:
                    continue
                default:
                    // An error, or no progress with all input consumed: the stream is broken or cut short.
                    throw ZipError.damaged("an entry could not be decompressed")
                }
            }
        }
        return output
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22, uint32(data, at: 0) == 0x0403_4b50 || uint32(data, at: 0) == 0x0605_4b50 else {
            throw ZipError.notAZipFile
        }
        // The end-of-central-directory record is in the last 22 + 65,535 bytes (its comment can be that long).
        let lowest = max(0, data.count - 22 - 65_535)
        var eocd: Int?
        var position = data.count - 22
        while position >= lowest {
            if uint32(data, at: position) == 0x0605_4b50 {
                eocd = position
                break
            }
            position -= 1
        }
        guard let eocd, let count = uint16(data, at: eocd + 10), let directorySize = uint32(data, at: eocd + 12),
            let directoryOffset = uint32(data, at: eocd + 16)
        else {
            throw ZipError.notAZipFile
        }
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ZipError.unsupported("ZIP64 archives")
        }
        var entries: [Entry] = []
        var cursor = Int(directoryOffset)
        for _ in 0..<Int(count) {
            guard uint32(data, at: cursor) == 0x0201_4b50,
                let flags = uint16(data, at: cursor + 8), let method = uint16(data, at: cursor + 10),
                let crc = uint32(data, at: cursor + 16), let compressed = uint32(data, at: cursor + 20),
                let uncompressed = uint32(data, at: cursor + 24), let nameLength = uint16(data, at: cursor + 28),
                let extraLength = uint16(data, at: cursor + 30), let commentLength = uint16(data, at: cursor + 32),
                let offset = uint32(data, at: cursor + 42)
            else {
                throw ZipError.damaged("the file list is truncated")
            }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count else { throw ZipError.damaged("the file list is truncated") }
            let name = String(
                decoding: data[(data.startIndex + nameStart)..<(data.startIndex + nameEnd)], as: UTF8.self)
            entries.append(
                Entry(
                    name: name, method: method, flags: flags, crc32: crc, compressedSize: Int(compressed),
                    uncompressedSize: Int(uncompressed), localHeaderOffset: Int(offset)))
            cursor = nameEnd + Int(extraLength) + Int(commentLength)
        }
        return entries
    }

    // MARK: - Little-endian reads

    static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }
}

/// CRC-32 (IEEE 802.3, the ZIP checksum).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

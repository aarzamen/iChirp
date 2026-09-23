// Plan 022 Step 6: the ZIP container a .docx is (PKWARE APPNOTE 6.3.x, "stored" entries). Fresh implementation with
// Foundation only; no compression, so no third-party code: a Word document of text stays small either way.

import Foundation

public enum ZipWriterError: Error, Equatable {
    /// More than 65,535 entries or 4 GB: not needed for a document, and would need ZIP64.
    case tooLarge
}

/// Writes a ZIP archive of uncompressed ("stored") entries with CRC-32 checks and UTF-8 names.
struct ZipStoreWriter {
    private var data = Data()
    private var central = Data()
    private var count = 0

    /// 1980-01-01 00:00, the DOS epoch (the time inside a document is in its own properties).
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1

    mutating func add(path: String, contents: String) throws {
        try add(path: path, bytes: Data(contents.utf8))
    }

    mutating func add(path: String, bytes: Data) throws {
        let name = Data(path.utf8)
        guard count < 0xFFFF, data.count + bytes.count + name.count + 64 < 0xFFFF_FFFF else {
            throw ZipWriterError.tooLarge
        }
        let crc = CRC32.checksum(bytes)
        let offset = UInt32(data.count)
        let size = UInt32(bytes.count)
        let flags: UInt16 = 1 << 11  // names are UTF-8

        // Local file header.
        data.append(le32: 0x0403_4B50)
        data.append(le16: 20)  // version needed: 2.0
        data.append(le16: flags)
        data.append(le16: 0)  // stored
        data.append(le16: Self.dosTime)
        data.append(le16: Self.dosDate)
        data.append(le32: crc)
        data.append(le32: size)
        data.append(le32: size)
        data.append(le16: UInt16(name.count))
        data.append(le16: 0)
        data.append(name)
        data.append(bytes)

        // Central directory entry.
        central.append(le32: 0x0201_4B50)
        central.append(le16: 20)  // made by: 2.0
        central.append(le16: 20)
        central.append(le16: flags)
        central.append(le16: 0)
        central.append(le16: Self.dosTime)
        central.append(le16: Self.dosDate)
        central.append(le32: crc)
        central.append(le32: size)
        central.append(le32: size)
        central.append(le16: UInt16(name.count))
        central.append(le16: 0)  // extra
        central.append(le16: 0)  // comment
        central.append(le16: 0)  // disk
        central.append(le16: 0)  // internal attributes
        central.append(le32: 0)  // external attributes
        central.append(le32: offset)
        central.append(name)
        count += 1
    }

    /// The finished archive: entries, central directory, end record.
    mutating func finish() -> Data {
        var archive = data
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(le32: 0x0605_4B50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(count))
        archive.append(le16: UInt16(count))
        archive.append(le32: UInt32(central.count))
        archive.append(le32: centralOffset)
        archive.append(le16: 0)
        return archive
    }
}

/// CRC-32 (IEEE 802.3, the polynomial ZIP uses).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
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

extension Data {
    fileprivate mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

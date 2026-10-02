import XCTest

@testable import ChirpIngest

/// Review R2-3: the size cap holds for the bytes an entry really inflates to, not only for the sizes its header
/// declares. Archives are built at test time; nothing real.
final class ZipArchiveReaderTests: XCTestCase {
    /// A raw DEFLATE stream of `blocks` stored (uncompressed) blocks of 65,535 "A"s, then a block with the reserved
    /// type 3, which no decoder accepts.
    private static func storedBlocksThenGarbage(blocks: Int) -> Data {
        var stream = Data()
        for _ in 0..<blocks {
            stream.append(contentsOf: [0x00, 0xFF, 0xFF, 0x00, 0x00])  // not final, stored, LEN 65535, NLEN
            stream.append(Data(repeating: 0x41, count: 65_535))
        }
        stream.append(contentsOf: [0x07, 0xDE, 0xAD, 0xBE, 0xEF])  // final, type 3 (reserved): invalid
        return stream
    }

    /// The entry says it holds 1 KB but inflates to far more: the reader stops once the output passes the declared
    /// size. It never reaches the invalid tail, which a reader that inflates everything first would hit.
    func testInflationStopsOnceTheOutputPassesTheDeclaredSize() throws {
        let archive = SyntheticZip.make(rawEntries: [
            SyntheticZip.RawEntry(
                name: "word/document.xml", method: 8, payload: Self.storedBlocksThenGarbage(blocks: 4),
                declaredSize: 1_024, crc: 0)
        ])
        let reader = try ZipArchiveReader(data: archive)
        XCTAssertThrowsError(try reader.contents(of: "word/document.xml")) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .damaged("an entry has the wrong size"))
        }
    }

    /// A small "zip bomb": megabytes of zeros declared as 1 KB are refused as damaged.
    func testAnEntryLargerThanItsHeaderSaysIsRefused() throws {
        let zeros = Data(repeating: 0, count: 8 * 1_024 * 1_024)
        let packed = try (zeros as NSData).compressed(using: .zlib) as Data
        let archive = SyntheticZip.make(rawEntries: [
            SyntheticZip.RawEntry(
                name: "word/document.xml", method: 8, payload: packed, declaredSize: 1_024, crc: CRC32.checksum(zeros))
        ])
        XCTAssertThrowsError(try ZipArchiveReader(data: archive).contents(of: "word/document.xml")) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .damaged("an entry has the wrong size"))
        }
    }

    /// An entry that inflates to less than it declares is damaged too, and one that declares more than the cap is
    /// refused before anything is inflated.
    func testShortEntriesAndOversizedDeclarationsAreRefused() throws {
        let text = Data("<w:document/>".utf8)
        let packed = try (text as NSData).compressed(using: .zlib) as Data
        let short = SyntheticZip.make(rawEntries: [
            SyntheticZip.RawEntry(
                name: "a.xml", method: 8, payload: packed, declaredSize: text.count + 10, crc: CRC32.checksum(text))
        ])
        XCTAssertThrowsError(try ZipArchiveReader(data: short).contents(of: "a.xml")) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .damaged("an entry has the wrong size"))
        }
        let huge = SyntheticZip.make(rawEntries: [
            SyntheticZip.RawEntry(
                name: "a.xml", method: 8, payload: packed, declaredSize: ZipArchiveReader.maximumEntrySize + 1,
                crc: 0)
        ])
        XCTAssertThrowsError(try ZipArchiveReader(data: huge).contents(of: "a.xml")) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .tooLarge)
        }
    }

    /// A broken stream is reported as one that could not be decompressed.
    func testATruncatedStreamIsDamaged() throws {
        let text = Data(String(repeating: "Synthetic paragraph text. ", count: 400).utf8)
        let packed = try (text as NSData).compressed(using: .zlib) as Data
        let archive = SyntheticZip.make(rawEntries: [
            SyntheticZip.RawEntry(
                name: "a.xml", method: 8, payload: packed.prefix(packed.count / 2), declaredSize: text.count,
                crc: CRC32.checksum(text))
        ])
        XCTAssertThrowsError(try ZipArchiveReader(data: archive).contents(of: "a.xml")) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .damaged("an entry could not be decompressed"))
        }
    }

    /// Large real entries still inflate exactly, across many output chunks.
    func testALargeEntryInflatesExactly() throws {
        let text = Data((0..<600_000).map { UInt8(0x41 + $0 % 26) })
        let archive = SyntheticZip.make([("word/document.xml", text)])
        XCTAssertEqual(try ZipArchiveReader(data: archive).contents(of: "word/document.xml"), text)
    }
}

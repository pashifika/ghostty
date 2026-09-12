import Cocoa
import Testing
@testable import Ghostty

struct CodableBridgeTests {
    @Test func preparedStateRemainsReadableByThePreviousEnvelopeDecoder() throws {
        let expected = BridgeFixture(directory: "/tmp/captured")
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(try CodableBridge(preparing: expected), forKey: "state")
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        defer { unarchiver.finishDecoding() }
        unarchiver.setClass(
            LegacyCodableBridge.self,
            forClassName: NSStringFromClass(CodableBridge<BridgeFixture>.self))
        let restored = try #require(unarchiver.decodeObject(of: LegacyCodableBridge.self, forKey: "state"))
        #expect(restored.value == expected)
    }

    @Test func previousEnvelopeStillDecodes() throws {
        let expected = BridgeFixture(directory: "/tmp/previous")
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName(NSStringFromClass(CodableBridge<BridgeFixture>.self), for: LegacyCodableBridge.self)
        archiver.encode(LegacyCodableBridge(expected), forKey: "state")
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        defer { unarchiver.finishDecoding() }
        let restored = try #require(unarchiver.decodeObject(of: CodableBridge<BridgeFixture>.self, forKey: "state"))
        #expect(restored.value == expected)
    }

    @Test func preparationPropagatesEncodingFailure() {
        #expect(throws: EncodingFailure.rejected) {
            _ = try CodableBridge(preparing: UnencodableFixture())
        }
    }
}

private struct BridgeFixture: Codable, Equatable {
    let directory: String
}

private enum EncodingFailure: Error, Equatable {
    case rejected
}

private struct UnencodableFixture: Codable {
    func encode(to encoder: Encoder) throws {
        throw EncodingFailure.rejected
    }
}

@objc(GhosttyTestsLegacyCodableBridge)
private final class LegacyCodableBridge: NSObject, NSSecureCoding {
    let value: BridgeFixture

    init(_ value: BridgeFixture) { self.value = value }

    static var supportsSecureCoding: Bool { true }

    required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: "data") as? Data,
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data),
              let value = unarchiver.decodeDecodable(BridgeFixture.self, forKey: "value") else { return nil }
        self.value = value
    }

    func encode(with coder: NSCoder) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        try? archiver.encodeEncodable(value, forKey: "value")
        coder.encode(archiver.encodedData, forKey: "data")
    }
}

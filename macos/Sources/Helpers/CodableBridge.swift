import Cocoa

/// A wrapper that allows a Swift Codable to implement NSSecureCoding.
class CodableBridge<Wrapped: Codable>: NSObject, NSSecureCoding {
    private enum Storage {
        case value(Wrapped)
        case prepared(Data)
    }

    private let storage: Storage

    var value: Wrapped? {
        guard case .value(let value) = storage else { return nil }
        return value
    }

    init(_ value: Wrapped) {
        storage = .value(value)
    }

    /// Capture bytes without retaining or decoding live terminal surfaces.
    init(preparing value: Wrapped) throws {
        storage = .prepared(try Self.archive(value))
    }

    static var supportsSecureCoding: Bool { return true }

    required init?(coder aDecoder: NSCoder) {
        guard let data = aDecoder.decodeObject(of: NSData.self, forKey: "data") as? Data else { return nil }
        guard let archiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        defer { archiver.finishDecoding() }
        guard let value = archiver.decodeDecodable(Wrapped.self, forKey: "value") else { return nil }
        storage = .value(value)
    }

    func encode(with aCoder: NSCoder) {
        do {
            let data: Data
            switch storage {
            case .value(let value):
                data = try Self.archive(value)
            case .prepared(let prepared):
                data = prepared
            }
            aCoder.encode(data, forKey: "data")
        } catch {
            Ghostty.logger.error("Cannot encode restoration state: \(error.localizedDescription)")
        }
    }

    private static func archive(_ value: Wrapped) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        do {
            try archiver.encodeEncodable(value, forKey: "value")
        } catch {
            archiver.finishEncoding()
            throw error
        }
        archiver.finishEncoding()
        if let error = archiver.error { throw error }
        return archiver.encodedData
    }
}

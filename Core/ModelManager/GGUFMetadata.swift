import Foundation

/// Minimal reader for GGUF file headers (llama.cpp's format). Only the
/// metadata key-value section at the front of the file is parsed — weights
/// are multi-GB and never touched. Everything is little-endian, parsed
/// byte-by-byte so truncation or malformation yields nil/partial results
/// instead of a crash.
public struct GGUFMetadata: Sendable, Equatable {
    public var architecture: String?
    public var contextLength: Int?
    public var modelName: String?
    /// Transformer dimensions, needed to size the KV cache
    /// ("<arch>.block_count" etc.).
    public var blockCount: Int?
    public var embeddingLength: Int?
    public var attentionHeadCount: Int?
    public var attentionHeadCountKV: Int?
    /// "<arch>.nextn_predict_layers" — how many multi-token-prediction
    /// layers the model carries (Qwen3.5 MTP builds ship 1). Present means
    /// llama.cpp's `--spec-type draft-mtp` has tensors to draft with.
    public var mtpPredictLayers: Int?

    /// True when the GGUF ships MTP (nextn) layers for draft-mtp
    /// speculative decoding.
    public var supportsDraftMTP: Bool { (mtpPredictLayers ?? 0) > 0 }

    public init(architecture: String? = nil, contextLength: Int? = nil, modelName: String? = nil,
                blockCount: Int? = nil, embeddingLength: Int? = nil,
                attentionHeadCount: Int? = nil, attentionHeadCountKV: Int? = nil,
                mtpPredictLayers: Int? = nil) {
        self.architecture = architecture
        self.contextLength = contextLength
        self.modelName = modelName
        self.blockCount = blockCount
        self.embeddingLength = embeddingLength
        self.attentionHeadCount = attentionHeadCount
        self.attentionHeadCountKV = attentionHeadCountKV
        self.mtpPredictLayers = mtpPredictLayers
    }

    /// Header bytes read from disk. Metadata lives at the front of the file;
    /// 4 MB covers even tokenizer-heavy models without loading the weights.
    private static let headerLimit = 4 * 1024 * 1024

    /// Reads up to the first 4 MB of `url` and parses the GGUF header.
    /// Returns nil when the file can't be read or isn't GGUF.
    public static func read(from url: URL) -> GGUFMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLimit) else { return nil }
        return parse(data)
    }

    /// Parses GGUF header bytes. Returns nil when the fixed header (magic,
    /// version, counts) is missing or wrong; returns whatever was collected
    /// so far when a key-value pair is cut off mid-stream (a 4 MB window can
    /// truncate a very large tokenizer section after the keys we care about).
    public static func parse(_ data: Data) -> GGUFMetadata? {
        var r = Reader(data: data)
        guard r.readUInt32() == 0x46554747,  // "GGUF"
              r.readUInt32() != nil,         // version (any known layout parses the same)
              r.readUInt64() != nil,         // tensor_count
              let kvCount = r.readUInt64()
        else { return nil }

        var metadata = GGUFMetadata()
        // "<arch>.<suffix>" keys can arrive before "general.architecture",
        // so collect every candidate per suffix and resolve once parsing ends.
        let suffixes = [
            ".context_length", ".block_count", ".embedding_length",
            ".attention.head_count", ".attention.head_count_kv",
            ".nextn_predict_layers",
        ]
        var candidates: [String: [String: Int]] = [:]  // suffix → (key → value)

        kvLoop: for _ in 0..<kvCount {
            guard let key = r.readString(), let valueType = r.readUInt32() else { break }
            switch r.readValue(type: valueType) {
            case .string(let value):
                if key == "general.architecture" { metadata.architecture = value }
                else if key == "general.name" { metadata.modelName = value }
            case .int(let value):
                for suffix in suffixes where key.hasSuffix(suffix) {
                    candidates[suffix, default: [:]][key] = value
                }
            case .skipped:
                break
            case .truncated:
                break kvLoop  // keep whatever the intact prefix gave us
            }
        }

        /// Architecture-qualified match wins; a single unambiguous candidate
        /// is used when the architecture itself is unknown.
        func resolve(_ suffix: String) -> Int? {
            guard let group = candidates[suffix] else { return nil }
            if let architecture = metadata.architecture,
               let match = group["\(architecture)\(suffix)"] {
                return match
            }
            return group.count == 1 ? group.values.first : nil
        }

        metadata.contextLength = resolve(".context_length")
        metadata.blockCount = resolve(".block_count")
        metadata.embeddingLength = resolve(".embedding_length")
        metadata.attentionHeadCount = resolve(".attention.head_count")
        metadata.attentionHeadCountKV = resolve(".attention.head_count_kv")
        metadata.mtpPredictLayers = resolve(".nextn_predict_layers")
        return metadata
    }
}

// MARK: - Byte cursor

extension GGUFMetadata {
    private enum ValueResult {
        case string(String)
        case int(Int)
        case skipped     // well-formed value of a type we don't keep
        case truncated   // malformed or past EOF — stop parsing
    }

    private struct Reader {
        let data: Data
        var offset = 0

        var remaining: Int { data.count - offset }

        mutating func readUInt8() -> UInt8? {
            guard remaining >= 1 else { return nil }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readUInt16() -> UInt16? {
            guard remaining >= 2 else { return nil }
            defer { offset += 2 }
            return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }

        mutating func readUInt32() -> UInt32? {
            guard remaining >= 4 else { return nil }
            defer { offset += 4 }
            return UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
        }

        mutating func readUInt64() -> UInt64? {
            guard remaining >= 8 else { return nil }
            defer { offset += 8 }
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(data[offset + i]) << UInt64(i * 8)
            }
            return value
        }

        mutating func skip(_ count: UInt64) -> Bool {
            guard count <= UInt64(remaining) else { return false }
            offset += Int(count)
            return true
        }

        /// Length-prefixed (uint64) UTF-8 string.
        mutating func readString() -> String? {
            guard let length = readUInt64(), length <= UInt64(remaining) else { return nil }
            let start = offset
            offset += Int(length)
            return String(data: data[start..<offset], encoding: .utf8)
        }

        /// Skips `count` elements of `size` bytes with overflow-safe math.
        mutating func skipElements(_ count: UInt64, each size: UInt64) -> Bool {
            let (bytes, overflow) = count.multipliedReportingOverflow(by: size)
            guard !overflow else { return false }
            return skip(bytes)
        }

        /// Reads one metadata value of the given GGUF value type. Strings and
        /// integers are surfaced; everything else (floats, bools, arrays) is
        /// walked past so the next key still parses.
        mutating func readValue(type: UInt32) -> ValueResult {
            switch type {
            case 0, 1, 7:  // UINT8, INT8, BOOL
                return skip(1) ? .skipped : .truncated
            case 2:  // UINT16
                return readUInt16() != nil ? .skipped : .truncated
            case 3:  // INT16
                return readUInt16() != nil ? .skipped : .truncated
            case 4:  // UINT32
                guard let v = readUInt32() else { return .truncated }
                return .int(Int(v))
            case 5:  // INT32
                guard let v = readUInt32() else { return .truncated }
                return .int(Int(Int32(bitPattern: v)))
            case 6:  // FLOAT32
                return skip(4) ? .skipped : .truncated
            case 8:  // STRING
                guard let s = readString() else { return .truncated }
                return .string(s)
            case 9:  // ARRAY
                return skipArray() ? .skipped : .truncated
            case 10:  // UINT64
                guard let v = readUInt64() else { return .truncated }
                guard let i = Int(exactly: v) else { return .skipped }  // absurdly large, not malformed
                return .int(i)
            case 11:  // INT64
                guard let v = readUInt64() else { return .truncated }
                return .int(Int(Int64(bitPattern: v)))
            case 12:  // FLOAT64
                return skip(8) ? .skipped : .truncated
            default:  // unknown type — can't know its size, stop
                return .truncated
            }
        }

        /// ARRAY value: uint32 element type + uint64 count + elements. Scalar
        /// elements are skipped by byte size; string elements are walked one
        /// length prefix at a time. Arrays are never stored.
        mutating func skipArray() -> Bool {
            guard let elementType = readUInt32(), let count = readUInt64() else { return false }
            switch elementType {
            case 0, 1, 7: return skipElements(count, each: 1)
            case 2, 3: return skipElements(count, each: 2)
            case 4, 5, 6: return skipElements(count, each: 4)
            case 8:
                for _ in 0..<count {
                    guard readString() != nil else { return false }
                }
                return true
            case 10, 11, 12: return skipElements(count, each: 8)
            default: return false
            }
        }
    }
}

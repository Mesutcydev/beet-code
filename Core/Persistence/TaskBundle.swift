import CryptoKit
import Foundation

/// A portable, passphrase-protected handoff for one Beet Code task.
///
/// The workspace path is deliberately not part of the payload. A bundle can
/// only become an active session after the user chooses the destination
/// folder, which prevents a file received from another Mac from silently
/// binding the agent to an arbitrary local path.
struct TaskBundle: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let format = "com.beetcode.task-bundle"

    let format: String
    let version: Int
    let exportedAt: Date
    let workspaceHint: String
    let session: SessionRecord

    static func make(from record: SessionRecord, exportedAt: Date = Date()) -> TaskBundle {
        var portable = record
        portable.workspacePath = ""
        portable.checkpoints = []
        portable.messages = SessionStore.redactAndBound(record.messages)
        portable.source = .bundle
        portable.schemaVersion = SessionRecord.currentSchemaVersion

        return TaskBundle(
            format: Self.format,
            version: Self.currentVersion,
            // The wire format stores milliseconds; normalize before encoding
            // so an encode/decode round trip is value-stable.
            exportedAt: Date(timeIntervalSince1970: (exportedAt.timeIntervalSince1970 * 1_000).rounded() / 1_000),
            workspaceHint: URL(fileURLWithPath: record.workspacePath).lastPathComponent,
            session: portable)
    }
}

/// Errors are intentionally user-readable: a wrong passphrase must not look
/// like a corrupted workspace, and an unsupported future version must not be
/// imported as if it were a compatible task.
enum TaskBundleError: LocalizedError, Equatable {
    case passphraseRequired
    case passphraseTooShort
    case invalidContainer
    case unsupportedVersion(Int)
    case authenticationFailed
    case invalidPayload
    case workspaceRequired

    var errorDescription: String? {
        switch self {
        case .passphraseRequired:
            "Enter a passphrase to protect this task bundle."
        case .passphraseTooShort:
            "Use a passphrase with at least 8 characters."
        case .invalidContainer:
            "This file is not a Beet Code task bundle."
        case .unsupportedVersion(let version):
            "This task bundle uses an unsupported format version (\(version))."
        case .authenticationFailed:
            "The passphrase is incorrect, or the bundle was damaged."
        case .invalidPayload:
            "The task bundle contents are incomplete or invalid."
        case .workspaceRequired:
            "Choose an existing project folder before importing this task."
        }
    }
}

/// Passphrase-based AES-GCM container for portable task bundles.
///
/// CryptoKit does not expose PBKDF2 directly, so the small implementation
/// below uses PBKDF2-HMAC-SHA256 with a per-file random salt. The transcript
/// and tool output are encrypted; only the format version, salt, nonce, and
/// authentication tag are visible in the outer JSON container.
enum TaskBundleCodec {

    static let minimumPassphraseLength = 8

    private static let kdfName = "PBKDF2-HMAC-SHA256"
    private static let iterations = 120_000
    private static let minimumIterations = 50_000
    private static let maximumIterations = 500_000
    private static let saltLength = 16
    private static let nonceLength = 12
    private static let tagLength = 16

    private struct Container: Codable {
        let format: String
        let version: Int
        let kdf: String
        let iterations: Int
        let salt: Data
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    static func encode(_ bundle: TaskBundle, passphrase: String) throws -> Data {
        try validate(passphrase: passphrase)
        guard bundle.format == TaskBundle.format,
              bundle.version == TaskBundle.currentVersion
        else { throw TaskBundleError.unsupportedVersion(bundle.version) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(bundle)
        let salt = randomBytes(count: saltLength)
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            payload,
            using: key,
            nonce: nonce,
            authenticating: associatedData(version: TaskBundle.currentVersion))

        let container = Container(
            format: TaskBundle.format,
            version: TaskBundle.currentVersion,
            kdf: kdfName,
            iterations: iterations,
            salt: salt,
            nonce: Data(nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag)
        return try encoder.encode(container)
    }

    static func decode(_ data: Data, passphrase: String) throws -> TaskBundle {
        try validate(passphrase: passphrase)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let container = try? decoder.decode(Container.self, from: data),
              container.format == TaskBundle.format,
              container.kdf == kdfName,
              container.salt.count == saltLength,
              container.iterations >= minimumIterations,
              container.iterations <= maximumIterations,
              container.nonce.count == nonceLength,
              container.tag.count == tagLength,
              !container.ciphertext.isEmpty
        else { throw TaskBundleError.invalidContainer }

        guard container.version == TaskBundle.currentVersion else {
            throw TaskBundleError.unsupportedVersion(container.version)
        }

        let key = deriveKey(
            passphrase: passphrase,
            salt: container.salt,
            iterations: container.iterations)
        do {
            let nonce = try AES.GCM.Nonce(data: container.nonce)
            let sealed = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: container.ciphertext,
                tag: container.tag)
            let payload = try AES.GCM.open(
                sealed,
                using: key,
                authenticating: associatedData(version: container.version))
            let bundle = try decoder.decode(TaskBundle.self, from: payload)
            guard bundle.format == TaskBundle.format,
                  bundle.version == TaskBundle.currentVersion,
                  !bundle.session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw TaskBundleError.invalidPayload }
            return bundle
        } catch let error as TaskBundleError {
            throw error
        } catch {
            throw TaskBundleError.authenticationFailed
        }
    }

    /// Rebinds a decrypted bundle to an explicitly selected destination.
    /// Checkpoints are never copied because their tree hash belongs to the
    /// source workspace and could make Undo restore unrelated files.
    static func reboundSession(_ bundle: TaskBundle, workspace: URL) throws -> SessionRecord {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw TaskBundleError.workspaceRequired }

        var session = bundle.session
        session.id = UUID()
        session.workspacePath = workspace.standardizedFileURL.path
        session.source = .bundle
        session.checkpoints = []
        session.updatedAt = Date()
        session.schemaVersion = SessionRecord.currentSchemaVersion
        return session
    }

    private static func validate(passphrase: String) throws {
        guard !passphrase.isEmpty else { throw TaskBundleError.passphraseRequired }
        guard passphrase.count >= minimumPassphraseLength else {
            throw TaskBundleError.passphraseTooShort
        }
    }

    private static func associatedData(version: Int) -> Data {
        Data("\(TaskBundle.format):\(version)".utf8)
    }

    private static func randomBytes(count: Int) -> Data {
        let key = SymmetricKey(size: count == 16 ? .bits128 : .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    /// PBKDF2-HMAC-SHA256, RFC 8018 block 1. The iteration count is stored in
    /// the container so a future format can raise it without breaking old
    /// bundles; decoding rejects nonsensical counts before doing work.
    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        let passwordKey = SymmetricKey(data: Data(passphrase.utf8))
        var block = salt
        var counter = UInt32(1).bigEndian
        withUnsafeBytes(of: &counter) { block.append(contentsOf: $0) }

        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: passwordKey))
        var result = u
        guard iterations > 1 else { return SymmetricKey(data: result) }

        for _ in 1..<iterations {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
            for index in result.indices {
                result[index] ^= u[index]
            }
        }
        return SymmetricKey(data: result)
    }
}

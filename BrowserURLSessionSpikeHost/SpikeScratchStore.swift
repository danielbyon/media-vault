import Foundation

/// Disposable scratch storage for downloaded experiment files.
///
/// The background download delegate moves the system temporary file here
/// before it returns; hashing and reporting happen afterwards. Nothing in this
/// store is ever handed to the media library or the shipping vault.
final class SpikeScratchStore: @unchecked Sendable {
    private let lock = NSLock()
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Number of files currently retained in the disposable scratch tree.
    var fileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.count
    }

    /// Remove every scratch file and recreate the directory.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Destination for one download inside the scratch area.
    func destinationURL(role: String, profile: String, taskIdentifier: Int) -> URL {
        let directory = rootURL
            .appendingPathComponent(role, isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("task-\(taskIdentifier).download")
    }

    /// Move a system temporary download into the scratch area.
    ///
    /// The system deletes the temporary file as soon as the delegate method
    /// returns, so this must run synchronously inside the delegate callback.
    func moveSystemFile(at sourceURL: URL, to destinationURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    /// SHA-256 digest of a scratch file.
    func digest(of fileURL: URL) throws -> String {
        try Self.digestFile(at: fileURL)
    }

    /// SHA-256 digest of a file, usable off the main actor.
    static func digestFile(at fileURL: URL) throws -> String {
        SpikeHash.digest(try Data(contentsOf: fileURL))
    }

    /// Byte count of a scratch file.
    func byteCount(of fileURL: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil ?? 0
    }
}

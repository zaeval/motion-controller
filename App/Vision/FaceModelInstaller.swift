import CoreML
import Foundation
import os

/// Downloads AdaFace IR-18 and compiles it into Application Support, so face unlock and enrollment can be switched on
/// from inside the app.
///
/// The weights are deliberately not in the repo — non-commercial licence, about 44MB — so they have to arrive at
/// runtime somehow. That used to mean pasting commands into a terminal *and rebuilding the app*, which the user
/// (2026-09-14) asked to replace with a button. The rebuild was the worse half: a model downloaded into the source
/// tree only reaches the app the next time it is built, so they downloaded it and still couldn't enrol. Compiling it
/// here instead means enrollment opens the moment the download lands, with no build and no relaunch.
enum FaceModelInstaller {
    enum Step: Equatable, Sendable {
        case idle
        /// 0...1 of the download, or nil while the server hasn't said how big it is.
        case downloading(Double?)
        case compiling
        case installed
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Face")
    /// The same release the README points at.
    static let source = URL(
        string: "https://github.com/john-rocky/CoreML-Models/releases/download/adaface-v1/AdaFace_IR18.mlpackage.zip"
    )!
    static let modelName = "AdaFace_IR18"

    /// A model installed at runtime. `FaceSource` looks here before the app bundle, so a build that carries the model
    /// still works and an installed one wins.
    static var installedURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "MotionController/Models/\(modelName).mlmodelc", directoryHint: .isDirectory)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    /// Downloads, unpacks and compiles the model, reporting each step. Throws with a user-readable message.
    static func install(progress: @escaping @Sendable (Step) -> Void) async throws {
        progress(.downloading(nil))
        let zip = try await download(progress: progress)
        let scratch = zip.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: scratch) }
        progress(.compiling)
        let compiled = try await Task.detached(priority: .userInitiated) { try unpackAndCompile(zip, in: scratch) }.value
        try FileManager.default.createDirectory(
            at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // `replaceItemAt` throws when there is nothing to replace, which is every first install.
        if FileManager.default.fileExists(atPath: installedURL.path) {
            _ = try FileManager.default.replaceItemAt(installedURL, withItemAt: compiled)
        } else {
            try FileManager.default.moveItem(at: compiled, to: installedURL)
        }
        logger.notice("Face model installed at \(installedURL.path, privacy: .public)")
        progress(.installed)
    }

    /// Removes an installed model. The one built into the app bundle, if any, is untouched.
    static func remove() throws {
        guard isInstalled else { return }
        try FileManager.default.removeItem(at: installedURL)
        logger.notice("Installed face model removed")
    }

    private static func download(progress: @escaping @Sendable (Step) -> Void) async throws -> URL {
        let scratch = URL.temporaryDirectory.appending(path: "MotionController-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let destination = scratch.appending(path: "\(modelName).mlpackage.zip")
        let delegate = DownloadReporter { fraction in progress(.downloading(fraction)) }
        // A 44MB download deserves a progress bar, and only the delegate API reports bytes as they arrive.
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: source, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure("모델을 내려받지 못했습니다 (HTTP \(http.statusCode))")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Unzips the package, finds the `.mlpackage` inside it and compiles that. Blocking, so it runs off the main
    /// actor; `ditto` is used because Foundation has no unzip.
    private static func unpackAndCompile(_ zip: URL, in scratch: URL) throws -> URL {
        let unpacked = scratch.appending(path: "unpacked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        let errors = Pipe()
        ditto.standardError = errors
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure("압축을 풀지 못했습니다: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // The archive has the package at its root, but a re-zipped one can nest it under a folder.
        guard let package = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.pathExtension == "mlpackage" })
        else { throw Failure("내려받은 파일 안에 .mlpackage가 없습니다") }
        do {
            return try MLModel.compileModel(at: package)
        } catch {
            throw Failure("모델을 컴파일하지 못했습니다: \(error.localizedDescription)")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Reports download progress. `URLSession`'s async `download` still calls the delegate, so this only has to forward
/// the byte counts; the file itself comes back from the await.
private final class DownloadReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onFraction: @Sendable (Double?) -> Void

    init(onFraction: @escaping @Sendable (Double?) -> Void) {
        self.onFraction = onFraction
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            onFraction(nil)
            return
        }
        onFraction(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The async `download` moves the file itself; nothing to do here, but the method is required for progress.
    }
}

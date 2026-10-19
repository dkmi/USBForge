import Foundation
import Darwin

struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
func require(_ test: Bool, _ message: String) throws { if !test { throw Failure(message: message) } }
@discardableResult func run(_ path: String, _ args: [String], onOutput: ((Data) -> Void)? = nil, cancellation: OperationCancellation? = nil, interruptible: Bool = false) throws -> Data {
    try cancellation?.check()
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
    let out = Pipe(); process.standardOutput = out
    // Drain stdout before waiting, including large plist output.
    let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let err = try FileHandle(forWritingTo: errorURL)
    defer { try? err.close(); try? FileManager.default.removeItem(at: errorURL) }
    process.standardError = err
    try process.run()
    // Only interrupt self-contained tools such as wimlib. diskutil operations
    // finish their current step; cancellation is checked before the next step.
    let monitorQueue = DispatchQueue(label: "USBForge.childCancellation")
    let monitor = DispatchSource.makeTimerSource(queue: monitorQueue)
    monitor.schedule(deadline: .now(), repeating: .milliseconds(100))
    var terminationSent = false
    monitor.setEventHandler {
        if interruptible && cancellation?.isCancelled == true && !terminationSent && process.isRunning {
            terminationSent = true
            process.terminate()
        }
    }
    monitor.resume()
    defer { monitor.cancel(); monitorQueue.sync {} }
    var data = Data()
    while true {
        let chunk = out.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        if let onOutput { onOutput(chunk) } else { data.append(chunk) }
    }
    process.waitUntilExit()
    try cancellation?.check()
    try require(process.terminationStatus == 0, "Command failed: \(path)\n\((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "")")
    return data
}
func plist(_ data: Data) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Failure(message: "Invalid disk information") }; return value
}
func info(_ path: String) throws -> [String: Any] { try plist(run("/usr/sbin/diskutil", ["info", "-plist", path])) }
struct Disk: Identifiable, Hashable {
    let id: String; let name: String; let size: Int64
    var label: String { "\(name) — \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) (/dev/\(id))" }
}
func safeDisk(_ id: String) throws -> Disk {
    try require(id.range(of: "^disk[0-9]+$", options: .regularExpression) != nil, "Invalid disk identifier")
    let d = try info(id)
    try require((d["WholeDisk"] as? Bool ?? d["Whole"] as? Bool) == true && d["Internal"] as? Bool == false && d["BusProtocol"] as? String == "USB" && d["Writable"] as? Bool == true, "Target must be a writable, external, physical USB disk")
    try require(d["VirtualOrPhysical"] as? String == "Physical", "Virtual disks are not supported")
    return Disk(id: id, name: d["MediaName"] as? String ?? "USB", size: (d["TotalSize"] as? NSNumber)?.int64Value ?? 0)
}
func disks() throws -> [Disk] {
    let d = try plist(run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"]))
    return (d["WholeDisks"] as? [String] ?? []).compactMap { try? safeDisk($0) }
}

// Open-panel access belongs to the GUI process. Stage outside TCC-protected
// folders before invoking the independently authorized helper.
struct PreparedWrite {
    let directory: URL
    var image: URL { directory.appendingPathComponent("image.iso") }
    let helper: URL
    var progressURL: URL { directory.appendingPathComponent("progress.jsonl") }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
func prepareWrite(image: URL, helper: URL, progress: @escaping (TransferProgress) -> Void = { _ in }, cancellation: OperationCancellation? = nil) throws -> PreparedWrite {
    try cancellation?.check()
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("USBForge-" + UUID().uuidString, isDirectory: true)
    let prepared = PreparedWrite(directory: directory, helper: helper)
    try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
        try cancellation?.attach(to: directory)
        try cancellation?.check()
        let accessed = image.startAccessingSecurityScopedResource()
        defer { if accessed { image.stopAccessingSecurityScopedResource() } }
        let total = (try fm.attributesOfItem(atPath: image.path)[.size] as? NSNumber)?.int64Value ?? 0
        let input = try FileHandle(forReadingFrom: image); defer { try? input.close() }
        fm.createFile(atPath: prepared.image.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: prepared.image); defer { try? output.close() }
        let reporter = ProgressReporter(send: progress)
        var done: Int64 = 0
        reporter.update(TransferProgress(stage: "Preparing ISO", completed: 0, total: total))
        while let block = try input.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            try cancellation?.check()
            try output.write(contentsOf: block); done += Int64(block.count)
            reporter.update(TransferProgress(stage: "Preparing ISO", completed: done, total: total))
        }
        try cancellation?.check()
        try output.synchronize()
        fm.createFile(atPath: prepared.progressURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prepared.image.path)
        try require(fm.isExecutableFile(atPath: helper.path), "Bundled writer is missing or not executable")
        return prepared
    } catch { prepared.cleanup(); throw error }
}

struct TransferProgress: Codable {
    var stage: String
    var completed: Int64 = 0
    var total: Int64 = 0
    var detail: String = ""
    var destinationModified: Bool = false
    var fraction: Double? { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : nil }
}

// Limit updates to five per second; stage transitions and final counts are immediate.
final class ProgressReporter {
    private let send: (TransferProgress) -> Void
    private var lastTime = -Double.infinity
    private var lastStage = ""
    init(send: @escaping (TransferProgress) -> Void) { self.send = send }
    func update(_ value: TransferProgress) {
        let now = ProcessInfo.processInfo.systemUptime
        guard value.stage != lastStage || now - lastTime >= 0.2 || (value.total > 0 && value.completed >= value.total) else { return }
        lastTime = now; lastStage = value.stage; send(value)
    }
}

// The GUI creates the file. The root helper only appends to that existing,
// regular, non-symlink file and never creates a privileged arbitrary path.
func progressWriter(source: URL) throws -> FileHandle {
    let path = source.deletingLastPathComponent().appendingPathComponent("progress.jsonl").path
    let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0, "Cannot open progress channel")
    var metadata = stat()
    if fstat(fd, &metadata) != 0 || (metadata.st_mode & S_IFMT) != S_IFREG || metadata.st_nlink != 1 {
        Darwin.close(fd); throw Failure(message: "Invalid progress channel")
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

final class ProgressReader {
    private let file: FileHandle
    private var pending = Data()
    init(url: URL) throws { file = try FileHandle(forReadingFrom: url) }
    deinit { try? file.close() }
    func latest() -> TransferProgress? {
        pending.append(file.readDataToEndOfFile())
        var latest: TransferProgress?
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            if let event = try? JSONDecoder().decode(TransferProgress.self, from: line) { latest = event }
        }
        return latest
    }
}

// wimlib uses CR-delimited progress lines, including separate integrity passes.
// Only the selected operation's lines contribute to its percentage.
final class WIMProgressParser {
    private var pending = Data()
    private let prefix: String
    private let stage: String
    private let send: (TransferProgress) -> Void
    init(prefix: String, stage: String, send: @escaping (TransferProgress) -> Void) {
        self.prefix = prefix; self.stage = stage; self.send = send
    }
    func consume(_ data: Data) {
        pending.append(data)
        while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            guard line.hasPrefix(prefix),
                  let range = line.range(of: #"\([0-9]+%\)"#, options: .regularExpression),
                  let value = Int64(line[range].dropFirst().dropLast(2)) else { continue }
            send(TransferProgress(stage: stage, completed: value, total: 100, detail: line))
        }
    }
}

struct OperationCancelled: LocalizedError {
    var errorDescription: String? { "USBFORGE_CANCELLED" }
}

// GUI requests cancellation through a pre-created one-byte channel. The helper
// checks that channel between writes; the GUI never kills osascript and leaves
// an orphaned privileged writer running.
final class OperationCancellation {
    private let lock = NSLock()
    private var requested = false
    private var changed = false
    private var channel: FileHandle?
    private let remoteURL: URL?
    init(remoteURL: URL? = nil) { self.remoteURL = remoteURL }
    var isCancelled: Bool {
        lock.lock(); let local = requested; lock.unlock()
        if local { return true }
        guard let remoteURL else { return false }
        let fd = Darwin.open(remoteURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return true } // lost channel: stop rather than continue blindly
        defer { Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_nlink == 1 else { return true }
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) != 1 || byte != 0
    }
    var destinationMayHaveChanged: Bool { lock.lock(); defer { lock.unlock() }; return changed }
    func markDestinationChanged() { lock.lock(); changed = true; lock.unlock() }
    func check() throws { if isCancelled { throw OperationCancelled() } }
    func attach(to directory: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent("cancel.flag")
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0, "Cannot create cancellation channel")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data([requested ? 1 : 0]))
        channel = handle
    }
    func request() throws {
        lock.lock(); defer { lock.unlock() }
        if let channel {
            try channel.seek(toOffset: 0)
            try channel.write(contentsOf: Data([1]))
        }
        requested = true
    }
    deinit { try? channel?.close() }
}

enum DiskAccessState: Equatable { case available, denied, unknown }
func probeDiskAccess(path: String) -> DiskAccessState {
    // Access probe only: never read, query or modify the privacy database.
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
    if fd >= 0 { Darwin.close(fd); return .available }
    return errno == EPERM || errno == EACCES ? .denied : .unknown
}
func diskAccessState() -> DiskAccessState {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
    return probeDiskAccess(path: path)
}

func validateISO(_ url: URL) throws {
    try require(url.isFileURL && url.pathExtension.lowercased() == "iso", "Choose a single local ISO file.")
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    try require(values.isRegularFile == true, "Choose a single local ISO file.")
}

struct FriendlyIssue: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
func friendlyIssue(for error: Error) -> FriendlyIssue {
    let text = error.localizedDescription.lowercased()
    let ns = error as NSError
    if text.contains("(-128)") || ns.code == NSUserCancelledError {
        return FriendlyIssue(title: "Authorization cancelled", message: "Administrator authorization was declined. Try again and approve the macOS prompt to write the USB.")
    }
    if text.contains("permission") || text.contains("not permitted") || text.contains("errno=1 (") || text.contains("errno=13") || text.contains("access denied") {
        return FriendlyIssue(title: "Disk access blocked", message: "macOS blocked access to the image or USB. Enable Full Disk Access for this copy of USBForge, reopen it from Finder, and choose the ISO again. Also check whether the USB is write-protected.")
    }
    if text.contains("no space") || text.contains("does not fit") || text.contains("overhead") || ns.code == NSFileWriteOutOfSpaceError {
        return FriendlyIssue(title: "Not enough space", message: "The USB or your Mac does not have enough free space. Use a larger USB and allow space on your Mac for a temporary ISO copy.")
    }
    if text.contains("no hybrid") || text.contains("could not mount") || text.contains("no mountable") || text.contains("no uefi") || text.contains("installation media") {
        return FriendlyIssue(title: "Image or mode mismatch", message: "The ISO may be incomplete, unsupported, or selected in the wrong mode. Choose Linux for a hybrid Linux ISO and Windows for a Windows installer. If needed, download a fresh ISO.")
    }
    if text.contains("large file") || text.contains("install.esd") {
        return FriendlyIssue(title: "Windows image not supported", message: "This ISO contains a file that is too large for FAT32 and cannot be split by this app. Use a Windows ISO with install.wim instead of a large install.esd.")
    }
    if text.contains("answer file") || text.contains("architecture") {
        return FriendlyIssue(title: "Windows customization conflict", message: "The image already has custom Setup settings or its architecture is ambiguous. Turn off the TPM/Secure Boot bypass, or use an unmodified Windows ISO.")
    }
    if text.contains("verification") || text.contains("input/output") || text.contains("i/o error") {
        return FriendlyIssue(title: "USB write or verification failed", message: "The USB, its connection, or the ISO may be faulty. Reconnect it directly, try another USB port or drive, and verify the ISO download.")
    }
    if text.contains("usb changed") || text.contains("device changed") || text.contains("invalid disk") || text.contains("writable, external") {
        return FriendlyIssue(title: "USB is no longer available", message: "The selected device changed, disconnected, or is not writable. Reconnect it, refresh the list and select the destination again.")
    }
    if text.contains("unmount") || text.contains("eject") || text.contains("busy") {
        return FriendlyIssue(title: "USB is in use", message: "Another app may be using the USB. Close files and Finder windows on that drive, reconnect it and try again.")
    }
    if text.contains("bundled") || text.contains("helper") {
        return FriendlyIssue(title: "Application component missing", message: "A required bundled tool is missing or could not start. Rebuild the complete project and run the resulting USBForge app.")
    }
    if text.contains("single local iso") || text.contains("no such file") || ns.code == NSFileReadNoSuchFileError {
        return FriendlyIssue(title: "Select a valid ISO", message: "Choose or drop one local .iso file. Folders, multiple files and unavailable downloads cannot be used.")
    }
    return FriendlyIssue(title: "The operation could not finish", message: "The USB may be disconnected or busy, or the ISO may be unreadable. Reconnect the USB, select the image again and retry. Copy diagnostics if the problem continues.")
}

import Foundation

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("USBForge-tests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("input.iso")
let output = root.appendingPathComponent("output.iso")
let bytes = Data((0..<(12 * 1024 * 1024 + 127)).map { UInt8($0 % 251) })
try bytes.write(to: source)
var copies: [(String, Int64, Int64)] = []
try copyVerified(source, output) { copies.append(($0, $1, $2)) }
let copied = try Data(contentsOf: output)
precondition(copied == bytes)
for stage in ["Writing USB", "Verifying USB"] {
    let counts = copies.filter { $0.0 == stage }.map { $0.1 }
    precondition(counts.count >= 4 && counts.first == 0 && counts.last == Int64(bytes.count))
    precondition(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 })
}
print("PASS: streamed write/read-back progress and byte equality (ordinary files only)")

var staging: [TransferProgress] = []
let prepared = try prepareWrite(image: source, helper: URL(fileURLWithPath: "/usr/bin/true")) { staging.append($0) }
defer { prepared.cleanup() }
precondition(staging.first?.completed == 0 && staging.last?.completed == Int64(bytes.count))
let channel = try progressWriter(source: prepared.image)
let reader = try ProgressReader(url: prepared.progressURL)
let event = TransferProgress(stage: "Writing USB", completed: 5, total: 10)
let encoded = try JSONEncoder().encode(event)
try channel.write(contentsOf: encoded.prefix(encoded.count / 2))
precondition(reader.latest() == nil)
try channel.write(contentsOf: encoded.suffix(encoded.count - encoded.count / 2) + Data([10]))
precondition(reader.latest()?.fraction == 0.5)
try channel.close()
print("PASS: staging counts and incremental progress IPC tolerate partial messages")

let fakeSource = root.appendingPathComponent("fake/image.iso")
try fm.createDirectory(at: fakeSource.deletingLastPathComponent(), withIntermediateDirectories: true)
try fm.createSymbolicLink(at: fakeSource.deletingLastPathComponent().appendingPathComponent("progress.jsonl"), withDestinationURL: output)
do { _ = try progressWriter(source: fakeSource); fatalError("Accepted symlink progress channel") }
catch { print("PASS: symlink progress channel rejected") }

var parsed: [TransferProgress] = []
let parser = WIMProgressParser(prefix: "Splitting WIM:", stage: "Splitting Windows image") { parsed.append($0) }
let text = "\rCalculating integrity table for WIM: 100 KiB (100%) done\rSplitting WIM: 1 KiB of 2 KiB (50%) written\rSplitting WIM: 2 KiB of 2 KiB (100%) written\n"
for byte in text.utf8 { parser.consume(Data([byte])) }
precondition(parsed.map { $0.completed } == [50, 100])
print("PASS: fragmented WIM output parsed; unrelated integrity percentages ignored")

if CommandLine.arguments.count > 1 {
    var updates: [TransferProgress] = []
    let live = WIMProgressParser(prefix: "Verifying file data:", stage: "Verifying Windows image") { updates.append($0) }
    let tool = CommandLine.arguments[1]
    let fixture = root.appendingPathComponent("fixture")
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    try Data(repeating: 42, count: 1024 * 1024).write(to: fixture.appendingPathComponent("data.bin"))
    let wim = root.appendingPathComponent("fixture.wim").path
    try run(tool, ["capture", fixture.path, wim, "Fixture", "--compress=none", "--check"])
    try run(tool, ["verify", wim], onOutput: live.consume)
    precondition(updates.last?.completed == 100)
    print("PASS: bundled wimlib progress arrives through streaming subprocess output")
}

// Windows 11 Setup option: validate the generated XML and its narrow scope.
let windowsPaths = ["EFI/BOOT/BOOTX64.EFI", "sources/boot.wim", "sources/install.wim"]
let disabledAnswer = try windowsBypassAnswer(enabled: false, relativePaths: [])
precondition(disabledAnswer == nil)
let answer = try windowsBypassAnswer(enabled: true, relativePaths: windowsPaths)!
let document = try XMLDocument(data: answer)
let components = try document.nodes(forXPath: "//*[local-name()='component']")
precondition(components.count == 1)
precondition((components[0] as? XMLElement)?.attribute(forName: "processorArchitecture")?.stringValue == "amd64")
let commands = try document.nodes(forXPath: "//*[local-name()='RunSynchronousCommand']/*[local-name()='Path']").compactMap { $0.stringValue }
precondition(commands == [
    #"reg.exe add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f"#,
    #"reg.exe add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f"#
])
let eula = try document.nodes(forXPath: "//*[local-name()='AcceptEula']")
precondition(eula.first?.stringValue == "false")
let destructive = try document.nodes(forXPath: "//*[local-name()='DiskConfiguration' or local-name()='InstallTo' or local-name()='AutoLogon']")
precondition(destructive.isEmpty)
let arm = try windowsBypassAnswer(enabled: true, relativePaths: ["efi/boot/bootaa64.efi", "sources/boot.wim", "sources/install.esd"])!
precondition(String(decoding: arm, as: UTF8.self).contains("processorArchitecture=\"arm64\""))
for paths in [windowsPaths + ["AUTOUNATTEND.XML"], windowsPaths + ["unattend.xml"], windowsPaths + ["efi/boot/bootaa64.efi"], ["efi/boot/bootx64.efi"]] {
    do { _ = try windowsBypassAnswer(enabled: true, relativePaths: paths); fatalError("Unsafe/conflicting answer accepted") }
    catch { /* expected preflight rejection */ }
}
let testVolume = root.appendingPathComponent("usb-fixture")
try fm.createDirectory(at: testVolume, withIntermediateDirectories: true)
try installWindowsAnswer(answer, at: testVolume)
let installed = try Data(contentsOf: testVolume.appendingPathComponent("autounattend.xml"))
precondition(installed == answer)
do { try installWindowsAnswer(Data("replacement".utf8), at: testVolume); fatalError("Existing answer overwritten") }
catch { /* preserve existing answer */ }
let preserved = try Data(contentsOf: testVolume.appendingPathComponent("autounattend.xml"))
precondition(preserved == answer)
print("PASS: Windows bypass XML, x64/ARM64, opt-out, collisions, interactive setup and verified non-overwriting installation")

// Cancellation tests use ordinary temporary files and harmless child processes.
func expectCancelled(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Cancellation was ignored") }
    catch is OperationCancelled { }
    catch { fatalError("Unexpected cancellation error: \(error)") }
}
let beforeStart = OperationCancellation()
try beforeStart.request()
expectCancelled { _ = try prepareWrite(image: source, helper: URL(fileURLWithPath: "/usr/bin/true"), cancellation: beforeStart) }
let cancelDirectory = root.appendingPathComponent("cancel-channel")
try fm.createDirectory(at: cancelDirectory, withIntermediateDirectories: false)
let localCancel = OperationCancellation()
try localCancel.attach(to: cancelDirectory)
let remoteCancel = OperationCancellation(remoteURL: cancelDirectory.appendingPathComponent("cancel.flag"))
precondition(!remoteCancel.isCancelled)
try localCancel.request()
precondition(remoteCancel.isCancelled)
precondition(OperationCancellation(remoteURL: root.appendingPathComponent("missing.flag")).isCancelled)
let symlinkFlag = root.appendingPathComponent("symlink.flag")
try fm.createSymbolicLink(at: symlinkFlag, withDestinationURL: source)
precondition(OperationCancellation(remoteURL: symlinkFlag).isCancelled)
print("PASS: pre-start cancellation and fail-closed cancellation channel")

let partialOutput = root.appendingPathComponent("partial.iso")
let duringCopy = OperationCancellation()
expectCancelled {
    try copyVerified(source, partialOutput, progress: { stage, count, _ in
        if stage == "Writing USB" && count > 0 { try! duringCopy.request() }
    }, cancellation: duringCopy)
}
let partialSize = try size(partialOutput)
precondition(partialSize > 0 && partialSize < Int64(bytes.count))
let duringVerify = OperationCancellation()
expectCancelled {
    try copyVerified(source, output, progress: { stage, count, _ in
        if stage == "Verifying USB" && count > 0 { try! duringVerify.request() }
    }, cancellation: duringVerify)
}
let beforeFiles = Set(try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path))
let duringStage = OperationCancellation()
expectCancelled {
    _ = try prepareWrite(image: source, helper: URL(fileURLWithPath: "/usr/bin/true"), progress: { event in
        if event.completed > 0 { try! duringStage.request() }
    }, cancellation: duringStage)
}
let afterFiles = Set(try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path))
precondition(afterFiles.subtracting(beforeFiles).filter { $0.hasPrefix("USBForge-") }.isEmpty)
print("PASS: cancellation during write, verification and staging; temporary staging cleanup")

let subprocessCancel = OperationCancellation()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { try! subprocessCancel.request() }
let started = Date()
expectCancelled { try run("/bin/sleep", ["20"], cancellation: subprocessCancel, interruptible: true) }
precondition(Date().timeIntervalSince(started) < 3)
let boundaryCancel = OperationCancellation()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { try! boundaryCancel.request() }
let boundaryStart = Date()
expectCancelled { try run("/bin/sleep", ["0.3"], cancellation: boundaryCancel) }
precondition(Date().timeIntervalSince(boundaryStart) >= 0.25)
print("PASS: child process terminates and is reaped; noninterruptible operation stops at its boundary")

try validateISO(source)
let upperISO = root.appendingPathComponent("uppercase.ISO")
try Data([0]).write(to: upperISO)
try validateISO(upperISO)
for invalid in [root, URL(string: "https://example.com/image.iso")!, root.appendingPathComponent("missing.iso")] {
    do { try validateISO(invalid); fatalError("Invalid ISO accepted") } catch { }
}
precondition(probeDiskAccess(path: source.path) == .available)
precondition(probeDiskAccess(path: root.appendingPathComponent("absent.db").path) == .unknown)
for (raw, title) in [
    ("Command failed: /usr/bin/osascript\nPermission denied", "Disk access blocked"),
    ("hdiutil: attach failed - no mountable file systems", "Image or mode mismatch"),
    ("No space left on device", "Not enough space"),
    ("Verification failed", "USB write or verification failed"),
    ("execution error: User canceled. (-128)", "Authorization cancelled")
] { precondition(friendlyIssue(for: Failure(message: raw)).title == title) }
let changedEvent = TransferProgress(stage: "Cancelled", destinationModified: true)
let decoded = try JSONDecoder().decode(TransferProgress.self, from: JSONEncoder().encode(changedEvent))
precondition(decoded.destinationModified)
print("PASS: ISO validation, access-probe states, friendly errors and modified-destination IPC")

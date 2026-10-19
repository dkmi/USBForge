import Foundation
import Darwin

func openRaw(_ url: URL, writing: Bool) throws -> FileHandle {
    let fd = Darwin.open(url.path, (writing ? O_WRONLY : O_RDONLY) | O_CLOEXEC)
    guard fd >= 0 else {
        let code = errno
        let hint = (code == EPERM || code == EACCES)
            ? "\nmacOS denied raw disk access despite administrator authorization. Quit USBForge. In System Settings > Privacy & Security > Full Disk Access, add USBForge.app, enable access, then reopen the app directly from Finder. If launched through Xcode, test the standalone app first. Also check Files and Folders > Removable Volumes if listed."
            : ""
        throw Failure(message: "Cannot open \(url.path) for \(writing ? "writing" : "verification"): errno=\(code) (\(String(cString: strerror(code)))), euid=\(geteuid()). No bytes were transferred by this open operation." + hint)
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}
func size(_ url: URL) throws -> Int64 { (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
func copyVerified(_ source: URL, _ destination: URL, raw: Bool = false, progress: (String, Int64, Int64) -> Void = { _, _, _ in }, cancellation: OperationCancellation? = nil) throws {
    try cancellation?.check()
    let total = try size(source)
    var completed: Int64 = 0
    progress("Writing USB", 0, total)
    let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
    if !raw { FileManager.default.createFile(atPath: destination.path, contents: nil) }
    let output = try raw ? openRaw(destination, writing: true) : FileHandle(forWritingTo: destination); defer { try? output.close() }
    while let block = try input.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
        try cancellation?.check()
        try output.write(contentsOf: block); completed += Int64(block.count)
        progress("Writing USB", completed, total)
    }
    try cancellation?.check()
    progress("Flushing written data", 0, 0)
    try output.synchronize(); try output.close()
    try input.seek(toOffset: 0)
    completed = 0
    progress("Verifying USB", 0, total)
    let check = try raw ? openRaw(destination, writing: false) : FileHandle(forReadingFrom: destination); defer { try? check.close() }
    while let block = try input.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
        try cancellation?.check()
        var read = Data()
        while read.count < block.count {
            try cancellation?.check()
            let part = try check.read(upToCount: block.count - read.count) ?? Data()
            try require(!part.isEmpty, "Verification: unexpected end of destination"); read.append(part)
        }
        try require(read == block, "Verification failed")
        completed += Int64(block.count); progress("Verifying USB", completed, total)
    }
}
// Generate a minimal, interactive Windows PE answer file. Only the two
// requested Setup checks are changed; disk selection, licensing and accounts
// remain interactive. Root answer files are discovered by booted Windows Setup.
func windowsBypassAnswer(enabled: Bool, relativePaths: [String]) throws -> Data? {
    guard enabled else { return nil }
    let paths = Set(relativePaths.map { $0.lowercased() })
    try require(!paths.contains("autounattend.xml") && !paths.contains("unattend.xml"),
                "This ISO already contains a root answer file. Disable the bypass option or use an unmodified Windows ISO. The USB has not been erased or written.")
    try require(paths.contains("sources/boot.wim") && (paths.contains("sources/install.wim") || paths.contains("sources/install.esd") || paths.contains("sources/install.swm")),
                "The bypass option requires Windows installation media. The USB has not been erased or written.")
    let architectures = [("efi/boot/bootx64.efi", "amd64"), ("efi/boot/bootaa64.efi", "arm64")]
        .filter { paths.contains($0.0) }.map { $0.1 }
    try require(architectures.count == 1, "Cannot identify one supported Windows Setup architecture (x64 or ARM64). Disable bypass for this ISO. The USB has not been erased or written.")
    let architecture = architectures[0]
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="\(architecture)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <UserData>
            <AcceptEula>false</AcceptEula>
            <ProductKey><Key/><WillShowUI>Always</WillShowUI></ProductKey>
          </UserData>
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Path>reg.exe add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>2</Order>
              <Path>reg.exe add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    </unattend>
    """
    return Data(xml.utf8)
}

func installWindowsAnswer(_ data: Data, at volume: URL) throws {
    let destination = volume.appendingPathComponent("autounattend.xml")
    try data.write(to: destination, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    try handle.synchronize()
    let readBack = try Data(contentsOf: destination)
    try require(readBack == data, "Windows answer file verification failed")
}

func write() throws {
    let a = CommandLine.arguments
    try require(geteuid() == 0 && (a.count == 6 || a.count == 7), "Administrator authorization required")
    let bypassChecks = a.count == 7
    try require(!bypassChecks || (a[1] == "windows" && a[6] == "--bypass-tpm-secureboot"), "Invalid Windows Setup option")
    let source = URL(fileURLWithPath: a[2]).resolvingSymlinksInPath()
    try require(source.pathExtension.lowercased() == "iso", "Select an ISO file")
    let cancellation = OperationCancellation(remoteURL: source.deletingLastPathComponent().appendingPathComponent("cancel.flag"))
    try cancellation.check()
    let channel = try progressWriter(source: source); defer { try? channel.close() }
    var destinationModified = false
    var finished = false
    let reporter = ProgressReporter { event in
        if var data = try? JSONEncoder().encode(event) { data.append(10); try? channel.write(contentsOf: data) }
    }
    let report: (TransferProgress) -> Void = { event in
        var value = event; value.destinationModified = destinationModified
        reporter.update(value)
    }
    report(TransferProgress(stage: "Checking image and USB"))
    let selected = try safeDisk(a[3]); let expected = Int64(a[4]) ?? -1
    try require(selected.size == expected && selected.name == a[5], "USB device changed. Refresh and select it again.")
    let volume = try source.resourceValues(forKeys: [.volumeURLKey]).volume ?? source.deletingLastPathComponent()
    let backing = try info(volume.path)
    try require(backing["ParentWholeDisk"] as? String != selected.id && backing["DeviceIdentifier"] as? String != selected.id, "The ISO cannot be stored on the destination")
    try require(backing["Internal"] as? Bool == true, "Copy the ISO to the internal Mac disk before writing. External and network source volumes are not supported.")
    let bytes = try size(source)
    try require(bytes > 0 && bytes < selected.size, "The image does not fit on the USB")
    let device = "/dev/" + selected.id
    defer {
        if !finished {
            if destinationModified {
                report(TransferProgress(stage: "Stopping and ejecting USB"))
                _ = try? run("/bin/sync", [])
                _ = try? run("/usr/sbin/diskutil", ["unmountDisk", device])
                _ = try? run("/usr/sbin/diskutil", ["eject", device])
            }
            report(TransferProgress(stage: cancellation.isCancelled ? "Cancelled" : "Operation stopped"))
        }
    }
    try cancellation.check()
    if a[1] == "linux" {
        let file = try FileHandle(forReadingFrom: source); let header = try file.read(upToCount: 512) ?? Data(); try file.close()
        try require(header.count == 512 && header[510] == 0x55 && header[511] == 0xaa, "This ISO has no hybrid boot signature. Use a USB-compatible Linux hybrid ISO.")
        report(TransferProgress(stage: "Unmounting USB"))
        try run("/usr/sbin/diskutil", ["unmountDisk", device], cancellation: cancellation)
        try require(try safeDisk(selected.id) == selected, "USB changed")
        try cancellation.check()
        destinationModified = true
        try copyVerified(source, URL(fileURLWithPath: "/dev/r" + selected.id), raw: true, progress: { stage, done, total in
            report(TransferProgress(stage: stage, completed: done, total: total))
        }, cancellation: cancellation)
    } else {
        try require(a[1] == "windows", "Unknown mode")
        report(TransferProgress(stage: "Mounting Windows ISO"))
        try cancellation.check()
        let mounted: [String: Any]
        do {
            mounted = try plist(run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-plist", source.path]))
        } catch {
            if error is OperationCancelled { throw error }
            throw Failure(message: "Windows mode could not mount this ISO. If this is Ubuntu or another Linux distribution, select Linux · Hybrid ISO and retry. For a Windows ISO, check that the download is complete and that macOS can mount it. The USB has not been erased or written.\n" + error.localizedDescription)
        }
        let entities = mounted["system-entities"] as? [[String: Any]] ?? []
        guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first else { throw Failure(message: "ISO has no mountable filesystem") }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount]) }
        try cancellation.check()
        let root = URL(fileURLWithPath: mount)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw Failure(message: "Cannot read ISO") }
        let files = try enumerator.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        let relative: (URL) -> String = { String($0.path.dropFirst(root.path.count + 1)) }
        try require(files.contains { relative($0).lowercased().hasPrefix("efi/boot/boot") && $0.pathExtension.lowercased() == "efi" }, "Windows ISO has no UEFI bootloader")
        let answer = try windowsBypassAnswer(enabled: bypassChecks,
            relativePaths: files.map(relative) + fm.contentsOfDirectory(atPath: root.path))
        let large = try files.filter { try size($0) > 4_294_967_295 }
        try require(large.allSatisfy { relative($0).lowercased() == "sources/install.wim" }, "ISO contains a large file other than sources/install.wim; this image is unsupported")
        let bundledWim = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("wimlib-imagex").path
        let wim: String? = fm.isExecutableFile(atPath: bundledWim) ? bundledWim : nil
        try require(large.isEmpty || wim != nil, "The bundled WIM tool is missing. Rebuild USBForge; no Homebrew installation is needed.")
        let total = try files.reduce(Int64(0)) { try $0 + size($1) }
        try require(total + 536_870_912 < selected.size, "USB needs at least 512 MB of free overhead")
        try require(try safeDisk(selected.id) == selected, "USB changed")
        try cancellation.check()
        destinationModified = true
        report(TransferProgress(stage: "Formatting USB"))
        try run("/usr/sbin/diskutil", ["eraseDisk", "MS-DOS", "WINUSB", "GPT", device], cancellation: cancellation)
        let partition = try info(selected.id + "s2")
        guard let target = partition["MountPoint"] as? String else { throw Failure(message: "Cannot locate formatted USB partition") }
        let ordinary = files.filter { !large.contains($0) }
        let ordinaryTotal = try ordinary.reduce(Int64(0)) { try $0 + size($1) } * 2
        var processed: Int64 = 0
        for file in ordinary {
            try cancellation.check()
            let dest = URL(fileURLWithPath: target).appendingPathComponent(relative(file))
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyVerified(file, dest, progress: { stage, done, fileTotal in
                if fileTotal == 0 { return }
                let offset = stage == "Verifying USB" ? fileTotal : 0
                report(TransferProgress(stage: "Copying and verifying Windows files", completed: processed + offset + done, total: ordinaryTotal, detail: file.lastPathComponent))
            }, cancellation: cancellation)
            processed += try size(file) * 2
        }
        if let big = large.first, let tool = wim {
            let dest = URL(fileURLWithPath: target).appendingPathComponent("sources/install.swm")
            report(TransferProgress(stage: "Checking and splitting Windows image"))
            let splitProgress = WIMProgressParser(prefix: "Splitting WIM:", stage: "Splitting Windows image", send: report)
            try run(tool, ["split", big.path, dest.path, "3800", "--check"], onOutput: splitProgress.consume, cancellation: cancellation, interruptible: true)
            report(TransferProgress(stage: "Checking split image integrity"))
            let verifyProgress = WIMProgressParser(prefix: "Verifying file data:", stage: "Verifying Windows image", send: report)
            try run(tool, ["verify", dest.path, "--ref=" + dest.deletingLastPathComponent().appendingPathComponent("install*.swm").path], onOutput: verifyProgress.consume, cancellation: cancellation, interruptible: true)
        }
        if let answer {
            try cancellation.check()
            report(TransferProgress(stage: "Configuring Windows Setup", detail: "Bypassing TPM 2.0 and Secure Boot installation checks"))
            try installWindowsAnswer(answer, at: URL(fileURLWithPath: target))
        }
    }
    try cancellation.check()
    report(TransferProgress(stage: "Finishing and ejecting USB"))
    try run("/bin/sync", [], cancellation: cancellation)
    try run("/usr/sbin/diskutil", ["eject", device])
    finished = true
    report(TransferProgress(stage: "Complete", completed: 1, total: 1))
}

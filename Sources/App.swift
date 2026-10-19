import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var writing = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.writing else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "A USB operation is still running"
        alert.informativeText = "Use Cancel and wait for the operation to stop before quitting."
        alert.runModal()
        return .terminateCancel
    }
}
@main struct USBForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Window("USBForge", id: "main") { ContentView() }.windowResizability(.contentSize).defaultSize(width: 760, height: 700) }
}
struct ContentView: View {
    @State private var image: URL?
    @State private var devices: [Disk] = []
    @State private var selected = ""
    @State private var mode = "windows"
    @State private var bypassWindowsChecks = false
    @State private var busy = false
    @State private var progress: TransferProgress?
    @State private var confirm = false
    @State private var accessPrompt = false
    @State private var accessState: DiskAccessState = .unknown
    @AppStorage("diskAccessConfirmed") private var manualAccessConfirmation = false
    @AppStorage("diskAccessIntroductionShown") private var accessIntroductionShown = false
    @State private var dropTargeted = false
    @State private var cancelPrompt = false
    @State private var cancelRequested = false
    @State private var cancellation: OperationCancellation?
    @State private var issue: FriendlyIssue?
    @State private var diagnostic = ""
    @State private var status = "Choose an ISO image and a USB device."
    var disk: Disk? { devices.first { $0.id == selected } }
    private var modeDescription: String {
        mode == "windows"
            ? "UEFI installation media. Large install.wim files are split automatically. Large install.esd files are not supported."
            : "Direct write of a USB-compatible hybrid ISO. Match the image architecture to the target computer."
    }
    private var progressDetail: String {
        guard let progress else { return "Choose an ISO and USB device to begin." }
        if progress.total > 100 {
            return "\(ByteCountFormatter.string(fromByteCount: progress.completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))"
                + (progress.detail.isEmpty ? "" : " · " + progress.detail)
        }
        return progress.detail.isEmpty ? (busy ? "Keep the USB connected." : "See status for details.") : progress.detail
    }
    private func panel<Content: View>(height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content().padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("USBForge", systemImage: "externaldrive.badge.plus").font(.title.bold())
                Spacer()
                Text("Windows & Linux installation media").font(.callout).foregroundStyle(.secondary)
            }.frame(height: 36)

            panel(height: 130) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Mode").font(.headline).frame(width: 84, alignment: .leading)
                        Picker("Installation mode", selection: $mode) {
                            Text("Windows · UEFI / FAT32").tag("windows")
                            Text("Linux · Hybrid ISO").tag("linux")
                        }.pickerStyle(.segmented).labelsHidden()
                    }.frame(height: 24)
                    Text(modeDescription).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).frame(height: 26, alignment: .topLeading)
                    Toggle("Bypass TPM 2.0 and Secure Boot checks", isOn: $bypassWindowsChecks)
                        .toggleStyle(.checkbox).disabled(mode != "windows")
                        .frame(height: 18).help("Available only for Windows installation media.")
                    Text(mode == "windows"
                         ? "Windows 11 clean installs from USB only. Unsupported PCs may have compatibility issues and are not guaranteed updates. UEFI is required."
                         : "Windows Setup options are unavailable in Linux mode.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).frame(height: 26, alignment: .topLeading)
                }
            }.disabled(busy)

            panel(height: 62) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("ISO image").font(.headline).frame(width: 84, alignment: .leading)
                        Button("Browse…") { choose() }.fixedSize()
                        Text(image?.lastPathComponent ?? "No ISO selected")
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(image?.path ?? "Choose an ISO image").textSelection(.enabled)
                    }.frame(height: 24)
                    Text("Drop one ISO here or browse. Allow space on your Mac for a temporary copy.")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(height: 14)
                }
            }.disabled(busy)
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 2) }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: acceptDrop)

            panel(height: 80) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("USB device").font(.headline).frame(width: 84, alignment: .leading)
                        Menu {
                            Button("Select a USB device") { selected = "" }
                            ForEach(devices) { device in Button(device.label) { selected = device.id } }
                        } label: {
                            Text(disk?.label ?? "Select a USB device")
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.help(disk?.label ?? "Choose the destination USB device")
                    }.frame(height: 24)
                    HStack {
                        Button("Refresh devices", systemImage: "arrow.clockwise") { refresh() }
                        Spacer()
                        Button("Disk permissions…") { accessState = diskAccessState(); accessPrompt = true }
                    }.frame(height: 24)
                }
            }.disabled(busy)

            Label("All partitions and files on the selected USB will be erased.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange).lineLimit(1).frame(height: 20)

            panel(height: 76) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(progress?.stage ?? "Ready").font(.headline).lineLimit(1).truncationMode(.tail)
                            .help(progress?.stage ?? "Ready")
                        Spacer(minLength: 10)
                        Text(progress?.fraction.map { "\(Int($0 * 100))%" } ?? "—")
                            .monospacedDigit().frame(width: 48, alignment: .trailing)
                    }.frame(height: 18)
                    ZStack {
                        ProgressView(value: progress?.fraction ?? 0).progressViewStyle(.linear).tint(.cyan)
                            .opacity(busy && progress?.fraction == nil ? 0 : 1)
                        if busy && progress?.fraction == nil { ProgressView().progressViewStyle(.linear) }
                    }.frame(height: 8)
                    Text(progressDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(progressDetail)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 14)
                }
            }

            panel(height: 74) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Status").font(.caption.bold())
                        Spacer()
                        Button("Copy diagnostics") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnostic, forType: .string)
                        }.buttonStyle(.borderless).font(.caption).disabled(diagnostic.isEmpty)
                    }.frame(height: 16)
                    ScrollView(.vertical) {
                        Text(status).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }.frame(height: 35)
                }
            }

            HStack {
                Text(busy ? "Keep the app open and the USB connected." : "Confirm the destination before writing.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(cancelRequested ? "Stopping…" : "Cancel") { cancelPrompt = true }
                    .disabled(!busy || cancelRequested)
                Button("Write USB…", systemImage: "externaldrive.fill.badge.exclamationmark") {
                    checkAccess()
                    if accessState == .available || (accessState == .unknown && manualAccessConfirmation) { confirm = true }
                    else { accessPrompt = true }
                }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(image == nil || disk == nil || busy)
            }.frame(height: 34)
        }
        .padding(16).frame(width: 760, height: 700)
        .task {
            refresh(); checkAccess()
            accessPrompt = accessState == .denied || (accessState == .unknown && !manualAccessConfirmation && !accessIntroductionShown)
            if accessPrompt { accessIntroductionShown = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !busy { checkAccess() }
        }
        .onChange(of: busy) { value in
            AppDelegate.writing = value
            for window in NSApplication.shared.windows where window.title == "USBForge" {
                window.standardWindowButton(.closeButton)?.isEnabled = !value
            }
        }
        .alert(item: $issue) { item in Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK"))) }
        .sheet(isPresented: $accessPrompt) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Full Disk Access").font(.title2.bold())
                Text(accessState == .available ? "The access check passed." : accessState == .denied
                     ? "macOS is blocking access. Enable Full Disk Access for USBForge before writing a USB."
                     : "macOS did not provide a conclusive access result. Check that this copy of USBForge is enabled in Full Disk Access.")
                    .frame(height: 54, alignment: .topLeading)
                Text("Open System Settings → Privacy & Security → Full Disk Access. Add USBForge with + and enable it. Then quit and reopen the app if macOS asks you to.")
                    .frame(height: 64, alignment: .topLeading)
                HStack {
                    Button("Show app in Finder") { NSWorkspace.shared.selectFile(Bundle.main.bundlePath, inFileViewerRootedAtPath: "") }
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }
                }
                HStack {
                    Button("Later") { accessPrompt = false }.keyboardShortcut(.cancelAction)
                    Button("Check again") { checkAccess(); if accessState == .available { accessPrompt = false } }
                    Spacer()
                    if accessState == .unknown {
                        Button("I enabled access") { checkAccess(); if accessState != .denied { manualAccessConfirmation = true; accessPrompt = false } }
                    } else if accessState == .available { Button("Done") { accessPrompt = false } }
                }
            }.padding(24).frame(width: 560, height: 310)
        }
        .sheet(isPresented: $confirm) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Erase this USB and write the ISO?").font(.title2.bold())
                Text(disk?.label ?? "").lineLimit(2).truncationMode(.middle).frame(height: 40, alignment: .topLeading)
                Text("All partitions and files on this device will be permanently erased.")
                Text(mode == "windows" && bypassWindowsChecks
                     ? "Windows Setup: TPM 2.0 and Secure Boot checks will be bypassed."
                     : "The selected image will be written and verified.").font(.callout)
                HStack {
                    Button("NO") { confirm = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("YES", role: .destructive) { confirm = false; start() }
                }
            }.padding(24).frame(width: 540, height: 270)
        }
        .sheet(isPresented: $cancelPrompt) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cancel the operation?").font(.title2.bold())
                Text("If writing has started, the USB will contain incomplete data and must be formatted before you use it for anything else. Keep it connected until the operation stops.")
                HStack {
                    Button("NO") { cancelPrompt = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("YES", role: .destructive) {
                        cancelPrompt = false
                        guard busy else { return }
                        do {
                            try cancellation?.request(); cancelRequested = true
                            progress = TransferProgress(stage: "Stopping…")
                            status = "Waiting for the current disk operation to finish. Keep the USB connected. If an authorization prompt is open, dismiss it."
                        } catch { issue = FriendlyIssue(title: "Could not request cancellation", message: "The writer could not be notified. Keep the USB connected and try Cancel again."); diagnostic = error.localizedDescription }
                    }
                }
            }.padding(24).frame(width: 540, height: 220)
        }
    }
    func checkAccess() {
        accessState = diskAccessState()
        // Persist a successful probe or the user's explicit confirmation across
        // launches. An inconclusive probe must not revoke that confirmation.
        if accessState == .available { manualAccessConfirmation = true }
        else if accessState == .denied { manualAccessConfirmation = false }
    }
    func selectImage(_ url: URL) {
        guard !busy else { return }
        do {
            try validateISO(url); image = url
            let name = url.lastPathComponent.lowercased()
            let linuxNames = ["ubuntu", "kubuntu", "xubuntu", "lubuntu", "debian", "fedora", "linuxmint", "archlinux", "manjaro", "opensuse", "pop-os", "endeavouros", "kali-linux", "zorin"]
            if linuxNames.contains(where: { name.contains($0) }) { mode = "linux" }
            else if name.hasPrefix("win10") || name.hasPrefix("win11") { mode = "windows" }
            status = "ISO selected. Confirm the mode and USB destination."; progress = nil; diagnostic = ""
        } catch { issue = friendlyIssue(for: error) }
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy else { return false }
        guard providers.count == 1, let provider = providers.first else {
            issue = FriendlyIssue(title: "Select one ISO", message: "Drop a single local .iso file."); return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = item as? URL }
            DispatchQueue.main.async {
                if let url { selectImage(url) }
                else { issue = FriendlyIssue(title: "Cannot open dropped file", message: "Drop a local ISO from Finder, or use Browse.") }
            }
        }
        return true
    }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { selectImage(url) }
    }
    func refresh() {
        do { devices = try disks(); if !devices.contains(where: { $0.id == selected }) { selected = "" }; status = "USB devices found: \(devices.count)" }
        catch { let problem = friendlyIssue(for: error); status = problem.message; issue = problem; diagnostic = error.localizedDescription }
    }
    func start() {
        guard let image, let disk, let helper = Bundle.main.url(forResource: "USBForgeHelper", withExtension: nil) else { status = "The bundled writer is missing. Rebuild the project."; return }
        let selectedMode = mode
        let bypassChecks = mode == "windows" && bypassWindowsChecks
        let token = OperationCancellation()
        cancellation = token; cancelRequested = false; diagnostic = ""
        progress = TransferProgress(stage: "Preparing ISO")
        busy = true; status = "Preparing a temporary ISO copy… macOS will then request administrator authorization."
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            var helperInvoked = false
            var succeeded = false
            let update: (TransferProgress) -> Void = { event in
                if event.destinationModified { token.markDestinationChanged() }
                DispatchQueue.main.async { if busy && !cancelRequested { progress = event } }
            }
            do {
                let prepared = try prepareWrite(image: image, helper: helper, progress: update, cancellation: token)
                defer { prepared.cleanup() }
                let reader = try ProgressReader(url: prepared.progressURL)
                let progressQueue = DispatchQueue(label: "USBForge.progress")
                let timer = DispatchSource.makeTimerSource(queue: progressQueue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(200))
                timer.setEventHandler { if let event = reader.latest() { update(event) } }
                timer.resume()
                defer { timer.cancel(); progressQueue.sync { if let event = reader.latest() { update(event) } } }
                try token.check()
                update(TransferProgress(stage: "Waiting for administrator authorization"))
                let shellQuote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
                var arguments = [prepared.helper.path, selectedMode, prepared.image.path, disk.id, String(disk.size), disk.name]
                if bypassChecks { arguments.append("--bypass-tpm-secureboot") }
                let command = arguments.map(shellQuote).joined(separator: " ")
                let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let script = "do shell script \"" + literal + "\" with administrator privileges"
                DispatchQueue.main.async { status = "Writing and verifying… Do not disconnect the USB device." }
                try token.check()
                helperInvoked = true
                try run("/usr/bin/osascript", ["-e", script])
                succeeded = true
            } catch { failure = error }
            let success = succeeded
            let cancelled = !success && (token.isCancelled || failure is OperationCancelled || failure?.localizedDescription.contains("USBFORGE_CANCELLED") == true)
            let problem = failure.map { friendlyIssue(for: $0) }
            let details = failure?.localizedDescription ?? ""
            // Missing progress is not proof that the privileged writer never
            // touched the USB. Prefer the reformat warning when uncertain.
            let declinedAuthorization = details.contains("(-128)")
            let validatedBeforeWrite = details.contains("The USB has not been erased or written.")
            let modified = token.destinationMayHaveChanged || (helperInvoked && !declinedAuthorization && !validatedBeforeWrite)
            DispatchQueue.main.async {
                busy = false; cancellation = nil; cancelPrompt = false; diagnostic = details
                if success {
                    status = "USB is ready. Verification passed; device ejected."
                    progress = TransferProgress(stage: "Complete — USB ready", completed: 1, total: 1)
                } else if cancelled {
                    status = modified ? "Cancelled. Format the USB before using it for anything else." : "Cancelled before writing. The USB has not been changed."
                    progress = TransferProgress(stage: "Cancelled")
                    issue = FriendlyIssue(title: "Operation cancelled", message: status)
                } else {
                    status = (problem?.message ?? "The operation could not finish.") + (modified ? " The USB may contain incomplete data. Format it before using it for anything else." : " The USB has not been written.")
                    progress = TransferProgress(stage: "Operation stopped")
                    issue = FriendlyIssue(title: problem?.title ?? "Operation stopped", message: status)
                }
            }
        }
    }
}

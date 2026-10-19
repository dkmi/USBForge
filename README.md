# USBForge — macOS ISO → USB

Native SwiftUI Xcode project for macOS 13+, with an English interface.
Windows UEFI installation media and direct Linux hybrid ISO writing.

## Build and run — no Homebrew

1. Open `USBForge.xcodeproj` in Xcode.
2. Select **USBForge → My Mac**, and a signing team if needed.
3. Run with **⌘R**. The first build compiles the included wimlib source and may take a little longer. Nothing is downloaded during the build or at runtime.
4. Choose an ISO with **Browse…** or drop one local `.iso` file onto the ISO row, and select the correct installation mode. Recognizable Linux filenames select Linux mode automatically; this is a filename hint, not image analysis.
5. Select a USB device, check its name, capacity and disk identifier, and click **Write USB…** and confirm erasure with **YES** (or return with **NO**).
6. Authorize through macOS and keep the app open and the Mac awake until verification and ejection finish.

If replacing a previous revision after a build failure, use **Product → Clean Build Folder** (Shift–⌘K), then build again. Project folders may contain spaces. The build script invokes its local configure shim through `/bin/sh`, so extracted ZIP executable permissions do not affect it.

Builds use only Apple's Xcode toolchain and system build utilities. No Homebrew, MacPorts, separately installed wimlib, pkg-config, autotools or Swift packages are needed. The original wimlib 1.14.5 source archive is included in `Vendor/`, and Xcode builds and bundles the executable automatically. See `Vendor/NOTICE.md` for provenance and licenses.

Build on the Mac where the app will run: both helper executables currently target the build host architecture, Apple Silicon or Intel. A universal distribution is not provided.

## English, fixed interface

The content area is fixed at 760 × 700 points. There is no main scroll view and the window cannot be resized. Mode, image, destination, progress, status and Write USB controls have permanently allocated rows. Switching modes, selecting a long filename or USB name, receiving a lengthy error, or starting progress does not insert rows or move the Write USB button.

The Windows-only bypass checkbox remains in place but is disabled in Linux mode. Filenames and device names use a single truncated line with the complete value available in a tooltip. The progress area is always present, initially showing Ready. Only the status text scrolls inside its fixed area; its **Copy diagnostics** button copies the underlying technical error for troubleshooting. The status and error dialog show a short explanation of likely causes. The confirmation dialog also has fixed dimensions.

This layout was checked in the running app in Windows and Linux modes. A detached layout harness also measured the same 760 × 700 fitting size for idle, Linux and simulated writing states with long filenames and diagnostics. No USB write was performed during these UI checks.

## Live progress and app icon

A progress panel occupies a permanent fixed row above Status. It shows the current stage, percentage and processed byte counts where available. Percentages describe the current stage and restart when a new stage begins.

- Preparing ISO: actual bytes copied into the temporary image.
- Linux: actual bytes written, followed by a separate read-back verification stage.
- Windows: aggregate copying and verification progress for regular files, followed by wimlib split and verification percentages for a large WIM.
- Authorization, mounting, formatting, flushing and ejecting: indeterminate activity until the system operation finishes. No fabricated percentage or ETA is shown.

The helper appends throttled JSON progress events to a pre-created private channel; the GUI reads it every 200 ms. Errors stop the progress display and show a short, actionable message; technical details remain available through Copy diagnostics. Completion is shown only after successful ejection.

The original USB-and-write-arrow artwork is in `Assets.xcassets/AppIcon.appiconset`, including all ten standard macOS icon sizes. It is configured as the app icon for Debug and Release. Regenerate with `swift Scripts/generate-icon.swift .` from the project directory.

## Windows

Creates GPT + FAT32 installation media for UEFI PCs. Mounts the ISO read-only, checks for an EFI bootloader, copies regular files and compares each copy with its source. An `install.wim` over FAT32's 4 GiB file limit is split into 3800 MiB SWM files by the bundled wimlib-imagex tool, then the split WIM is verified.

Other files above the FAT32 limit, including a large `install.esd`, are rejected before erasure. Legacy BIOS boot, Windows To Go, automatic account creation and custom partition layouts are not implemented. The image architecture and target firmware must be compatible. Creating a Windows installer does not add Windows support to Apple Silicon Macs.

If ISO mounting fails, check that Windows mode is appropriate and that the download is complete. A mount failure happens before USB erasure. New macOS versions may print an hdiutil deprecation warning; hdiutil is retained for macOS 13 compatibility, and that warning alone does not mean a failure.

### Optional Windows 11 TPM / Secure Boot check bypass

Enable **Bypass TPM 2.0 and Secure Boot checks** in Windows mode before writing. It is off by default and also appears in the erasure confirmation. Boot the target PC from the created USB for a clean installation; launching setup.exe from an existing Windows installation is outside this feature's scope.

USBForge writes a minimal `autounattend.xml` to the USB root. During the `windowsPE` pass, `Microsoft-Windows-Setup/RunSynchronous` sets `BypassTPMCheck=1` and `BypassSecureBootCheck=1` under `HKLM\SYSTEM\Setup\LabConfig`. This uses the Setup registry approach also used by Rufus's answer-file fallback, rather than implementing all Rufus customizations.

Only these two checks are changed. Firmware Secure Boot settings are not modified. UEFI boot remains required by this application's GPT/FAT32 media layout. RAM, storage and CPU instruction requirements are not bypassed. Partition selection, license acceptance, product key and accounts remain interactive; no unattended target-disk erasure is configured.

Use an unmodified Windows 11 ISO. The helper detects x64 or ARM64 from the EFI bootloader and rejects ambiguous images or existing root answer files before USB erasure. It never overwrites an existing answer file. Customized ISOs can contain higher-priority embedded answer files and are not supported for this option.

Compatibility depends on the Windows build and hardware. Microsoft does not support installations on devices outside its requirements and does not guarantee updates. This option has passed XML, command-scope, architecture, opt-out, collision and read-back tests, but has not been tested by completing a Windows installation on a physical machine or VM.

References:
- https://github.com/pbatard/rufus/blob/master/src/wue.c
- https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-automation-overview?view=windows-11
- https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-setup-runsynchronous
- https://support.microsoft.com/en-us/windows/installing-windows-11-on-devices-that-don-t-meet-minimum-system-requirements-0b2dc4a2-5933-4ad4-9c09-ef0a331518f1

## Linux

Raw write to `/dev/rdiskN`, synchronization, full read-back byte comparison and eject. Requires an ISO with a hybrid MBR signature. This initial check does not prove bootability: use an official USB-compatible hybrid ISO for the target computer. Linux mode does not mount or extract the ISO.

## Permissions and safety

All partitions and files on the selected USB will be destroyed. USB hard drives and SSDs may also appear. Check the destination carefully. Internal, virtual, non-USB, read-only and partition targets are rejected. Device type, name and capacity are checked again before destructive work. Do not disconnect or replace devices while the operation starts or runs: these checks cannot eliminate all device replacement races.

The GUI first prepares a private temporary ISO copy on the internal startup disk, avoiding both protected source folder access from the root helper and source/target overlap. Allow space for a full ISO copy. The temporary directory is removed after success or failure; force-quitting can leave it for system temporary-file cleanup. The privileged helper stays at its stable bundled path.

Administrator authorization does not override macOS privacy policy. If raw device access fails with EPERM or EACCES:

1. Quit USBForge.
2. Add **USBForge.app** in **System Settings → Privacy & Security → Full Disk Access** and enable it.
3. Launch that same app directly from Finder. If testing through Xcode, locate it with **Product → Show Build Folder in Finder**, then `Products/Debug/USBForge.app`.
4. Check **Files and Folders → Removable Volumes** if present.

On launch and before writing, the app performs an access-only probe of the current user's protected TCC database, without reading its contents. If access is denied, writing is blocked and a Full Disk Access dialog offers **Open Settings**, **Show app in Finder**, and **Check again**. **Disk permissions…** opens the same dialog. Reopening the app after enabling access may be necessary.

macOS has no reliable public API to query or request Full Disk Access. This probe is a best-effort indication, not a guarantee for every file or the privileged helper. If the probe is inconclusive (for example, the database is absent), the app says so and allows the user to confirm **I enabled access** after checking System Settings. A successful check or explicit confirmation is remembered across launches. An inconclusive check does not reset it, and the introductory dialog is shown automatically only once for an inconclusive result. A definite access denial resets the saved confirmation and shows the dialog again. The app never grants itself permissions or changes privacy settings. Raw errno and helper details are retained only in diagnostics.

**Cancel** asks for YES / NO confirmation and warns that, once writing has started, the USB must be formatted before other use. Cancellation is supported during staging, copying, read-back verification and WIM processing. The GUI signals the helper through a private pre-created channel; it does not terminate osascript and abandon a running privileged writer. Formatting, mounting, synchronization and ejection finish their current system operation before stopping. Keep the USB connected while **Stopping…** is displayed. If an administrator prompt is waiting, dismiss it.

The app reports cancellation only after the helper has exited and attempted synchronization, unmounting and ejection. If cancelled before any destination writes, it reports that the USB was unchanged. If writing may have started, it displays the reformat warning. A completed write wins over a cancellation requested during final ejection. Ejection failure is reported even if copying succeeded. The app prevents normal quitting while an operation is active; use Cancel first. A forced quit or power loss can still interrupt the operation.

## Implementation

- `Sources/App.swift`: SwiftUI interface and administrator authorization via osascript.
- `Sources/Core.swift`: disk discovery, safety checks, staging and process execution.
- `Helper/Writer.swift`: privileged writer, progress reporting and verification; `Helper/main.swift`: executable entry point.
- `Scripts/build-wimlib.sh`: offline build of bundled WIM tool using Apple tools.
- `Vendor/`: original wimlib source and notices.

This is a local developer utility with App Sandbox disabled for raw device access. A distributed product should use a signed and notarized app with a dedicated ServiceManagement privileged service. The ZIP contains source, not a signed release.

## Validation

```sh
xcodebuild -project USBForge.xcodeproj -scheme USBForge -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Checks include compilation, USB discovery without elevation, rejection of internal disks/partitions/invalid identifiers, and temporary ISO staging and cleanup. The bundled WIM tool was exercised with 24 generated files: capture, split into eight SWM parts, verify, apply, and byte-for-byte comparison all passed. `otool -L` confirmed that its only dynamic dependency is macOS libSystem. Actual USB writes, Windows/Linux boot tests, and end-to-end macOS privacy authorization have not been completed.

References:
- https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/split-a-windows-image--wim--file-to-span-across-multiple-dvds?view=windows-11
- https://wimlib.net/
- Target Mac manuals: `man diskutil`, `man hdiutil`.

### Progress regression tests

Run `Tests/run.sh` with Apple's Swift toolchain. Optionally pass the built `USBForge.app/Contents/Resources/wimlib-imagex` path to exercise its live output. The tests use temporary ordinary files only: byte equality and monotonically increasing copy/verify counts, staging counts, partial IPC records, symlink rejection, fragmented WIM messages and live wimlib output. All passed for this revision. Xcode compiled the app and embedded `AppIcon.icns` successfully. Physical USB writes were not performed for that change; the subsequent fixed-layout revision was inspected visually as described above.

### Clean ZIP build regression

The build-path fix was verified by extracting the ZIP into `Extracted Project With Spaces`, with the pkg-config shim at mode 0644 (not executable), and building with a fresh DerivedData directory. The complete Xcode build succeeded, including wimlib, the privileged helper, SwiftUI and app assets. The bundled wimlib executable also ran successfully. No Homebrew tools were on the dependency build PATH.

### Usability and cancellation regression tests

The current revision builds successfully with Xcode. `Tests/run.sh` also checks cancellation before starting, midway through ordinary-file copying, during read-back, and during ISO staging with temporary-directory cleanup. It checks cross-process cancellation signaling, missing/symlink channels, termination and reaping of an interruptible child process, and cancellation at a noninterruptible operation boundary. ISO validation, access-probe outcomes, friendly error classification and destination-modified progress messages are covered. These tests use disposable files and harmless child processes, never a USB destination. The launch access dialog and fixed main window were inspected in the running app. Real USB cancellation and the user-granted Full Disk Access flow still require testing on the target Mac.

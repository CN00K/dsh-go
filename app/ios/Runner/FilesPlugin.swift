//  FilesPlugin.swift
//  MethodChannel `dsh/files` — iOS port of Android FilesPlugin.kt.
//
//  Files the agent made for the user (chat deliverables / artifacts).
//
//  - `resolveGuest {path}` → host path of a local-engine (iSH guest) file,
//    or null. The guest root is NOT one host directory: `/home/workspace`
//    is bind-mounted to `ISHRuntime.hostWorkspaceURL` (Application
//    Support/NativeNode/home/workspace), outside the rootfs data dir;
//    everything else (`/root`, `/tmp`, `/etc`, …) lives under
//    `RootfsManager.dataURL` (Application Support/iSH/rootfs/data).
//    `resolveGuest` maps each guest prefix to its host location.
//  - `listOutputs {depth}` → always [] on iOS: the outputs folder
//    (Documents/DSH-Go) is not part of the guest filesystem, so there is
//    no guest path for it. Saved files are visible in the Files app instead.
//  - `open {path, mime, name, chooser}` → UIDocumentInteractionController
//    "Open In" menu.
//  - `saveToDownloads {path, name, mime}` → copy into Documents/DSH-Go
//    (visible in the Files app, "On My iPhone > dsh-go > DSH-Go");
//    returns the shown location (`DSH-Go/x.pdf`).
//  - `pdfInfo {path}` → page sizes (PDF points); `pdfPage {path, page, width}`
//    → PNG bytes; `pdfClose` releases the open PDF.
//
//  Errors: `missing` (no such readable file), `no_app` (nothing opens this
//  type), `failed`.
//
//  Why this plugin exists: `dsh/files` was Android-only (FilesPlugin.kt).
//  On iOS every call threw MissingPluginException, which the Dart error
//  mapping turns into the generic "没能完成，再试一次" — so in the 文件 page
//  both 分享 and 保存到手机文件 failed for every local (iSH) artifact,
//  because both run materialize() → resolveGuest() first.

import Flutter
import PDFKit
import UIKit
import UniformTypeIdentifiers

public final class FilesPlugin: NSObject, FlutterPlugin, UIDocumentInteractionControllerDelegate {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dsh/files", binaryMessenger: registrar.messenger())
        let instance = FilesPlugin()
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    /// The iSH guest rootfs data dir (guest `/` maps here).
    private static var guestDataURL: URL { RootfsManager.dataURL }

    /// Where saved files land, visible in the Files app
    /// ("On My iPhone > dsh-go > DSH-Go").
    private static var outputsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSH-Go", isDirectory: true)
    }

    /// Retained while an "Open In" menu is on screen (the controller is
    /// deallocated if nothing holds it).
    private var interactionController: UIDocumentInteractionController?

    /// The currently open PDF (pdfInfo / pdfPage / pdfClose), if any.
    private var pdfDocument: PDFDocument?
    private var pdfPath: String?

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "resolveGuest":
            let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
            result(Self.resolveGuest(path)?.path)
        case "listOutputs":
            result([])
        case "open":
            open(call, result: result)
        case "saveToDownloads":
            saveToDownloads(call, result: result)
        case "pdfInfo":
            pdfInfo(call, result: result)
        case "pdfPage":
            pdfPage(call, result: result)
        case "pdfClose":
            pdfDocument = nil
            pdfPath = nil
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - resolveGuest

    /// Host file for an absolute guest [path]; null when it is not a
    /// readable regular file. Mirrors Android GuestFiles.resolve: walks
    /// the path segment by segment, following symlinks in the guest
    /// namespace (up to 16 links).
    ///
    /// The guest root is NOT one host directory (build 29 device test):
    /// `/home/workspace` is bind-mounted to
    /// `ISHRuntime.hostWorkspaceURL` (Application
    /// Support/NativeNode/home/workspace), outside the rootfs data dir,
    /// while everything else (`/root`, `/tmp`, `/etc`, …) lives under
    /// `RootfsManager.dataURL`. The walk therefore stays in guest
    /// coordinates and maps each prefix to its host location
    /// (`hostCandidates`), instead of joining every path onto the
    /// data dir. The old code looked for `/home/workspace/<file>` at
    /// `…/iSH/rootfs/data/home/workspace/<file>`, which does not
    /// exist — so every workspace file failed share/save as "missing"
    /// even though the file list (read through the guest, where the
    /// bind mount is visible) showed it. When the workspace mount
    /// failed at boot the guest wrote into `data/home/workspace`
    /// instead; that location is the second candidate, so those
    /// files still resolve.
    private static func resolveGuest(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var resolved: [String] = []
        var links = 0
        while !segments.isEmpty {
            let segment = segments.removeFirst()
            switch segment {
            case "", ".":
                continue
            case "..":
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            default:
                break
            }
            resolved.append(segment)
            // First host location that exists; a symlink there is
            // followed in the guest namespace (see below).
            let hosts = hostCandidates(forGuestSegments: resolved)
            guard let host = hosts.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            guard (try? host.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            links += 1
            guard links <= 16 else { return nil }
            guard var target = try? fm.destinationOfSymbolicLink(atPath: host.path) else { return nil }
            resolved.removeLast()
            if target.hasPrefix("/") {
                // Absolute guest target: restart from the guest root
                // (the target may live under a different host root,
                // e.g. a workspace link to /etc/hostname).
                resolved.removeAll()
            } else {
                // Relative target: splice it in place of the symlink.
                // ".." segments stay in the guest namespace and clamp
                // at the guest root, so they can never escape into the
                // wrong host tree.
                target = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let targetSegments = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            segments = targetSegments + segments
        }
        // Final file: first candidate that is a readable regular file.
        for host in hostCandidates(forGuestSegments: resolved) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: host.path, isDirectory: &isDir), !isDir.boolValue,
               fm.isReadableFile(atPath: host.path) {
                return host
            }
        }
        return nil
    }

    /// Host locations for a guest path ([segments] from the guest root),
    /// best first. `/home/workspace/…` is bind-mounted to the host
    /// workspace dir; when that mount failed at boot the guest wrote
    /// into `data/home/workspace` instead, so both are candidates.
    /// Any other guest path has exactly one location, under the
    /// rootfs data dir. A path like `/home/workspace2/…` is NOT a
    /// workspace path (exact second segment required).
    private static func hostCandidates(forGuestSegments segments: [String]) -> [URL] {
        if segments.count >= 2, segments[0] == "home", segments[1] == "workspace" {
            var workspace = ISHRuntime.hostWorkspaceURL
            for part in segments.dropFirst(2) { workspace.appendPathComponent(part) }
            var data = guestDataURL
            for part in segments { data.appendPathComponent(part) }
            return [workspace, data]
        }
        var data = guestDataURL
        for part in segments { data.appendPathComponent(part) }
        return [data]
    }

    // MARK: - saveToDownloads

    private func saveToDownloads(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let path = args?["path"] as? String ?? ""
        let name = Self.safeName(args?["name"] as? String ?? "")
        let fm = FileManager.default
        let source = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            result(FlutterError(code: "missing", message: "no such file", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try fm.createDirectory(at: Self.outputsURL, withIntermediateDirectories: true)
                let target = Self.unique(in: Self.outputsURL, name: name)
                try fm.copyItem(at: source, to: target)
                let shown = "DSH-Go/\(target.lastPathComponent)"
                DispatchQueue.main.async { result(shown) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - open

    private func open(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let path = args?["path"] as? String ?? ""
        let name = args?["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            result(FlutterError(code: "missing", message: "no such file", details: nil))
            return
        }
        let url = URL(fileURLWithPath: path)
        let controller = UIDocumentInteractionController(url: url)
        controller.name = name
        if let mime = args?["mime"] as? String, let type = UTType(mimeType: mime) {
            controller.uti = type.identifier
        }
        controller.delegate = self
        guard let host = Self.keyViewController() else {
            result(FlutterError(code: "failed", message: "no view controller to present from", details: nil))
            return
        }
        // Retain while on screen; released in documentInteractionControllerDidDismissOpenInMenu.
        interactionController = controller
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                result(FlutterError(code: "failed", message: "plugin released", details: nil))
                return
            }
            let presented = controller.presentOpenInMenu(
                from: host.view.bounds, in: host.view, animated: true)
            if presented {
                result(nil)
            } else {
                self.interactionController = nil
                result(FlutterError(code: "no_app", message: "no app opens this file", details: nil))
            }
        }
    }

    public func documentInteractionControllerDidDismissOpenInMenu(
        _ controller: UIDocumentInteractionController
    ) {
        if interactionController === controller { interactionController = nil }
    }

    private static func keyViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                return window.rootViewController
            }
        }
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
    }

    // MARK: - PDF

    private func pdfDocument(for path: String) -> PDFDocument? {
        if pdfPath == path, let doc = pdfDocument { return doc }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        pdfDocument = doc
        pdfPath = path
        return doc
    }

    private func pdfInfo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            guard let doc = self.pdfDocument(for: path) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "missing", message: "no such PDF", details: nil))
                }
                return
            }
            let sizes: [[String: Double]] = (0..<doc.pageCount).compactMap { index in
                guard let page = doc.page(at: index) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                return ["width": Double(bounds.width), "height": Double(bounds.height)]
            }
            DispatchQueue.main.async { result(sizes) }
        }
    }

    private func pdfPage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let path = args?["path"] as? String ?? ""
        let page = args?["page"] as? Int ?? 0
        let width = args?["width"] as? Int ?? 1080
        DispatchQueue.global(qos: .userInitiated).async {
            guard let doc = self.pdfDocument(for: path), let pdfPage = doc.page(at: page) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "missing", message: "no such PDF page", details: nil))
                }
                return
            }
            let bounds = pdfPage.bounds(for: .mediaBox)
            let scale = bounds.width > 0 ? CGFloat(width) / bounds.width : 1
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = pdfPage.thumbnail(of: size, for: .mediaBox)
            guard let png = image.pngData() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "failed", message: "could not render PDF page", details: nil))
                }
                return
            }
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: png)) }
        }
    }

    // MARK: - Helpers

    /// A file name without path separators or control characters
    /// (mirrors Android FilesPlugin.safeName).
    private static func safeName(_ name: String) -> String {
        let base = name.split(separator: "/").last.map(String.init) ?? ""
        let forbidden = CharacterSet(charactersIn: "\\:*?\"<>|").union(.controlCharacters)
        let cleaned = base.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "file" : cleaned
    }

    /// [name] in [dir], or `name (2).ext`, `name (3).ext`… when taken
    /// (mirrors Android FilesPlugin.unique).
    private static func unique(in dir: URL, name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }
}

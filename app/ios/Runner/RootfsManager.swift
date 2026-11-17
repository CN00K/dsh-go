//  RootfsManager.swift
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.2).
//
//  Formal port of the Stage 1 prototype RootfsInstaller.swift, plus:
//  - `.ready` marker (written last; isInstalled requires it — a crash
//    mid-install leaves no .ready, so the next launch re-extracts
//    instead of booting a half-written rootfs).
//  - zip SHA-256 marker (`.zip-sha256`): same hash = idempotent no-op;
//    different hash = upgradeRequiresReset, NEVER an automatic reset
//    (the guest's /root, /etc and apk packages live in this rootfs —
//    an upgrade wipes them, so it needs an explicit reset() call).
//  - meta.db verification + subtree re-registration (the shipped
//    meta.db normally comes with the zip; if its sentinel /bin/sh is
//    missing, the whole data/ tree is re-registered via
//    ish_fakefs_meta_register_subtree).
//  - rename-broken recovery: a failed delete / broken install is
//    renamed to `.rootfs-broken-<timestamp>` instead of blocking the
//    install (design §2.6: prefer leaking disk over blocking install).
//  - progress callback (0.0–1.0, delivered on the main queue).
//  - reset() (refuses while the kernel is booted — use
//    ISHKernel.resetRootfsWhileBooted for the booted case).
//
//  Rootfs home (design §2.6): Application Support/iSH/rootfs/
//  (permissions 0700), NOT ~/Documents — the Documents directory is
//  user-visible and a few hundred MB of rootfs would pollute it.
//  Layout inside rootfs/: data/ + meta.db + .arch + .zip-sha256 + .ready
//  The workspace (/home/workspace) is NOT pre-built here — it is a
//  bind-mount created at boot by the channel layer (ISHKernel
//  bindMountPath:). The guest's /root, /etc and apk packages persist
//  across app restarts; only a reset removes them.
//
//  The ZIP reader is the prototype's minimal reader (stored + deflate
//  only, no third-party dependency), including the commonPrefix fix
//  (commit 898bd735): the zip's first central-dir entry is the bare
//  top-level dir ("alpine-rootfs/"), which splits to a single
//  component — single-component entries must not vote on the prefix,
//  or nothing is stripped and data/ lands nested at alpine-rootfs/data/
//  (stage 1 build 10/11, test 1.1b).
//
//  Threading: call from one thread at a time (the channel layer calls
//  ensureInstalled once, on a background queue, before boot).
//  The progress closure is invoked on the main queue.

import Foundation
import CryptoKit

enum RootfsError: Error, LocalizedError {
    case missingZip
    case corruptZip(String)
    case ioError(String)
    case upgradeRequiresReset(currentHash: String, newHash: String)
    case kernelBooted

    var errorDescription: String? {
        switch self {
        case .missingZip:
            return "alpine-rootfs.zip 缺失：需先跑构建产出 IShArtifacts（见 ISHKernel.h 构建说明）"
        case .corruptZip(let m): return "rootfs zip 损坏：\(m)"
        case .ioError(let m): return "rootfs 安装 I/O 失败：\(m)"
        case .upgradeRequiresReset(let current, let new):
            return "rootfs 有新版本（zip 哈希变化），需重置后重装：当前 \(String(current.prefix(12)))，新 \(String(new.prefix(12)))。请先调用 reset()（内核未启动时）"
        case .kernelBooted:
            return "内核已启动，不能直接重置 rootfs。请先 stopGuest 并重启 App，或调用 ISHKernel.resetRootfsWhileBooted()"
        }
    }
}

enum RootfsInstallResult {
    case alreadyInstalled
    case installed
}

struct RootfsManager {
    /// Application Support/iSH/rootfs/ (design §2.6). 0700.
    static let rootfsURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("iSH/rootfs", isDirectory: true)
    }()

    static var ishDirURL: URL { rootfsURL.deletingLastPathComponent() }
    static var dataURL: URL { rootfsURL.appendingPathComponent("data", isDirectory: true) }
    static var metaDBURL: URL { rootfsURL.appendingPathComponent("meta.db") }
    static var archURL: URL { rootfsURL.appendingPathComponent(".arch") }
    static var readyURL: URL { rootfsURL.appendingPathComponent(".ready") }
    static var hashURL: URL { rootfsURL.appendingPathComponent(".zip-sha256") }

    /// Critical guest files the terminal needs to spawn a shell.
    /// A rootfs that lost these (partial delete, interrupted reset,
    /// corrupted extraction) still passes isInstalled + the hash
    /// marker, so the kernel boots fine (phase=running, loopback up)
    /// but do_execve("/bin/sh") fails and every terminal open dies
    /// with close 1011 — while a reinstall is a no-op because the
    /// hash matches. (Builds 25–37: terminal dead since build 25,
    /// build 24 reinstalled also failed, reset did not help.)
    /// Verified here so a broken tree is re-extracted, not booted.
    ///
    /// (Build 39) The build-38 check only covered bin/sh +
    /// bin/busybox, and the terminal STILL failed — so the breakage
    /// is in a file the shell needs but the old check never looked
    /// at. do_execve("/bin/sh") loads busybox through the dynamic
    /// linker, so a tree with bin/sh + bin/busybox present but the
    /// linker (or libc) missing/corrupt still boots fine and still
    /// dies on every shell spawn. The check now covers the whole
    /// spawn chain — shell, busybox, dynamic linker, libc, profile —
    /// and verifies the two binaries are not truncated (a partial
    /// extraction leaves a small or zero-byte file behind).
    /// Sizes are the shipped ones (busybox 919304, ld-musl 723480);
    /// the minimums leave room for a future Alpine bump.
    static var criticalGuestFiles: [String] {
        ["bin/sh", "bin/busybox", "lib/ld-musl-aarch64.so.1",
         "lib/libc.musl-aarch64.so.1", "etc/profile"]
    }

    /// Minimum byte sizes for the two real binaries (0 = any size,
    /// just existence). Symlinks (bin/sh, libc) and the profile are
    /// tiny by design and are only checked for existence.
    static var criticalGuestMinSizes: [String: UInt64] {
        ["bin/busybox": 500_000, "lib/ld-musl-aarch64.so.1": 500_000]
    }

    /// True when every critical guest file exists under data/ and
    /// the two binaries are not truncated.
    static func criticalFilesPresent() -> Bool {
        let fm = FileManager.default
        for rel in criticalGuestFiles {
            let path = dataURL.appendingPathComponent(rel).path
            guard fm.fileExists(atPath: path) else {
                NSLog("RootfsManager: 缺关键文件 \(rel)")
                return false
            }
            if let min = criticalGuestMinSizes[rel] {
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? UInt64, size >= min else {
                    NSLog("RootfsManager: 关键文件 \(rel) 尺寸异常（疑似截断）")
                    return false
                }
            }
        }
        return true
    }

    /// Installed = data/ exists, .arch reads "aarch64", and .ready
    /// exists (written last, so a crash mid-install is detected).
    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dataURL.path) else { return false }
        guard fm.fileExists(atPath: readyURL.path) else { return false }
        guard let arch = try? String(contentsOf: archURL, encoding: .utf8) else { return false }
        return arch.trimmingCharacters(in: .whitespacesAndNewlines) == "aarch64"
    }

    /// The zip SHA-256 recorded at install time, or nil when no install
    /// (or no hash marker) exists.
    static func installedHash() -> String? {
        guard let hash = try? String(contentsOf: hashURL, encoding: .utf8) else { return nil }
        let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func zipSHA256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// True when an install exists AND the bundled zip's hash differs
    /// from the installed one (i.e. an upgrade needs a reset first).
    /// False when not installed (ensureInstalled will install it) or
    /// when the hashes match.
    static func needsUpgrade(zipURL: URL? = nil) throws -> Bool {
        guard isInstalled else { return false }
        let zip = try resolveZipURL(zipURL)
        let data = try Data(contentsOf: zip)
        let current = zipSHA256(of: data)
        guard let installed = installedHash() else { return true }
        return installed != current
    }

    @discardableResult
    static func ensureInstalled(zipURL: URL? = nil,
                                progress: ((Double) -> Void)? = nil) throws -> RootfsInstallResult {
        let zip = try resolveZipURL(zipURL)
        let zipData: Data
        do {
            zipData = try Data(contentsOf: zip)
        } catch {
            throw RootfsError.ioError("读 zip 失败：\(error.localizedDescription)")
        }
        let hash = zipSHA256(of: zipData)
        reportProgress(progress, 0.05)
        if isInstalled {
            if installedHash() == hash {
                // Self-healing (build 38): the hash marker only proves
                // the zip is the same, not that the extracted tree is
                // intact. A tree missing bin/sh or bin/busybox boots
                // fine but can never spawn a shell (close 1011 on every
                // terminal open). Re-extract instead of booting it.
                if criticalFilesPresent() {
                    reportProgress(progress, 1.0)
                    return .alreadyInstalled
                }
                NSLog("RootfsManager: 已安装但缺关键文件（shell/动态链接器/libc/profile），重新解压")
                try clearBrokenInstall()
            } else {
                throw RootfsError.upgradeRequiresReset(currentHash: installedHash() ?? "(无)",
                                                       newHash: hash)
            }
        }
        // A broken / partial install is in the way: clear it (rename to
        // .rootfs-broken-<timestamp> when a delete fails) before
        // extracting, so a half-written tree is never booted.
        if FileManager.default.fileExists(atPath: rootfsURL.path) {
            try clearBrokenInstall()
        }
        let fm = FileManager.default
        // Extract to a temp sibling (same volume, so the move is an
        // atomic rename) and move into place only after verification.
        let tmp = ishDirURL
            .appendingPathComponent(".tmp-rootfs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: ishDirURL, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try extract(zipData: zipData, to: tmp, progress: progress)
        reportProgress(progress, 0.85)
        // Verify the extracted tree before moving it into place.
        guard fm.fileExists(atPath: tmp.appendingPathComponent("data", isDirectory: true).path) else {
            throw RootfsError.ioError("解压后校验失败：data/ 缺失")
        }
        guard fm.fileExists(atPath: tmp.appendingPathComponent("meta.db").path) else {
            throw RootfsError.corruptZip("zip 内缺失 meta.db")
        }
        try fm.createDirectory(at: rootfsURL, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Move the extracted tree into place.
        for item in try fm.contentsOfDirectory(atPath: tmp.path) {
            try fm.moveItem(at: tmp.appendingPathComponent(item),
                            to: rootfsURL.appendingPathComponent(item))
        }
        reportProgress(progress, 0.90)
        // Markers. .ready is written LAST — it is the "install complete"
        // signal isInstalled checks.
        try "aarch64".write(to: archURL, atomically: true, encoding: .utf8)
        try hash.write(to: hashURL, atomically: true, encoding: .utf8)
        try ensureMetaDB()
        reportProgress(progress, 0.95)
        _ = FileManager.default.createFile(atPath: readyURL.path, contents: Data())
        guard isInstalled else { throw RootfsError.ioError("解压后校验失败：data/、.arch 或 .ready 缺失") }
        // (Build 39) Verify the spawn chain actually landed: a
        // "successful" extraction that silently dropped the dynamic
        // linker (or truncated busybox) would boot fine and then fail
        // every shell spawn — the exact failure seen on builds 25–38.
        // Fail loudly here instead of booting a broken tree.
        guard criticalFilesPresent() else {
            throw RootfsError.ioError("解压后校验失败：关键文件（shell/动态链接器/libc/profile）缺失或截断")
        }
        reportProgress(progress, 1.0)
        return .installed
    }

    /// Delete the rootfs (fresh install on the next ensureInstalled).
    /// Refuses while the kernel is booted — a booted kernel has the
    /// rootfs mounted and its pid-1 supervisor parked on it; use
    /// ISHKernel.resetRootfsWhileBooted for that case, then relaunch.
    /// A delete failure falls back to renaming the tree to
    /// `.rootfs-broken-<timestamp>` (prefer leaking disk over blocking).
    static func reset() throws {
        if ISHKernel.shared.isBooted {
            throw RootfsError.kernelBooted
        }
        guard FileManager.default.fileExists(atPath: rootfsURL.path) else { return }
        try clearBrokenInstall()
    }

    /// Remove the rootfs tree (best effort, never throws) so the
    /// next app launch reinstalls it from the bundled zip. Used when
    /// the kernel is already booted on a broken tree: the kernel
    /// cannot reboot in-process, so the reinstall has to happen on
    /// the next launch. (Build 39)
    static func clearBrokenInstallForRestart() {
        try? clearBrokenInstall()
    }

    /// (Build 40) Restores ONLY the critical guest files that are
    /// missing (or truncated) from the bundled zip, in place, without
    /// touching meta.db and without deleting anything. Safe to call
    /// while the kernel is booted: the kernel reads guest files on
    /// demand through fakefs, so restoring the missing files lets the
    /// next shell spawn succeed. The shipped meta.db already records
    /// the correct modes (bin/sh is a symlink, busybox/ld-musl are
    /// 0755), so it is left alone — replacing it under a running
    /// kernel would risk SQLite inconsistency.
    ///
    /// This is the recovery for a tree that was deleted while booted
    /// (e.g. the user pressed Reset while the kernel was up): the old
    /// build-39 path deleted the tree and asked for an app restart,
    /// but tapping the app icon does not kill the process, so the
    /// kernel stayed booted, the files stayed gone, and the restart
    /// error fired forever. Restoring in place needs no restart.
    static func restoreMissingFiles() throws {
        let fm = FileManager.default
        // Which critical files actually need restoring?
        var missing: [String] = []
        for rel in criticalGuestFiles {
            let path = dataURL.appendingPathComponent(rel).path
            var needsRestore = !fm.fileExists(atPath: path)
            if !needsRestore, let min = criticalGuestMinSizes[rel] {
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? UInt64, size < min {
                    needsRestore = true
                }
            }
            if needsRestore { missing.append(rel) }
        }
        guard !missing.isEmpty else { return }
        NSLog("RootfsManager: 内核运行中，补回缺失的关键文件：%@", missing.joined(separator: ", "))
        let zip = try resolveZipURL(nil)
        let zipData = try Data(contentsOf: zip)
        let tmp = ishDirURL
            .appendingPathComponent(".tmp-rootfs-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: ishDirURL, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try extract(zipData: zipData, to: tmp, progress: nil)
        for rel in missing {
            let src = tmp.appendingPathComponent("data").appendingPathComponent(rel)
            let dst = dataURL.appendingPathComponent(rel)
            guard fm.fileExists(atPath: src.path) else {
                throw RootfsError.ioError("zip 内缺失关键文件 \(rel)，无法补回")
            }
            try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.moveItem(at: src, to: dst)
        }
        guard criticalFilesPresent() else {
            throw RootfsError.ioError("补回后校验失败：关键文件仍缺失或截断")
        }
        NSLog("RootfsManager: 关键文件已补回，内核无需重启")
    }

    // MARK: - Private

    private static func resolveZipURL(_ zipURL: URL?) throws -> URL {
        if let zipURL { return zipURL }
        guard let url = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
            throw RootfsError.missingZip
        }
        return url
    }

    private static func reportProgress(_ progress: ((Double) -> Void)?, _ fraction: Double) {
        guard let progress else { return }
        DispatchQueue.main.async { progress(fraction) }
    }

    /// Remove rootfsURL; on failure rename it to
    /// `.rootfs-broken-<timestamp>` in the same parent. Throws only
    /// when both the delete and the rename fail.
    private static func clearBrokenInstall() throws {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: rootfsURL)
            return
        } catch {
            // Delete failed — rename instead of blocking the install.
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let broken = ishDirURL
                .appendingPathComponent(".rootfs-broken-\(stamp)", isDirectory: true)
            do {
                try fm.moveItem(at: rootfsURL, to: broken)
                NSLog("RootfsManager: 旧 rootfs 删不掉，已改名到 %@", broken.lastPathComponent)
            } catch {
                throw RootfsError.ioError("清理旧 rootfs 失败（删与改名都失败）：\(error.localizedDescription)")
            }
        }
    }

    /// Verify the shipped meta.db is intact and re-register the tree
    /// when it is not. Sentinel: "/bin/sh" must be registered (the
    /// shipped meta.db has 520 paths including /bin, /bin/sh, /etc;
    /// "/" itself is NOT registered, so it must not be the sentinel).
    private static func ensureMetaDB() throws {
        let metaDBPath = metaDBURL.path
        guard FileManager.default.fileExists(atPath: metaDBPath) else {
            throw RootfsError.ioError("meta.db 缺失")
        }
        let exists = metaDBPath.withCString { dbPath in
            ish_fakefs_meta_path_exists(dbPath, "/bin/sh")
        }
        if exists == 1 { return }
        if exists == 0 {
            NSLog("RootfsManager: meta.db 缺少 /bin/sh，重新登记整棵 data/ 树")
            let rc = metaDBPath.withCString { dbPath in
                dataURL.path.withCString { dataPath in
                    ish_fakefs_meta_register_subtree(dbPath, dataPath, "/")
                }
            }
            guard rc == 0 else {
                throw RootfsError.ioError("meta.db 补登记失败 (rc=\(rc))")
            }
            return
        }
        throw RootfsError.ioError("meta.db 校验失败（sqlite 错误）")
    }

    // MARK: - Minimal ZIP reader (stored + deflate only)

    private struct CentralEntry {
        let name: String
        let method: UInt16
        let compSize: UInt32
        let uncompSize: UInt32
        let localOffset: UInt32
        let externalAttrs: UInt32
    }

    private static func extract(zipData data: Data, to dest: URL,
                                progress: ((Double) -> Void)?) throws {
        // Find End of Central Directory (PK\x05\x06) in the last 64 KiB + 22.
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let searchStart = data.count > 65557 ? data.count - 65557 : 0
        var eocd: Int? = nil
        if data.count >= 22 {
            for i in stride(from: data.count - 22, through: searchStart, by: -1) {
                if data[i] == sig[0] && data[i + 1] == sig[1] &&
                   data[i + 2] == sig[2] && data[i + 3] == sig[3] {
                    eocd = i
                    break
                }
            }
        }
        guard let eocdOff = eocd else { throw RootfsError.corruptZip("找不到 EOCD 记录") }
        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | (UInt16(data[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(data[o]) | (UInt32(data[o + 1]) << 8) |
            (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
        }
        let totalEntries = Int(u16(eocdOff + 10))
        let cdOffset = Int(u32(eocdOff + 16))
        guard totalEntries > 0, cdOffset + 46 <= data.count else {
            throw RootfsError.corruptZip("中央目录为空或越界")
        }
        var entries: [CentralEntry] = []
        var p = cdOffset
        for _ in 0..<totalEntries {
            guard p + 46 <= data.count,
                  data[p] == 0x50 && data[p + 1] == 0x4B &&
                  data[p + 2] == 0x01 && data[p + 3] == 0x02 else {
                throw RootfsError.corruptZip("中央目录损坏 @\(p)")
            }
            let method = u16(p + 10)
            let compSize = u32(p + 20)
            let uncompSize = u32(p + 24)
            let nameLen = Int(u16(p + 28))
            let extraLen = Int(u16(p + 30))
            let commentLen = Int(u16(p + 32))
            let extAttrs = u32(p + 38)
            let localOffset = u32(p + 42)
            guard p + 46 + nameLen <= data.count else { throw RootfsError.corruptZip("文件名越界") }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw RootfsError.corruptZip("文件名非 UTF-8")
            }
            entries.append(CentralEntry(name: name, method: method, compSize: compSize,
                                        uncompSize: uncompSize, localOffset: localOffset,
                                        externalAttrs: extAttrs))
            p += 46 + nameLen + extraLen + commentLen
        }
        // Strip the common top-level prefix (e.g. "alpine-rootfs/").
        let prefix = commonPrefix(of: entries.map { $0.name })
        let fm = FileManager.default
        var lastReported: Double = 0.05
        for (index, e) in entries.enumerated() {
            let rel = prefix.isEmpty ? e.name : String(e.name.dropFirst(prefix.count))
            if rel.isEmpty { continue }
            if e.name.hasSuffix("/") {
                try fm.createDirectory(at: dest.appendingPathComponent(rel),
                                       withIntermediateDirectories: true)
                continue
            }
            // Local header (PK\x03\x04) -> data start.
            let lo = Int(e.localOffset)
            guard lo + 30 <= data.count,
                  data[lo] == 0x50 && data[lo + 1] == 0x4B &&
                  data[lo + 2] == 0x03 && data[lo + 3] == 0x04 else {
                throw RootfsError.corruptZip("本地头损坏：\(e.name)")
            }
            let lhNameLen = Int(u16(lo + 26))
            let lhExtraLen = Int(u16(lo + 28))
            let dataStart = lo + 30 + lhNameLen + lhExtraLen
            guard dataStart + Int(e.compSize) <= data.count else {
                throw RootfsError.corruptZip("数据越界：\(e.name)")
            }
            let comp = data.subdata(in: dataStart..<(dataStart + Int(e.compSize)))
            let raw: Data
            switch e.method {
            case 0: raw = comp
            case 8:
                raw = try inflate(comp, expectedSize: Int(e.uncompSize))
            default:
                throw RootfsError.corruptZip("不支持的压缩方法 \(e.method)：\(e.name)")
            }
            let outURL = dest.appendingPathComponent(rel)
            try fm.createDirectory(at: outURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try raw.write(to: outURL, options: [])
            // Unix permissions from external attributes (high 16 bits).
            let mode = (e.externalAttrs >> 16) & 0xFFFF
            if mode != 0 {
                try? fm.setAttributes([.posixPermissions: mode & 0o7777],
                                      ofItemAtPath: outURL.path)
            }
            // Progress: 0.05 -> 0.85 across the entries, reported when
            // it moves by >= 0.01 (523 entries would otherwise spam
            // the main queue).
            let fraction = 0.05 + 0.80 * Double(index + 1) / Double(entries.count)
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                reportProgress(progress, fraction)
            }
        }
    }

    private static func commonPrefix(of names: [String]) -> String {
        let parts = names.filter { !$0.isEmpty }.map { $0.split(separator: "/") }
        // Ignore bare single-component entries (e.g. the top-level dir
        // "alpine-rootfs/" itself, which splits to ["alpine-rootfs"]):
        // they must not veto the prefix. Only entries with a real path
        // below the top level vote. (Build 10/1.1b: the first central-dir
        // entry is the bare top-level dir, so the old guard
        // `first.count > 1` returned "" and nothing was stripped —
        // data/ landed at alpine-rootfs/data/ and the post-extract
        // check failed.)
        let multi = parts.filter { $0.count > 1 }
        guard let first = multi.first else { return "" }
        let candidate = String(first[0])
        guard multi.allSatisfy({ $0.first.map(String.init) == candidate }) else { return "" }
        return candidate + "/"
    }

    private static func inflate(_ comp: Data, expectedSize: Int) throws -> Data {
        var out = Data(count: expectedSize)
        var outLen = 0
        let rc = comp.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                ish_zip_inflate_raw(src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                    comp.count,
                                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                    expectedSize, &outLen)
            }
        }
        guard rc == 0 else { throw RootfsError.corruptZip("deflate 解压失败 (rc=\(rc))") }
        out.count = outLen
        return out
    }
}

//  RootfsInstaller.swift
//  ISHCoexist — Stage 1 coexistence prototype
//
//  First-install of the Alpine fakefs rootfs from the bundled
//  `alpine-rootfs.zip` (staged by prepare-rootfs.sh into IShArtifacts;
//  NOT in git). Semantics follow OpenMinis RootfsManager.swift in
//  miniature: rootfs is ready when data/ exists and `.arch` reads
//  "aarch64"; the zip's common top-level prefix is stripped on extract.
//  This is a minimal stored/deflate ZIP reader (no third-party dep):
//  production RootfsManager (stage 2) replaces it with the full
//  implementation (progress, hash check, upgrade-requires-reset).
//
//  Rootfs home (design §2.6, dsh-go path):
//    Application Support/ISHCoexist/rootfs/  (data/ + meta.db + .arch)

import Foundation

enum RootfsError: Error, LocalizedError {
    case missingZip
    case corruptZip(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .missingZip:
            return "alpine-rootfs.zip 缺失：需先跑 build-ish.sh 与 prepare-rootfs.sh 产出 IShArtifacts（见 README 构建前置条件）"
        case .corruptZip(let m): return "rootfs zip 损坏：\(m)"
        case .ioError(let m): return "rootfs 安装 I/O 失败：\(m)"
        }
    }
}

enum RootfsInstallResult {
    case alreadyInstalled
    case installed
}

struct RootfsInstaller {
    static let rootfsURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("ISHCoexist/rootfs", isDirectory: true)
    }()

    static var dataURL: URL { rootfsURL.appendingPathComponent("data", isDirectory: true) }
    static var archURL: URL { rootfsURL.appendingPathComponent(".arch") }

    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dataURL.path) else { return false }
        guard let arch = try? String(contentsOf: archURL, encoding: .utf8) else { return false }
        return arch.trimmingCharacters(in: .whitespacesAndNewlines) == "aarch64"
    }

    @discardableResult
    static func ensureInstalled() throws -> RootfsInstallResult {
        if isInstalled { return .alreadyInstalled }
        guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
            throw RootfsError.missingZip
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("ishcoexist-rootfs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try extract(zipURL: zipURL, to: tmp)
        try fm.createDirectory(at: rootfsURL, withIntermediateDirectories: true)
        // Move the extracted tree into place (replacing a partial install).
        if fm.fileExists(atPath: rootfsURL.path) {
            try? fm.removeItem(at: rootfsURL)
            try fm.createDirectory(at: rootfsURL, withIntermediateDirectories: true)
        }
        for item in try fm.contentsOfDirectory(atPath: tmp.path) {
            try fm.moveItem(at: tmp.appendingPathComponent(item),
                            to: rootfsURL.appendingPathComponent(item))
        }
        try "aarch64".write(to: archURL, atomically: true, encoding: .utf8)
        guard isInstalled else { throw RootfsError.ioError("解压后校验失败：data/ 或 .arch 缺失") }
        return .installed
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

    private static func extract(zipURL: URL, to dest: URL) throws {
        let data = try Data(contentsOf: zipURL)
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
        func u16(_ o: Int) -> UInt16 { UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt16.self) }) }
        func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }) }
        let totalEntries = Int(u16(eocdOff + 10))
        let cdOffset = Int(u32(eocdOff + 16))
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
        for e in entries {
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

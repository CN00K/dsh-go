import CryptoKit
import Foundation

/// Pinned by the app build. Only the JavaScript/data archive is downloaded;
/// native engine frameworks remain in the signed application bundle.
struct RuntimeDownloadDescriptor: Codable {
  let schema: Int
  let url: String
  let sha256: String
  let bytes: Int
  let runtimeVersion: String
  let dshVersion: String
  let nodeVersion: String

  func validated() throws -> RuntimeDownloadDescriptor {
    guard schema == 1, RuntimeManifest.isSha256(sha256), bytes > 0, bytes <= 512 * 1024 * 1024,
      !runtimeVersion.isEmpty, !dshVersion.isEmpty, nodeVersion == "24.22.1",
      let address = URL(string: url), Self.allowed(address)
    else {
      throw EngineFailure("ios_download_config", "引擎下载配置无效，请更新 App 或联系开发者检查下载地址。")
    }
    return self
  }

  func matches(_ manifest: RuntimeManifest) -> Bool {
    manifest.runtimeVersion == runtimeVersion && manifest.dshVersion == dshVersion && manifest.nodeVersion == nodeVersion
  }

  func cachedURL(in cache: URL) -> URL {
    cache.appendingPathComponent("runtime-\(sha256).zip")
  }

  /// Call from an installation worker; the engine state queue remains responsive.
  func archive(in cache: URL, progress: @escaping (String, Int, Int) -> Void) throws -> RuntimeArchive {
    _ = try validated()
    let files = FileManager.default
    let destination = cachedURL(in: cache)
    do {
      try files.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var verified = false
      if files.fileExists(atPath: destination.path) {
        do {
          try verify(destination, progress: progress)
          verified = true
        } catch let failure as EngineFailure where failure.code == "ios_download_checksum" {
          try files.removeItem(at: destination)
        }
      }
      if !verified {
        let partial = cache.appendingPathComponent("runtime-\(sha256).part")
        if files.fileExists(atPath: partial.path) { try files.removeItem(at: partial) }
        defer { try? files.removeItem(at: partial) }
        try RuntimeDownload().run(descriptor: self, to: partial, progress: progress)
        try verify(partial, progress: progress)
        try files.moveItem(at: partial, to: destination)
      }
      let archive: RuntimeArchive
      do { archive = try RuntimeArchive(url: destination) }
      catch { throw EngineFailure("ios_download_archive", "引擎包格式无效，请更新 App 后重新安装。") }
      guard matches(archive.manifest) else {
        throw EngineFailure("ios_download_version", "下载的引擎版本与 App 不匹配，请更新 App 后重新安装。")
      }
      return archive
    } catch let failure as EngineFailure {
      throw failure
    } catch {
      throw EngineFailure("ios_download_io", "无法保存引擎包，请检查可用空间后重新安装。")
    }
  }

  private func verify(_ file: URL, progress: (String, Int, Int) -> Void) throws {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    var received = 0
    progress("verify-download", 0, bytes)
    while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
      received += chunk.count
      guard received <= bytes else {
        throw EngineFailure("ios_download_checksum", "引擎包大小校验失败，请重新安装。")
      }
      hasher.update(data: chunk)
      progress("verify-download", received, bytes)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard received == bytes, digest == sha256 else {
      throw EngineFailure("ios_download_checksum", "引擎包校验失败，请检查网络后重新安装。")
    }
  }

  fileprivate static func allowed(_ url: URL) -> Bool {
    guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else { return false }
    if url.scheme == "https" { return true }
    #if DEBUG
    return url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    #else
    return false
    #endif
  }
}

/// Mutable request state is owned by the serial URLSession delegate queue.
private final class RuntimeDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private var descriptor: RuntimeDownloadDescriptor!
  private var destination: URL!
  private var progress: ((String, Int, Int) -> Void)!
  private var failure: EngineFailure?
  private var received = false
  private let done = DispatchSemaphore(value: 0)

  func run(descriptor: RuntimeDownloadDescriptor, to destination: URL,
           progress: @escaping (String, Int, Int) -> Void) throws {
    self.descriptor = descriptor
    self.destination = destination
    self.progress = progress
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 300
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    guard let address = URL(string: descriptor.url) else {
      throw EngineFailure("ios_download_config", "引擎下载地址无效，请更新 App。")
    }
    let task = session.downloadTask(with: address)
    progress("download", 0, descriptor.bytes)
    task.resume()
    done.wait()
    if let failure { throw failure }
    guard received else {
      throw EngineFailure("ios_download_network", "未收到引擎包，请检查网络后重新安装。")
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    guard let address = request.url, RuntimeDownloadDescriptor.allowed(address) else {
      failure = EngineFailure("ios_download_redirect", "引擎下载跳转到了不安全的地址，请联系开发者检查下载源。")
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesWritten <= descriptor.bytes,
      totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite <= descriptor.bytes else {
      failure = EngineFailure("ios_download_checksum", "下载内容超过引擎包大小，请检查下载源后重试。")
      downloadTask.cancel()
      return
    }
    progress("download", Int(totalBytesWritten), descriptor.bytes)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard failure == nil else { return }
    guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
      failure = EngineFailure("ios_download_http", "引擎下载服务暂不可用，请稍后重新安装。")
      return
    }
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      received = true
    } catch {
      failure = EngineFailure("ios_download_io", "无法保存引擎包，请检查可用空间后重新安装。")
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if failure == nil, error != nil {
      failure = EngineFailure("ios_download_network", "引擎下载未完成，请检查网络后重新安装。")
    }
    done.signal()
  }
}

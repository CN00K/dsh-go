#!/usr/bin/env python3
"""Exercise the production Swift downloader against a local ZIP/HTTP fixture."""
import hashlib
import http.server
import io
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import threading
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
XCRUN = shutil.which("xcrun")
ENTRIES = (
    "node_modules/@deepseek-ai/dsh/lib/bin.js",
    "runtime/ohos/preload.mjs",
    "runtime/ohos/process/index.mjs",
    "runtime/ohos/process/sandbox.mjs",
    "runtime/ohos/lifecycle/index.mjs",
    "runtime/ohos/capabilities/index.mjs",
    "runtime/bridge/dsh-go-bridge/lib/index.js",
    "runtime/ohos/process/child-process.mjs",
)

SWIFT = r'''
import Foundation

struct CheckFailure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
  if !condition { throw CheckFailure(message: message) }
}
func expect(_ code: String, _ body: () throws -> Void) throws {
  do {
    try body()
    throw CheckFailure(message: "Expected \(code), but operation succeeded")
  } catch let failure as EngineFailure {
    try check(failure.code == code, "Expected \(code), received \(failure.code)")
  }
}

do {
  let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  let mode = CommandLine.arguments[2]
  let descriptor = try JSONDecoder().decode(RuntimeDownloadDescriptor.self,
    from: Data(contentsOf: directory.appendingPathComponent("descriptor.json")))
  let cache = directory.appendingPathComponent("cache", isDirectory: true)
  let archiveURL = descriptor.cachedURL(in: cache)
  if mode == "release-http" || mode == "invalid-config" {
    try expect("ios_download_config") { _ = try descriptor.validated() }
  } else if mode == "http" || mode == "checksum" || mode == "size" || mode == "version" || mode == "redirect" {
    let code = ["http": "ios_download_http", "checksum": "ios_download_checksum",
      "size": "ios_download_checksum", "version": "ios_download_version", "redirect": "ios_download_redirect"][mode]!
    try expect(code) { _ = try descriptor.archive(in: cache) { _, _, _ in } }
    if mode != "version" {
      try check(!FileManager.default.fileExists(atPath: archiveURL.path), "Rejected download was cached")
    }
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
    try check(!remaining.contains(where: { $0.hasSuffix(".part") }), "Failed download left partial bytes")
  } else {
    if mode == "corrupt-cache" {
      try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
      try Data("corrupt cached archive".utf8).write(to: archiveURL)
    }
    var steps = Set<String>()
    let archive = try descriptor.archive(in: cache) { step, done, total in
      steps.insert(step)
      precondition(done >= 0 && done <= total)
    }
    try check(descriptor.matches(archive.manifest), "Wrong manifest returned")
    try check(steps.contains("download") && steps.contains("verify-download"), "Missing download/verification progress")
    let extracted = directory.appendingPathComponent("extracted.mjs")
    try archive.extract(archive.manifest.files[0], to: extracted)
    try check(try String(contentsOf: extracted, encoding: .utf8) == "// download fixture\n",
      "Downloaded ZIP member did not extract")
    if mode == "cache" {
      var downloadedAgain = false
      _ = try descriptor.archive(in: cache) { step, _, _ in if step == "download" { downloadedAgain = true } }
      try check(!downloadedAgain, "Verified cache was downloaded again")
    }
  }
  print("PASS \(mode)")
} catch let failure as EngineFailure {
  print("FAIL \(failure.code): \(failure.message)")
  exit(1)
} catch {
  print("FAIL \(error)")
  exit(1)
}
'''


def fixture():
    """Write the same Stored-manifest/Deflate-members profile as the composer."""
    content = b"// download fixture\n"
    manifest = {
        "schema": 1,
        "runtimeVersion": "ios-download-fixture",
        "dshVersion": "0.2.2-rc.1",
        "nodeVersion": "24.22.1",
        "files": [{"path": path, "size": len(content),
                   "sha256": hashlib.sha256(content).hexdigest()} for path in ENTRIES],
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("manifest.json", json.dumps(manifest), compress_type=zipfile.ZIP_STORED)
        for path in ENTRIES:
            archive.writestr("files/" + path, content, compress_type=zipfile.ZIP_DEFLATED)
    return output.getvalue(), manifest


@unittest.skipUnless(platform.system() == "Darwin" and XCRUN, "Apple Swift/Compression/CryptoKit require macOS")
class RuntimeDownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="runtime-download-tests-")
        cls.directory = Path(cls.temporary.name)
        cls.payload, cls.manifest = fixture()
        cls.requests = []
        cls.request_lock = threading.Lock()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with cls.request_lock:
                    cls.requests.append(self.path)
                if self.path == "/runtime.zip":
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(cls.payload)))
                    self.end_headers()
                    self.wfile.write(cls.payload)
                elif self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "http://example.invalid/runtime.zip")
                    self.end_headers()
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, *_args):
                pass

        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"
        source = cls.directory / "main.swift"
        source.write_text(SWIFT)
        cls.executables = {}
        for configuration, defines in (("debug", ["-D", "DEBUG"]), ("release", [])):
            executable = cls.directory / configuration
            subprocess.run([XCRUN, "swiftc", "-swift-version", "5", *defines,
                            str(ROOT / "app/ios/Runner/EngineRuntime.swift"),
                            str(ROOT / "app/ios/Runner/RuntimeDownload.swift"),
                            str(source), "-o", str(executable)], check=True, timeout=60)
            cls.executables[configuration] = executable

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.temporary.cleanup()

    def run_check(self, mode, configuration="debug", **overrides):
        descriptor = {
            "schema": 1, "url": self.base_url + "/runtime.zip",
            "sha256": hashlib.sha256(self.payload).hexdigest(), "bytes": len(self.payload),
            **{key: self.manifest[key] for key in ("runtimeVersion", "dshVersion", "nodeVersion")},
            **overrides,
        }
        with tempfile.TemporaryDirectory(prefix="case-", dir=self.directory) as temporary:
            directory = Path(temporary)
            (directory / "descriptor.json").write_text(json.dumps(descriptor))
            with self.request_lock:
                before = len(self.requests)
            result = subprocess.run([str(self.executables[configuration]), str(directory), mode],
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), "PASS " + mode)
            with self.request_lock:
                return self.requests[before:]

    def test_downloads_verifies_and_extracts_the_archive(self):
        self.assertEqual(self.run_check("success"), ["/runtime.zip"])

    def test_reuses_verified_cache_without_another_request(self):
        self.assertEqual(self.run_check("cache"), ["/runtime.zip"])

    def test_replaces_corrupt_cached_bytes(self):
        self.assertEqual(self.run_check("corrupt-cache"), ["/runtime.zip"])

    def test_rejects_http_failure(self):
        self.assertEqual(self.run_check("http", url=self.base_url + "/missing"), ["/missing"])

    def test_rejects_mismatching_archive_hash(self):
        self.assertEqual(self.run_check("checksum", sha256="0" * 64), ["/runtime.zip"])

    def test_rejects_download_larger_than_the_pin(self):
        self.assertEqual(self.run_check("size", bytes=len(self.payload) - 1), ["/runtime.zip"])

    def test_rejects_mismatching_manifest_version(self):
        self.assertEqual(self.run_check("version", runtimeVersion="other-version"), ["/runtime.zip"])

    def test_rejects_redirect_to_nonlocal_http_without_following_it(self):
        self.assertEqual(self.run_check("redirect", url=self.base_url + "/redirect"), ["/redirect"])

    def test_release_rejects_even_loopback_http(self):
        self.assertEqual(self.run_check("release-http", configuration="release"), [])

    def test_rejects_credentials_and_nonlocal_http(self):
        for address in ("https://user:password@example.invalid/runtime.zip",
                        "http://example.invalid/runtime.zip"):
            with self.subTest(address=address):
                self.assertEqual(self.run_check("invalid-config", url=address), [])


if __name__ == "__main__":
    unittest.main()

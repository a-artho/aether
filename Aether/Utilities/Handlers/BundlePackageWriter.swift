import Foundation
import Darwin
import Minizip

/// A bounded, cancellable writer shared by install and export packaging.
/// ArchiveHandler holds a read lease on the source until file work has exited.
enum BundlePackageWriter {
    struct Entry {
        let url: URL
        let name: String
        let metadata: stat
        var kind: mode_t { metadata.st_mode & S_IFMT }
    }
    enum Failure: LocalizedError {
        case archive(String)
        case changedSource(String)
        var errorDescription: String? {
            switch self {
            case .archive(let stage): return "Could not create the app archive (\(stage))."
            case .changedSource(let path): return "The app changed while packaging: \(path)."
            }
        }
    }
    static let bufferSize = 256 * 1024

    static func entries(at root: URL, rootName: String? = nil,
        check: () throws -> Void = { try Task.checkCancellation() }) throws -> [Entry] {
        let normalizedRoot = root.resolvingSymlinksInPath()
        let archiveRoot = rootName ?? normalizedRoot.lastPathComponent
        guard !archiveRoot.isEmpty, !archiveRoot.hasPrefix("/"),
            archiveRoot.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure.archive("app root name")
        }
        var result = [Entry]()
        func entry(_ url: URL, name: String) throws -> Entry {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw posixError() }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else {
                throw Failure.archive("unsupported file: \(name)")
            }
            // Canonical directory metadata keeps archives stable across staging
            // and direct reads; directory timestamps carry no app content.
            if kind == S_IFDIR {
                info.st_mtimespec = timespec(tv_sec: 315532800, tv_nsec: 0)
                info.st_size = 0
            }
            return Entry(url: url, name: kind == S_IFDIR ? name + "/" : name, metadata: info)
        }
        let rootEntry = try entry(normalizedRoot, name: archiveRoot)
        guard rootEntry.kind == S_IFDIR else { throw Failure.archive("app root") }
        result.append(rootEntry)
        func visit(_ directory: URL, relativeName: String) throws {
            try check()
            // Enumerate one directory at a time so read failures propagate.
            // Build relative names explicitly: Foundation may return /private/var
            // URLs for a /var root, which are equivalent filesystem locations.
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try check()
                let name = relativeName + "/" + child.lastPathComponent
                let item = try entry(child, name: name)
                result.append(item)
                if item.kind == S_IFDIR { try visit(child, relativeName: name) }
            }
        }
        try visit(normalizedRoot, relativeName: archiveRoot)
        return result.sorted { $0.name < $1.name }
    }

    static func write(_ entries: [Entry], to output: URL, compression: Int32,
        check: () throws -> Void = { try Task.checkCancellation() }, progress: (Double) -> Void) throws {
        try check()
        guard [-1, 0, 1, 9].contains(compression) else { throw Failure.archive("compression setting") }
        guard let archive = zipOpen64(output.path, APPEND_STATUS_CREATE) else { throw Failure.archive("opening destination") }
        var closed = false
        var complete = false
        var entryOpen = false
        defer {
            if entryOpen { _ = zipCloseFileInZip(archive) }
            if !closed { _ = zipClose(archive, nil) }
            if !complete { try? FileManager.default.removeItem(at: output) }
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        let total = entries.reduce(Int64(0)) { $0 + ($1.kind == S_IFREG ? Int64($1.metadata.st_size) : 0) }
        var written: Int64 = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        progress(0)
        for entry in entries {
            try check()
            var info = zip_fileinfo()
            let date = Date(timeIntervalSince1970: TimeInterval(entry.metadata.st_mtimespec.tv_sec))
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            info.tmz_date = tm_zip(tm_sec: UInt32(components.second ?? 0), tm_min: UInt32(components.minute ?? 0),
                tm_hour: UInt32(components.hour ?? 0), tm_mday: UInt32(components.day ?? 1),
                tm_mon: UInt32((components.month ?? 1) - 1), tm_year: UInt32(min(2107, max(1980, components.year ?? 1980))))
            info.external_fa = uLong(entry.metadata.st_mode) << 16
            if entry.kind == S_IFDIR { info.external_fa |= 0x10 }
            let method: Int32 = compression == 0 || entry.kind != S_IFREG ? 0 : Z_DEFLATED
            let opened = entry.name.withCString {
                zipOpenNewFileInZip4_64(archive, $0, &info, nil, 0, nil, 0, nil,
                    method, compression, 0, -MAX_WBITS, DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                    nil, 0, (3 << 8) | 20, 0x800, entry.metadata.st_size >= Int64(UInt32.max) ? 1 : 0)
            }
            guard opened == ZIP_OK else { throw Failure.archive("opening entry: \(entry.name)") }
            entryOpen = true
            func append(_ bytes: UnsafeRawBufferPointer) throws {
                try check()
                guard zipWriteInFileInZip(archive, bytes.baseAddress, UInt32(bytes.count)) == ZIP_OK else {
                    throw Failure.archive("writing entry: \(entry.name)")
                }
            }
            if entry.kind == S_IFREG {
                try read(entry, buffer: buffer, check: check) { bytes in
                    try append(bytes)
                    written += Int64(bytes.count)
                    if total > 0 { progress(min(0.999, Double(written) / Double(total))) }
                }
            } else if entry.kind == S_IFLNK {
                try symlinkData(entry).withUnsafeBytes { try append($0) }
            }
            let result = zipCloseFileInZip(archive)
            entryOpen = false
            guard result == ZIP_OK else { throw Failure.archive("closing entry: \(entry.name)") }
        }
        try check()
        let result = zipClose(archive, nil)
        closed = true
        guard result == ZIP_OK else { throw Failure.archive("closing archive") }
        try check()
        complete = true
        progress(1)
    }

    private static func read(_ entry: Entry, buffer: UnsafeMutableRawPointer, check: () throws -> Void,
        consume: (UnsafeRawBufferPointer) throws -> Void) throws {
        let fd = open(entry.url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard sameFile(info, entry.metadata) else { throw Failure.changedSource(entry.name) }
        var count: Int64 = 0
        while true {
            try check()
            let size = Darwin.read(fd, buffer, bufferSize)
            if size < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if size == 0 { break }
            count += Int64(size)
            try consume(UnsafeRawBufferPointer(start: buffer, count: size))
        }
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard count == entry.metadata.st_size, sameFile(info, entry.metadata) else { throw Failure.changedSource(entry.name) }
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func symlinkData(_ entry: Entry) throws -> Data {
        Data(try FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path).utf8)
    }
    private static func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

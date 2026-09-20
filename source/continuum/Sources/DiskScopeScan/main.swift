// diskscope-scan — a tiny privileged file-tree crawler.
//
// Continuum's in-process Disk Map scan runs as the logged-in user, so it cannot
// read directories owned by root (FDA grants TCC-protected access, not root).
// This standalone tool is invoked *as root* (via `osascript … with
// administrator privileges`) so it can stat and enumerate EVERY item on the
// volume — including system files the user can't open — and so account for the
// disk space those occupy.
//
// It writes a compact record stream to an output file the app then reads:
//   <isDir>\0<restricted>\0<allocatedSize>\0<relativePath>\0   (repeated)
// where isDir/restricted are '1'/'0'. Paths are relative to the scan root and
// never contain NUL, so NUL is a safe field+record separator. The root itself
// is not emitted (the app creates that node). Records appear parent-before-
// child, so the app assembles the tree in one pass.
//
// "restricted" means the item is owned by root and not writable by others —
// i.e. you cannot modify (and usually cannot open) it without admin rights.
// The app draws these blocks with a red inner outline.
//
// Traversal is an explicit-stack DFS over opendir/readdir + lstat (fts is not
// exposed to Swift). Symlinks are stat'd but never descended into — no cycles,
// no double counting.
//
// Safety: this tool is strictly read-only. It opens nothing for writing except
// its own output file, issues no deletes, and crosses no privilege boundary
// other than being launched as root by the user's explicit authorization.

import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: diskscope-scan <root> <out> [uid]\n".utf8))
    exit(2)
}
let rootArg = args[1]
let outPath = args[2]

// Normalize the root (drop any trailing slash except for "/").
let normRoot: String = (rootArg != "/" && rootArg.hasSuffix("/"))
    ? String(rootArg.dropLast()) : rootArg

FileManager.default.createFile(atPath: outPath, contents: nil)
guard let out = FileHandle(forWritingAtPath: outPath) else {
    FileHandle.standardError.write(Data("cannot open output \(outPath)\n".utf8))
    exit(3)
}

var buffer = Data()
buffer.reserveCapacity(1 << 20)
let nul: UInt8 = 0

@inline(__always)
func emit(isDir: Bool, restricted: Bool, size: Int64, relPath: String) {
    buffer.append(isDir ? 0x31 : 0x30); buffer.append(nul)        // '1'/'0'
    buffer.append(restricted ? 0x31 : 0x30); buffer.append(nul)
    buffer.append(Data(String(size).utf8)); buffer.append(nul)
    buffer.append(Data(relPath.utf8)); buffer.append(nul)
    if buffer.count >= (1 << 20) {
        out.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

/// Reads the NUL-terminated name out of a `dirent` regardless of platform tuple
/// width.
@inline(__always)
func entryName(_ ent: UnsafeMutablePointer<dirent>) -> String {
    return withUnsafeMutablePointer(to: &ent.pointee.d_name) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) {
            String(cString: $0)
        }
    }
}

// Explicit DFS stack of (absolutePath, relativePath). The root is expanded but
// not emitted; its entries carry relative paths the app keys its tree on.
var stack: [(abs: String, rel: String)] = [(normRoot, "")]

while let dir = stack.popLast() {
    guard let dp = opendir(dir.abs) else { continue }   // unreadable even as root
    defer { closedir(dp) }

    while let ent = readdir(dp) {
        let name = entryName(ent)
        if name == "." || name == ".." { continue }

        let childAbs = dir.abs == "/" ? "/" + name : dir.abs + "/" + name
        let childRel = dir.rel.isEmpty ? name : dir.rel + "/" + name

        var st = stat()
        guard lstat(childAbs, &st) == 0 else { continue }

        let mode = st.st_mode
        let isSymlink = (mode & S_IFMT) == S_IFLNK
        let isDir = (mode & S_IFMT) == S_IFDIR && !isSymlink

        let size: Int64 = isDir ? 0 : Int64(st.st_blocks) * 512   // size on disk
        let restricted = (st.st_uid == 0) && (Int32(mode) & Int32(S_IWOTH)) == 0

        emit(isDir: isDir, restricted: restricted, size: size, relPath: childRel)

        if isDir {
            stack.append((childAbs, childRel))
        }
    }
}

if !buffer.isEmpty { out.write(buffer) }
try? out.close()

// Make the root-owned output readable by the user who launched us.
chmod(outPath, 0o644)
exit(0)

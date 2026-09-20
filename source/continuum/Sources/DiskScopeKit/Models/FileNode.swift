import Foundation

/// One node of the scanned file tree.
///
/// Memory layout matters: scans can produce millions of nodes, so a node stores
/// only its own name and derives its full path by walking `parent` pointers.
/// Only the scan root holds an absolute path.
final class FileNode: Identifiable {
    let name: String
    let isDirectory: Bool
    private(set) var size: Int64
    private(set) var children: [FileNode] = []
    private(set) weak var parent: FileNode?
    private let absolutePath: String?

    /// True when this item is owned by root and not writable by you — i.e. you
    /// cannot modify (and usually cannot open) it without admin rights. Only set
    /// by the privileged "Read All Files" scan; the treemap draws these blocks
    /// with a red inner outline. Always `false` for the normal user-level scan.
    var restricted: Bool = false

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, size: Int64 = 0, absolutePath: String? = nil,
         restricted: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.absolutePath = absolutePath
        self.restricted = restricted
    }

    /// Full filesystem path, reconstructed from the parent chain.
    var path: String {
        if let absolutePath { return absolutePath }
        guard let parent else { return name }
        let parentPath = parent.path
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    func addChild(_ node: FileNode) {
        node.parent = self
        children.append(node)
    }

    /// Post-order pass run once after the crawl: sums directory sizes from
    /// children and sorts every child list by size descending (the squarify
    /// algorithm needs descending weights to produce good aspect ratios).
    @discardableResult
    func finalize() -> Int64 {
        if isDirectory {
            var total: Int64 = 0
            for child in children {
                total += child.finalize()
            }
            size = total
        }
        children.sort { $0.size > $1.size }
        return size
    }

    /// Ancestor chain from the scan root down to (and including) self.
    var chainFromRoot: [FileNode] {
        var chain: [FileNode] = []
        var node: FileNode? = self
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        return chain.reversed()
    }
}

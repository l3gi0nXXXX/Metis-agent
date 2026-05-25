package metis.core.media_tests

import std.fs.{Directory, Path}
import std.time.DateTime

public func mediaFakeAssetRoot(label: String): Path {
    let root = Path("/tmp/metis-media-fake-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

public func mediaFakeAssertInsideRoot(root: Path, path: Path): Bool {
    let rootText = root.toString()
    let pathText = path.toString()
    pathText == rootText || pathText.startsWith("${rootText}/")
}

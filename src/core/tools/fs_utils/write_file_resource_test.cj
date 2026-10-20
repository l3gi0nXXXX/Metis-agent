package metis.core.tools.fs_utils

import std.fs.{Directory, File, OpenMode, Path, remove}
import std.env.getProcessId
import std.time.DateTime
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
}

@When[os == "macOS"]
private func resourceWriteFdCount(): Int64 {
    var descriptors = VArray<UInt64, $4096>(repeat: 0)
    let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, inout descriptors, 32768) }
    @Expect(bytes > 0, true)
    Int64(bytes) / 8
}

@When[os != "macOS"]
private func resourceWriteFdCount(): Int64 { 0 }

@Test
public class WriteFileResourceTest {
    @TestCase
    public func resourceWriteKeepsUnicodeAppendAndFailureOutputs(): Unit {
        let root = Path("/tmp/metis-file-resource-write-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(root, recursive: true)
        try {
            let path = root.join("写入🧪.txt")
            @Expect(writeFileBasic(path, "中文😀"), "File ${path} written successfully!")
            @Expect(writeFileBasic(path, "追加", mode: OpenMode.Append), "File ${path} written successfully!")
            @Expect(String.fromUtf8(File.readFrom(path)), "中文😀追加")
            let content = StringBuilder()
            for (_ in 0..4096) { content.append("长文本🧪") }
            @Expect(writeFileBasic(path, content.toString()), "File ${path} written successfully!")
            @Expect(String.fromUtf8(File.readFrom(path)), content.toString())
            let failed = writeFileBasic(root.join("missing").join("child"), "sensitive-test-body")
            @Expect(failed, "Parent directory does not exist, cannot open file, write failed, partial write, or file is not writable")
            @Expect(failed.contains("sensitive-test-body"), false)
            // A read-only open succeeds, then write throws: exercise cleanup after ownership is acquired.
            let before = resourceWriteFdCount()
            for (_ in 0..32) {
                let readOnly = writeFileBasic(path, "sensitive-test-body", mode: OpenMode.Read)
                @Expect(readOnly.contains("written successfully"), false)
                @Expect(readOnly.contains("sensitive-test-body"), false)
            }
            @Expect(resourceWriteFdCount() <= before, true)
            @Expect(String.fromUtf8(File.readFrom(path)), content.toString())
            @Expect(writeFileBasic(path, ""), "File ${path} written successfully!")
            @Expect(File.readFrom(path).size, 0)
        } finally {
            remove(root, recursive: true)
        }
    }
}

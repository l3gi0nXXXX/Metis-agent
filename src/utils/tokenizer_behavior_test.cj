package metis.utils

import magic.tokenizer.Cl100kTokenizer
import metis.process.{launchManagedRawChild, ManagedOwnedChild, observeProcessBirthIdentity, probeProcessBirthIdentity}
import std.collection.{HashMap, Map, ArrayList, HashSet}
import std.env.{getVariables, getCommand, getProcessId}
import std.fs.{Path, OpenMode, FileInfo, exists, canonicalize, rename}
import std.process.ProcessRedirect
import std.runtime.{getMaxHeapSize, getThreadCount, getBlockingThreadCount}
import std.time.{DateTime, MonoTime}

import std.env.{getVariable, getStdOut}
import std.fs.{Directory, File, remove}
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

// Capture is intentionally not formal acceptance. Freeze the legacy records below
// before running without the explicit capture flag.
private let LEGACY_TOKENIZER_GOLDEN = String.join([
    "TOKENIZER-GOLDEN-v1|metis|full.vocabulary|bytes:1681125;sha:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e",
    "TOKENIZER-GOLDEN-v1|metis|full.string.empty|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;ids:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;bytes:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;count:0;repeat:ids:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "TOKENIZER-GOLDEN-v1|metis|full.string.ascii|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:16:aa8c00240708ae0286cd16705565abd4ca100d1df4d2b72434cc2104f11d0c48;ids:5:629583bde3279cc1afa69c0398bec849ac686a23e26f41184326c92fb6820033;bytes:16:aa8c00240708ae0286cd16705565abd4ca100d1df4d2b72434cc2104f11d0c48;count:5;repeat:ids:5:629583bde3279cc1afa69c0398bec849ac686a23e26f41184326c92fb6820033",
    "TOKENIZER-GOLDEN-v1|metis|full.string.code|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:32:a41e563ec9343ec18c1003d2932e49e4c82d5062f85a8c1a05ab6bf60c5cfd22;ids:9:3e4d6f3e247c5e802029615e9842752cbfa5e26ca87688b16aeecf1fc8161436;bytes:32:a41e563ec9343ec18c1003d2932e49e4c82d5062f85a8c1a05ab6bf60c5cfd22;count:9;repeat:ids:9:3e4d6f3e247c5e802029615e9842752cbfa5e26ca87688b16aeecf1fc8161436",
    "TOKENIZER-GOLDEN-v1|metis|full.string.unicode|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:23:d9d9a870a5c7ca303b57d5b8877896ff999ef416119d5b825d8a1ac6bc62c9be;ids:11:97f790a33b165c55fca5cb0e350ea2c6772fafdc35f783da7d0d8071d90acf88;bytes:23:d9d9a870a5c7ca303b57d5b8877896ff999ef416119d5b825d8a1ac6bc62c9be;count:11;repeat:ids:11:97f790a33b165c55fca5cb0e350ea2c6772fafdc35f783da7d0d8071d90acf88",
    "TOKENIZER-GOLDEN-v1|metis|full.string.controls|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:16:de0ed5cfa7d59f89acf1e625c2b3c2c701b8567ff466abbb51fb79a1fdf08099;ids:9:7fd8251bcc8d080dc6c0edac7771e0cc02baeaeb6535f62fe3b3cd2ccff3bfcd;bytes:16:de0ed5cfa7d59f89acf1e625c2b3c2c701b8567ff466abbb51fb79a1fdf08099;count:9;repeat:ids:9:7fd8251bcc8d080dc6c0edac7771e0cc02baeaeb6535f62fe3b3cd2ccff3bfcd",
    "TOKENIZER-GOLDEN-v1|metis|full.string.quotes|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:17:1873c5f7d26b3a01049d2b762b1d748c4f1d7c533bc487586e150b5f8a92d104;ids:8:d47d5ec32279383f9cb14e912439f566aa16cee0db1bfa08f8be02034feb577a;bytes:17:1873c5f7d26b3a01049d2b762b1d748c4f1d7c533bc487586e150b5f8a92d104;count:8;repeat:ids:8:d47d5ec32279383f9cb14e912439f566aa16cee0db1bfa08f8be02034feb577a",
    "TOKENIZER-GOLDEN-v1|metis|full.string.special|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:73:0b9c9cc7d3193163dceae419c11ac2de8600e2b611fac28a6e5bccc134b38c7e;ids:6:700c1186fbe7bbc657a57355d03c46254394d64a0cfc681e9b1f42f649bfd4fb;bytes:73:1f35c1fb077b3688c5d8d8742406f74927c1d12e1c5a9609bb9258103250a3ac;count:6;repeat:ids:6:700c1186fbe7bbc657a57355d03c46254394d64a0cfc681e9b1f42f649bfd4fb",
    "TOKENIZER-GOLDEN-v1|metis|full.string.long64k|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:65536:02ce7c3e01bfb35d7dc8845cfb15b03b9c22dbc60727b7af02d8f791be863744;ids:24576:7c7656480d38ba8b753c7bd9635d2bcaf090de04d21f8faf85f1f51235ffd4f1;bytes:65536:02ce7c3e01bfb35d7dc8845cfb15b03b9c22dbc60727b7af02d8f791be863744;count:24576;repeat:ids:24576:7c7656480d38ba8b753c7bd9635d2bcaf090de04d21f8faf85f1f51235ffd4f1",
    "TOKENIZER-GOLDEN-v1|metis|full.string.leadingSpace|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:14:f48be721c2a6e91201a4b99f1ffeb8b884516dc0db68d88f3b94e69ddb66e46d;ids:6:6aef05181e33f2770b3631b9fed9de6c38c179322a026755548390c43e4e1d84;bytes:14:f48be721c2a6e91201a4b99f1ffeb8b884516dc0db68d88f3b94e69ddb66e46d;count:6;repeat:ids:6:6aef05181e33f2770b3631b9fed9de6c38c179322a026755548390c43e4e1d84",
    "TOKENIZER-GOLDEN-v1|metis|full.string.trailingSpace|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:14:9535dc7fe8d4840f42ceaab7a157bb9c5127f0e7271e2ea32e1e241bb109a114;ids:6:e21f641bf796d7524d3ef85e5825b39e24c9f1dc00fae8aebcc94e60559c7eff;bytes:14:9535dc7fe8d4840f42ceaab7a157bb9c5127f0e7271e2ea32e1e241bb109a114;count:6;repeat:ids:6:e21f641bf796d7524d3ef85e5825b39e24c9f1dc00fae8aebcc94e60559c7eff",
    "TOKENIZER-GOLDEN-v1|metis|full.string.numbers|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:21:86a7a1fc633bb56c5918e6063ce1ba7b57a7b0a275e90e1663b47fc3ce372af5;ids:11:5488f414c32a787c1d271af379f9be6867d0f6009b744af2bf49af8743ee9798;bytes:21:86a7a1fc633bb56c5918e6063ce1ba7b57a7b0a275e90e1663b47fc3ce372af5;count:11;repeat:ids:11:5488f414c32a787c1d271af379f9be6867d0f6009b744af2bf49af8743ee9798",
    "TOKENIZER-GOLDEN-v1|metis|full.string.cjkPunctuation|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:27:e48d707ac18ef01a8abd1eb3ac98d5fcb41125b66848491bfe811546b8ebf92a;ids:10:409453858f393bf70c55cbb1c7fd4c4f2c11b690078c84ee381da8e135233371;bytes:27:e48d707ac18ef01a8abd1eb3ac98d5fcb41125b66848491bfe811546b8ebf92a;count:10;repeat:ids:10:409453858f393bf70c55cbb1c7fd4c4f2c11b690078c84ee381da8e135233371",
    "TOKENIZER-GOLDEN-v1|metis|full.string.emojiZwj|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:29:4d971b409e2aeaa59bc1901cabc6f12dabf3b4d3cf2c60b19a24f375e65b62c2;ids:18:03b8f8d9f11ceabc3044ba8e9e45dc69683655783f62f89e3cefb44de356949e;bytes:29:4d971b409e2aeaa59bc1901cabc6f12dabf3b4d3cf2c60b19a24f375e65b62c2;count:18;repeat:ids:18:03b8f8d9f11ceabc3044ba8e9e45dc69683655783f62f89e3cefb44de356949e",
    "TOKENIZER-GOLDEN-v1|metis|full.string.normalization|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:13:ef624607510952b51b128fe7268fa32bf1f7a2021dbd11f3b8a8fa57db430638;ids:7:9f6e09175a656e821d55608a7530cdb1a05150378eecdf238cef1b59dc320d10;exceptionLabel:IllegalArgumentException;count:7;repeat:ids:7:9f6e09175a656e821d55608a7530cdb1a05150378eecdf238cef1b59dc320d10",
    "TOKENIZER-GOLDEN-v1|metis|full.string.lineEndings|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:8:830d68e2cc23e5791bb929e30d5febd8d1667416de2ebe7157204d5e6d454755;ids:7:4a3e20251f19e735d4deba4e56400b81935387e6e575f3511939669925f9f9db;bytes:8:830d68e2cc23e5791bb929e30d5febd8d1667416de2ebe7157204d5e6d454755;count:7;repeat:ids:7:4a3e20251f19e735d4deba4e56400b81935387e6e575f3511939669925f9f9db",
    "TOKENIZER-GOLDEN-v1|metis|full.string.multiScript|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:48:bea07ac6d00db998deb41ab8bdeade3c4afbcab2a182c9687987cd926838f4b1;ids:16:a79675ffd4858b8de5a30c192d55ce87f1fbba7d5efaa1bb26651e954ce74a6f;bytes:48:bea07ac6d00db998deb41ab8bdeade3c4afbcab2a182c9687987cd926838f4b1;count:16;repeat:ids:16:a79675ffd4858b8de5a30c192d55ce87f1fbba7d5efaa1bb26651e954ce74a6f",
    "TOKENIZER-GOLDEN-v1|metis|full.path.empty|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;ids:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;bytes:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;count:0;repeat:ids:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "TOKENIZER-GOLDEN-v1|metis|full.path.ascii|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:16:aa8c00240708ae0286cd16705565abd4ca100d1df4d2b72434cc2104f11d0c48;ids:5:629583bde3279cc1afa69c0398bec849ac686a23e26f41184326c92fb6820033;bytes:16:aa8c00240708ae0286cd16705565abd4ca100d1df4d2b72434cc2104f11d0c48;count:5;repeat:ids:5:629583bde3279cc1afa69c0398bec849ac686a23e26f41184326c92fb6820033",
    "TOKENIZER-GOLDEN-v1|metis|full.path.code|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:32:a41e563ec9343ec18c1003d2932e49e4c82d5062f85a8c1a05ab6bf60c5cfd22;ids:9:3e4d6f3e247c5e802029615e9842752cbfa5e26ca87688b16aeecf1fc8161436;bytes:32:a41e563ec9343ec18c1003d2932e49e4c82d5062f85a8c1a05ab6bf60c5cfd22;count:9;repeat:ids:9:3e4d6f3e247c5e802029615e9842752cbfa5e26ca87688b16aeecf1fc8161436",
    "TOKENIZER-GOLDEN-v1|metis|full.path.unicode|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:23:d9d9a870a5c7ca303b57d5b8877896ff999ef416119d5b825d8a1ac6bc62c9be;ids:11:97f790a33b165c55fca5cb0e350ea2c6772fafdc35f783da7d0d8071d90acf88;bytes:23:d9d9a870a5c7ca303b57d5b8877896ff999ef416119d5b825d8a1ac6bc62c9be;count:11;repeat:ids:11:97f790a33b165c55fca5cb0e350ea2c6772fafdc35f783da7d0d8071d90acf88",
    "TOKENIZER-GOLDEN-v1|metis|full.path.controls|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:16:de0ed5cfa7d59f89acf1e625c2b3c2c701b8567ff466abbb51fb79a1fdf08099;ids:9:7fd8251bcc8d080dc6c0edac7771e0cc02baeaeb6535f62fe3b3cd2ccff3bfcd;bytes:16:de0ed5cfa7d59f89acf1e625c2b3c2c701b8567ff466abbb51fb79a1fdf08099;count:9;repeat:ids:9:7fd8251bcc8d080dc6c0edac7771e0cc02baeaeb6535f62fe3b3cd2ccff3bfcd",
    "TOKENIZER-GOLDEN-v1|metis|full.path.quotes|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:17:1873c5f7d26b3a01049d2b762b1d748c4f1d7c533bc487586e150b5f8a92d104;ids:8:d47d5ec32279383f9cb14e912439f566aa16cee0db1bfa08f8be02034feb577a;bytes:17:1873c5f7d26b3a01049d2b762b1d748c4f1d7c533bc487586e150b5f8a92d104;count:8;repeat:ids:8:d47d5ec32279383f9cb14e912439f566aa16cee0db1bfa08f8be02034feb577a",
    "TOKENIZER-GOLDEN-v1|metis|full.path.special|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:73:0b9c9cc7d3193163dceae419c11ac2de8600e2b611fac28a6e5bccc134b38c7e;ids:6:700c1186fbe7bbc657a57355d03c46254394d64a0cfc681e9b1f42f649bfd4fb;bytes:73:1f35c1fb077b3688c5d8d8742406f74927c1d12e1c5a9609bb9258103250a3ac;count:6;repeat:ids:6:700c1186fbe7bbc657a57355d03c46254394d64a0cfc681e9b1f42f649bfd4fb",
    "TOKENIZER-GOLDEN-v1|metis|full.path.long64k|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:65536:02ce7c3e01bfb35d7dc8845cfb15b03b9c22dbc60727b7af02d8f791be863744;ids:24576:7c7656480d38ba8b753c7bd9635d2bcaf090de04d21f8faf85f1f51235ffd4f1;bytes:65536:02ce7c3e01bfb35d7dc8845cfb15b03b9c22dbc60727b7af02d8f791be863744;count:24576;repeat:ids:24576:7c7656480d38ba8b753c7bd9635d2bcaf090de04d21f8faf85f1f51235ffd4f1",
    "TOKENIZER-GOLDEN-v1|metis|full.path.leadingSpace|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:14:f48be721c2a6e91201a4b99f1ffeb8b884516dc0db68d88f3b94e69ddb66e46d;ids:6:6aef05181e33f2770b3631b9fed9de6c38c179322a026755548390c43e4e1d84;bytes:14:f48be721c2a6e91201a4b99f1ffeb8b884516dc0db68d88f3b94e69ddb66e46d;count:6;repeat:ids:6:6aef05181e33f2770b3631b9fed9de6c38c179322a026755548390c43e4e1d84",
    "TOKENIZER-GOLDEN-v1|metis|full.path.trailingSpace|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:14:9535dc7fe8d4840f42ceaab7a157bb9c5127f0e7271e2ea32e1e241bb109a114;ids:6:e21f641bf796d7524d3ef85e5825b39e24c9f1dc00fae8aebcc94e60559c7eff;bytes:14:9535dc7fe8d4840f42ceaab7a157bb9c5127f0e7271e2ea32e1e241bb109a114;count:6;repeat:ids:6:e21f641bf796d7524d3ef85e5825b39e24c9f1dc00fae8aebcc94e60559c7eff",
    "TOKENIZER-GOLDEN-v1|metis|full.path.numbers|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:21:86a7a1fc633bb56c5918e6063ce1ba7b57a7b0a275e90e1663b47fc3ce372af5;ids:11:5488f414c32a787c1d271af379f9be6867d0f6009b744af2bf49af8743ee9798;bytes:21:86a7a1fc633bb56c5918e6063ce1ba7b57a7b0a275e90e1663b47fc3ce372af5;count:11;repeat:ids:11:5488f414c32a787c1d271af379f9be6867d0f6009b744af2bf49af8743ee9798",
    "TOKENIZER-GOLDEN-v1|metis|full.path.cjkPunctuation|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:27:e48d707ac18ef01a8abd1eb3ac98d5fcb41125b66848491bfe811546b8ebf92a;ids:10:409453858f393bf70c55cbb1c7fd4c4f2c11b690078c84ee381da8e135233371;bytes:27:e48d707ac18ef01a8abd1eb3ac98d5fcb41125b66848491bfe811546b8ebf92a;count:10;repeat:ids:10:409453858f393bf70c55cbb1c7fd4c4f2c11b690078c84ee381da8e135233371",
    "TOKENIZER-GOLDEN-v1|metis|full.path.emojiZwj|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:29:4d971b409e2aeaa59bc1901cabc6f12dabf3b4d3cf2c60b19a24f375e65b62c2;ids:18:03b8f8d9f11ceabc3044ba8e9e45dc69683655783f62f89e3cefb44de356949e;bytes:29:4d971b409e2aeaa59bc1901cabc6f12dabf3b4d3cf2c60b19a24f375e65b62c2;count:18;repeat:ids:18:03b8f8d9f11ceabc3044ba8e9e45dc69683655783f62f89e3cefb44de356949e",
    "TOKENIZER-GOLDEN-v1|metis|full.path.normalization|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:13:ef624607510952b51b128fe7268fa32bf1f7a2021dbd11f3b8a8fa57db430638;ids:7:9f6e09175a656e821d55608a7530cdb1a05150378eecdf238cef1b59dc320d10;exceptionLabel:IllegalArgumentException;count:7;repeat:ids:7:9f6e09175a656e821d55608a7530cdb1a05150378eecdf238cef1b59dc320d10",
    "TOKENIZER-GOLDEN-v1|metis|full.path.lineEndings|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:8:830d68e2cc23e5791bb929e30d5febd8d1667416de2ebe7157204d5e6d454755;ids:7:4a3e20251f19e735d4deba4e56400b81935387e6e575f3511939669925f9f9db;bytes:8:830d68e2cc23e5791bb929e30d5febd8d1667416de2ebe7157204d5e6d454755;count:7;repeat:ids:7:4a3e20251f19e735d4deba4e56400b81935387e6e575f3511939669925f9f9db",
    "TOKENIZER-GOLDEN-v1|metis|full.path.multiScript|vocab:1681125:085dcea7fc301966830f245cb17c9702c63e7aa9d9409563578d567670ba869e;input:48:bea07ac6d00db998deb41ab8bdeade3c4afbcab2a182c9687987cd926838f4b1;ids:16:a79675ffd4858b8de5a30c192d55ce87f1fbba7d5efaa1bb26651e954ce74a6f;bytes:48:bea07ac6d00db998deb41ab8bdeade3c4afbcab2a182c9687987cd926838f4b1;count:16;repeat:ids:16:a79675ffd4858b8de5a30c192d55ce87f1fbba7d5efaa1bb26651e954ce74a6f"
], delimiter: "\n")

private func goldenSha(bytes: Array<Byte>): String {
    let digest = SHA256(); digest.write(bytes)
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    let result = StringBuilder()
    for (byte in digest.finish()) {
        result.append(digits[Int64(byte >> 4)])
        result.append(digits[Int64(byte & 0x0f)])
    }
    result.toString()
}

private func goldenIds(ids: Array<UInt32>): String {
    let serialized = StringBuilder()
    for (id in ids) { serialized.append(id.toString()); serialized.append(",") }
    "${ids.size}:${goldenSha(serialized.toString().toArray())}"
}

private func goldenFailure(error: Exception): String {
    // SDK100 public Exception.toString() renders className[: message].
    let fields = error.toString().split(":", removeEmpty: false)
    if (fields.isEmpty()) { throw Exception("golden_exception_label_invalid") }
    let label = fields[0]
    let bytes = label.toArray()
    if (bytes.isEmpty() || bytes.size > 128 ||
        !((bytes[0] >= 65 && bytes[0] <= 90) || (bytes[0] >= 97 && bytes[0] <= 122) || bytes[0] == 95) ||
        !bytes.iterator().all({ byte => (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) || byte == 95 || byte == 46 })) {
        throw Exception("golden_exception_label_invalid")
    }
    "exceptionLabel:" + label
}

private func goldenObserve(tokenizer: Cl100kTokenizer, input: String): String {
    var ids: Option<Array<UInt32>> = None
    var encoded = "not_attempted"
    try { let actual = tokenizer.encode(input); ids = Some(actual); encoded = "ids:" + goldenIds(actual) }
    catch (error: Exception) { encoded = goldenFailure(error) }
    var decoded = "not_attempted"
    if (let Some(actual) <- ids) {
        try {
            let bytes = tokenizer.decode(actual).toArray()
            decoded = "bytes:${bytes.size}:${goldenSha(bytes)}"
        } catch (error: Exception) { decoded = goldenFailure(error) }
    }
    var counted = "not_attempted"
    try { counted = "count:${tokenizer.countToken(input)}" }
    catch (error: Exception) { counted = goldenFailure(error) }
    var repeated = "not_attempted"
    try { repeated = "ids:" + goldenIds(tokenizer.encode(input)) }
    catch (error: Exception) { repeated = goldenFailure(error) }
    "input:${input.size}:${goldenSha(input.toArray())};${encoded};${decoded};${counted};repeat:${repeated}"
}

private func goldenRecord(label: String, observation: String): Unit {
    let prefix = "TOKENIZER-GOLDEN-v1|metis|${label}|"
    let actual = prefix + observation
    if (getVariable("TOKENIZER_LEGACY_CAPTURE") == Some("1")) {
        let output = getStdOut()
        output.write((actual + "\n").toArray()); output.flush()
        return
    }
    if (LEGACY_TOKENIZER_GOLDEN.isEmpty()) { throw Exception("golden_baseline_not_frozen") }
    var expected: Option<String> = None
    for (line in LEGACY_TOKENIZER_GOLDEN.split('\n')) {
        if (line.startsWith(prefix)) {
            if (expected.isSome()) { throw Exception("golden_baseline_duplicate") }
            expected = Some(line)
        }
    }
    if (expected.isNone()) { throw Exception("golden_baseline_case_missing") }
    @Expect(actual, expected.getOrThrow())
}

private func goldenLongInput(): String {
    let result = StringBuilder()
    for (_ in 0..4096) { result.append("中文😀abcd \n") }
    let input = result.toString()
    @Expect(input.size, 65536)
    input
}

private func goldenInputs(): Array<(String, String)> {
    let nul = try { String.fromUtf8([0u8]) } catch (_: Exception) { throw Exception("golden_input_invalid") }
    [("empty", ""), ("ascii", "hello world 123!"), ("code", "func main() { println(\"hello\") }"),
     ("unicode", "中文😀混合🙂e\u{0301}"), ("controls", "A" + nul + "中文😀\r\n\tB"),
     ("quotes", "'\"\\$()`中文😀"), ("special", "a<|endoftext|>b<|fim_prefix|>c<|fim_middle|><|fim_suffix|><|endofprompt|>"),
     ("long64k", goldenLongInput()), ("leadingSpace", "  中文😀ab"), ("trailingSpace", "ab中文😀  "),
     ("numbers", "0 123 1234 9876543210"), ("cjkPunctuation", "你好，世界！中文。"),
     ("emojiZwj", "👩‍💻🏳\u{fe0f}‍🌈😀"), ("normalization", "é e\u{0301} Å A\u{030a}"),
     ("lineEndings", "a\r\nb\nc\rd"), ("multiScript", "中文 العربية हिन\u{094d}दी abc😀")]
}

private func goldenCorpus(label: String, tokenizer: Cl100kTokenizer, vocabulary: String): Unit {
    let identity = "vocab:${vocabulary.size}:${goldenSha(vocabulary.toArray())};"
    for ((name, input) in goldenInputs()) { goldenRecord(label + "." + name, identity + goldenObserve(tokenizer, input)) }
}

@When[os == "macOS"]
foreign {
    func getpgid(pid: Int32): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func __error(): CPointer<Int32>
}

private func goldenRequire(value: Bool): Unit {
    if (!value) { throw Exception("golden_owned_child_proof_failed") }
}

private func goldenPublish(home: Path, name: String, text: String): Unit {
    let pending = home.join(name + ".pending")
    File.writeTo(pending, text.toArray())
    rename(pending, to: home.join(name))
}

private func goldenRead(path: Path): String {
    goldenRequire(FileInfo(path).isRegular() && FileInfo(path).size <= 1048576)
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("golden_owned_input_invalid_encoding") }
}

private func goldenBinarySha(): String {
    let digest = SHA256()
    try (input = File(getCommand(), OpenMode.Read)) {
        let buffer = Array<Byte>(65536, repeat: 0)
        while (true) {
            let count = input.read(buffer)
            if (count == 0) { break }
            digest.write(buffer[0..count])
        }
    }
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    let result = StringBuilder()
    for (byte in digest.finish()) { result.append(digits[Int64(byte >> 4)]); result.append(digits[Int64(byte & 15)]) }
    result.toString()
}

@When[os == "macOS"]
private func goldenFdCount(): Int64 {
    // Reuse the existing utils package foreign declaration; do not redeclare it.
    var entries = VArray<UInt64, $4096>(repeat: 0)
    let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, inout entries, 32768) }
    goldenRequire(bytes > 0 && bytes < 32768 && bytes % 8 == 0)
    Int64(bytes / 8)
}

@When[os == "macOS"]
private func goldenGroupGone(pid: Int64): Bool {
    unsafe { kill(Int32(-pid), 0) } != 0 && unsafe { __error().read() } == 3
}

@When[enable_cl100k_tokenizer == "true" && os == "macOS"]
private func goldenFullCorpusChild(): Unit {
    let home = canonicalize(Path(getVariable("TOKENIZER_GOLDEN_CHILD_HOME").getOrThrow()))
    let nonce = getVariable("TOKENIZER_GOLDEN_CHILD_NONCE").getOrThrow()
    goldenRequire(!nonce.isEmpty() && nonce.runes().all({ rune => rune >= r'0' && rune <= r'9' }))
    goldenRequire(home.toString().startsWith("/private/tmp/"))
    let owner = home.join("owner")
    goldenRequire(FileInfo(owner).isRegular() && canonicalize(owner).toString() == owner.toString())
    goldenRequire(goldenRead(owner) == "tokenizer-golden-owner-v1\nnonce:${nonce}\nbinary:${goldenBinarySha()}\n")
    goldenRequire(getVariable("cjHeapSize").isNone() && getMaxHeapSize() == 268435456)
    let birth = observeProcessBirthIdentity(getProcessId()).getOrThrow().serialize()
    let receipt = "tokenizer-golden-child-v1\nnonce:${nonce}\npid:${getProcessId()}\nbirth:${birth}\nheap:${getMaxHeapSize()}\n"
    goldenPublish(home, "ready", receipt)
    let deadline = MonoTime.now() + Duration.second * 60
    while (!exists(home.join("release")) && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
    goldenRequire(goldenRead(home.join("release")) == nonce)
    goldenRecord("full.vocabulary", "bytes:${CL100K_BASE_TIKTOKEN.size};sha:${goldenSha(CL100K_BASE_TIKTOKEN.toArray())}")
    goldenCorpus("full.string", Cl100kTokenizer(CL100K_BASE_TIKTOKEN), CL100K_BASE_TIKTOKEN)
    let path = home.join("actual-cl100k.tiktoken")
    File.writeTo(path, CL100K_BASE_TIKTOKEN.toArray())
    goldenCorpus("full.path", Cl100kTokenizer(path), CL100K_BASE_TIKTOKEN)
    goldenPublish(home, "complete", receipt)
}

@When[enable_cl100k_tokenizer == "true" && os == "macOS"]
@Test
class TokenizerBehaviorTest {
    @TestCase
    public func fullCl100kLegacyGolden(): Unit {
        if (getVariable("TOKENIZER_GOLDEN_CHILD_NONCE").isSome()) { goldenFullCorpusChild(); return }
        goldenRequire(getMaxHeapSize() == 67108864)
        let home = canonicalize(Directory.createTemp("/tmp"))
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        let ownerText = "tokenizer-golden-owner-v1\nnonce:${nonce}\nbinary:${goldenBinarySha()}\n"
        goldenPublish(home, "owner", ownerText)
        File.writeTo(home.join("stdin"), [])
        let capture = getVariable("TOKENIZER_LEGACY_CAPTURE") == Some("1")
        let environment = HashMap(getVariables())
        for (key in environment.keys().toArray()) {
            let upper = key.toAsciiUpper()
            if (key.startsWith("METIS_PROCESS_RECOVERY_") || upper.contains("TOKEN") || upper.contains("SECRET") ||
                upper.contains("PASSWORD") || upper.contains("API_KEY") || upper.contains("AUTHORIZATION") ||
                upper.contains("ACCESS_KEY") || upper.contains("CREDENTIAL") || upper.contains("PROXY") ||
                ["cjHeapSize", "BASH_ENV", "ENV", "NODE_OPTIONS", "MRT_REPORT", "METIS_EMBED_REPORT_DIAGNOSTIC"].contains(key)) {
                environment.remove(key)
            }
        }
        environment["HOME"] = home.toString(); environment["TMPDIR"] = home.toString(); environment["METIS_HOME"] = home.toString()
        environment["TOKENIZER_GOLDEN_CHILD_HOME"] = home.toString(); environment["TOKENIZER_GOLDEN_CHILD_NONCE"] = nonce
        if (capture) { environment["TOKENIZER_LEGACY_CAPTURE"] = "1" }
        let baseline = (goldenFdCount(), getThreadCount(), getBlockingThreadCount())
        let records = ArrayList<String>()
        var child: Option<ManagedOwnedChild> = None
        var formal = false
        var actualReaped = false
        var actualCode: Int64 = -1
        var actualGroupGone = false
        try {
            try (input = File(home.join("stdin"), OpenMode.Read), output = File(home.join("stdout"), OpenMode.ReadWrite),
                error = File(home.join("stderr"), OpenMode.ReadWrite)) {
                let process = launchManagedRawChild(getCommand(),
                    ["--filter=TokenizerBehaviorTest.fullCl100kLegacyGolden", "--parallel=false", "--no-capture-output", "--no-progress", "--no-color"],
                    workingDirectory: Some(home), environment: Some<Map<String, String>>(environment),
                    stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output),
                    stdErr: ProcessRedirect.FromFile(error), newGeneration: true)
                child = Some(process)
                let birth = observeProcessBirthIdentity(process.pid).getOrThrow()
                goldenRequire(Int64(unsafe { getpgid(Int32(process.pid)) }) == process.pid)
                let deadline = MonoTime.now() + Duration.second * 60
                while (!exists(home.join("ready")) && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
                let expected = "tokenizer-golden-child-v1\nnonce:${nonce}\npid:${process.pid}\nbirth:${birth.serialize()}\nheap:268435456\n"
                goldenRequire(goldenRead(home.join("ready")) == expected)
                goldenRequire(observeProcessBirthIdentity(process.pid)?.serialize() == Some(birth.serialize()))
                goldenPublish(home, "release", nonce)
                goldenRequire(MonoTime.now() < deadline)
                let code = process.wait(timeout: Some(deadline - MonoTime.now()))
                actualCode = code
                actualReaped = true
                process.closeStreams()
                actualGroupGone = goldenGroupGone(process.pid)
                let gone = probeProcessBirthIdentity(birth, MonoTime.now() + Duration.second)
                goldenRequire(code == 0 && !process.isAlive() && process.streamsAreClosed() && actualGroupGone && gone.conclusive && !gone.alive)
                goldenRequire(goldenRead(home.join("complete")) == expected && goldenRead(home.join("owner")) == ownerText)
            }
            let stable = MonoTime.now() + Duration.second * 2
            while ((goldenFdCount() != baseline[0] || getThreadCount() > baseline[1] || getBlockingThreadCount() > baseline[2]) &&
                MonoTime.now() < stable) { sleep(Duration.millisecond) }
            goldenRequire(goldenFdCount() == baseline[0] && getThreadCount() <= baseline[1] && getBlockingThreadCount() <= baseline[2])
            let labels = HashSet<String>()
            for (line in goldenRead(home.join("stdout")).split('\n')) {
                if (line.startsWith("TOKENIZER-GOLDEN-v1|metis|")) {
                    let fields = line.split("|"); goldenRequire(fields.size == 4 && !labels.contains(fields[2]))
                    labels.add(fields[2]); records.add(line)
                }
            }
            if (getVariable("TOKENIZER_LEGACY_CAPTURE") == Some("1")) { goldenRequire(records.size == 33) }
            else { goldenRequire(records.isEmpty()) }
            formal = true
        } finally {
            // This receipt is always saved before any fallback can change resources.
            try {
                goldenPublish(home, "formal", "formal:${formal}\nreaped:${actualReaped}\ngroupGone:${actualGroupGone}\nactualCode:${actualCode}\nparentHeap:${getMaxHeapSize()}\nfdBefore:${baseline[0]}\nfdAfter:${goldenFdCount()}\ncjBefore:${baseline[1]}\ncjAfter:${getThreadCount()}\nblockingBefore:${baseline[2]}\nblockingAfter:${getBlockingThreadCount()}\n")
            } finally {
                if (!formal) {
                    if (let Some(process) <- child) {
                        try { process.terminate(); let _ = process.wait(timeout: Some(Duration.second * 5)) }
                        catch (_: Exception) { () }
                        process.closeStreams()
                    }
                }
            }
        }
        // Forward only a completely reaped, source-bound capture, never partial output.
        let output = getStdOut()
        for (record in records) { output.write((record + "\n").toArray()) }
        let phase = if (capture) { "CAPTURE" } else { "FORMAL" }
        output.write(("TOKENIZER-${phase}-COMPLETE-v1|metis|full|${records.size}\n").toArray())
        output.flush()
        // Retain owned input/stdout/stderr/receipts in both success and failure modes.
    }
}

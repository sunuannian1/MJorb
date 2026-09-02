import Foundation
import CryptoKit

/// 给 Mach-O 二进制添加 ad-hoc 签名
/// 解决 ldid 处理大文件时崩溃的问题：未签名或签名无效的 Mach-O 会导致 ldid 断言失败
/// 参考 Fladder issue #800 的解决方案：签名前先给所有 Mach-O 加 ad-hoc 签名
struct MachOAdHocSigner {

    // MARK: - Mach-O 常量

    private static let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    private static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1D

    // MARK: - 签名常量

    private static let CS_MAGIC_CODEDIRECTORY: UInt32 = 0xFADE0C02
    private static let CS_MAGIC_EMBEDDED_SIGNATURE: UInt32 = 0xFADE0CC1
    private static let CS_HASHTYPE_SHA256: UInt8 = 0x2
    private static let kSecCodeSignatureAdhoc: UInt32 = 0x2
    private static let pageSize: Int = 4096

    // MARK: - 架构信息

    private struct FatArch {
        let cputype: UInt32
        let cpusubtype: UInt32
        let offset: UInt32
        let size: UInt32
        let align: UInt32
    }

    // MARK: - 公开接口

    /// 给 App bundle 里所有 Mach-O 二进制加 ad-hoc 签名
    static func signAllBinaries(in appURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 100_000 else { continue }
            try? signFile(at: url)
        }
    }

    /// 给单个文件加 ad-hoc 签名
    @discardableResult
    static func signFile(at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard data.count >= 4 else { return false }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        if magic == FAT_MAGIC || magic == FAT_MAGIC.byteSwapped {
            return try signFATBinary(data: data, url: url)
        } else if magic == MH_MAGIC_64 || magic == MH_MAGIC_64.byteSwapped {
            return try signThinBinary(data: data, url: url)
        }
        return false
    }

    // MARK: - FAT 二进制

    private static func signFATBinary(data: Data, url: URL) throws -> Bool {
        let isBigEndian = data.withUnsafeBytes { $0.load(as: UInt32.self) } == FAT_MAGIC
        let nfatArch = readUInt32(data, offset: 4, bigEndian: isBigEndian)
        guard nfatArch > 0, nfatArch <= 10 else { return false }

        var archInfos: [FatArch] = []
        for i in 0..<Int(nfatArch) {
            let archOffset = 8 + i * 20
            archInfos.append(FatArch(
                cputype: readUInt32(data, offset: archOffset, bigEndian: isBigEndian),
                cpusubtype: readUInt32(data, offset: archOffset + 4, bigEndian: isBigEndian),
                offset: readUInt32(data, offset: archOffset + 8, bigEndian: isBigEndian),
                size: readUInt32(data, offset: archOffset + 12, bigEndian: isBigEndian),
                align: readUInt32(data, offset: archOffset + 16, bigEndian: isBigEndian)
            ))
        }

        // 给每个架构加签名
        var newArchData: [Data] = []
        var anySigned = false
        for info in archInfos {
            let archData = data.subdata(in: Int(info.offset)..<Int(info.offset + info.size))
            if let signed = try? signThinBinaryData(archData) {
                newArchData.append(signed)
                anySigned = true
            } else {
                newArchData.append(archData)
            }
        }

        guard anySigned else { return false }

        // 重新构建 FAT 二进制
        var result = Data()
        let headerSize = 8 + Int(nfatArch) * 20
        var currentOffset = UInt32((headerSize + pageSize - 1) / pageSize * pageSize)

        var archOffsets: [UInt32] = []
        for archData in newArchData {
            archOffsets.append(currentOffset)
            currentOffset += UInt32(archData.count)
            currentOffset = UInt32((Int(currentOffset) + pageSize - 1) / pageSize * pageSize)
        }

        // 写 FAT 头（始终大端）
        result.append(contentsOf: withUnsafeBytes(of: FAT_MAGIC.bigEndian) { Data($0) })
        result.append(contentsOf: withUnsafeBytes(of: nfatArch.bigEndian) { Data($0) })

        for (i, info) in archInfos.enumerated() {
            result.append(contentsOf: withUnsafeBytes(of: info.cputype.bigEndian) { Data($0) })
            result.append(contentsOf: withUnsafeBytes(of: info.cpusubtype.bigEndian) { Data($0) })
            result.append(contentsOf: withUnsafeBytes(of: archOffsets[i].bigEndian) { Data($0) })
            result.append(contentsOf: withUnsafeBytes(of: UInt32(newArchData[i].count).bigEndian) { Data($0) })
            result.append(contentsOf: withUnsafeBytes(of: info.align.bigEndian) { Data($0) })
        }

        // 写每个架构的数据（带对齐填充）
        for (i, archData) in newArchData.enumerated() {
            while result.count < Int(archOffsets[i]) {
                result.append(0)
            }
            result.append(archData)
        }

        try result.write(to: url)
        return true
    }

    // MARK: - Thin 二进制

    private static func signThinBinary(data: Data, url: URL) throws -> Bool {
        guard let signed = try signThinBinaryData(data) else { return false }
        try signed.write(to: url)
        return true
    }

    private static func signThinBinaryData(_ data: Data) throws -> Data? {
        guard data.count >= 32 else { return nil }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let isBigEndian = magic == MH_MAGIC_64.byteSwapped
        guard magic == MH_MAGIC_64 || isBigEndian else { return nil }

        let ncmds = readUInt32(data, offset: 16, bigEndian: isBigEndian)
        let sizeofcmds = readUInt32(data, offset: 20, bigEndian: isBigEndian)

        // 遍历 load commands
        var linkeditFileOffset: UInt64 = 0
        var codeSigCmdOffset: Int = 0
        var hasCodeSignature = false

        var cmdOffset = 32
        for _ in 0..<Int(ncmds) {
            guard cmdOffset + 8 <= data.count else { break }
            let cmd = readUInt32(data, offset: cmdOffset, bigEndian: isBigEndian)
            let cmdsize = readUInt32(data, offset: cmdOffset + 4, bigEndian: isBigEndian)

            if cmd == LC_SEGMENT_64 {
                if cmdOffset + 72 <= data.count {
                    let segname = String(data: data.subdata(in: cmdOffset+8..<cmdOffset+24), encoding: .utf8)?
                        .trimmingCharacters(in: .controlCharacters) ?? ""
                    if segname == "__LINKEDIT" {
                        linkeditFileOffset = readUInt64(data, offset: cmdOffset + 40, bigEndian: isBigEndian)
                    }
                }
            } else if cmd == LC_CODE_SIGNATURE {
                hasCodeSignature = true
                codeSigCmdOffset = cmdOffset
            }

            cmdOffset += Int(cmdsize)
        }

        // 计算代码区域大小
        let codeLimit: Int = linkeditFileOffset > 0 ? Int(linkeditFileOffset) : data.count

        // 计算页面哈希
        let pageCount = (codeLimit + pageSize - 1) / pageSize
        var pageHashes: [Data] = []
        pageHashes.reserveCapacity(pageCount)
        for i in 0..<pageCount {
            let pageStart = i * pageSize
            let pageEnd = min(pageStart + pageSize, codeLimit)
            let hash = SHA256.hash(data: data.subdata(in: pageStart..<pageEnd))
            pageHashes.append(Data(hash))
        }

        // 生成 CodeDirectory
        let identifierData = "ad-hoc".data(using: .utf8)! + Data([0])
        let codeDirectorySize = 156 + identifierData.count + pageHashes.count * 32
        let codeDirectoryPadded = (codeDirectorySize + 3) / 4 * 4

        var codeDirectory = Data(capacity: codeDirectoryPadded)
        codeDirectory.append(contentsOf: withUnsafeBytes(of: CS_MAGIC_CODEDIRECTORY.bigEndian) { Data($0) })
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(codeDirectorySize).bigEndian) { Data($0) })
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0x20100).bigEndian) { Data($0) }) // version
        codeDirectory.append(contentsOf: withUnsafeBytes(of: kSecCodeSignatureAdhoc.bigEndian) { Data($0) }) // flags
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(156).bigEndian) { Data($0) }) // hashOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(156).bigEndian) { Data($0) }) // identOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(pageCount).bigEndian) { Data($0) }) // nCodeSlots
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(codeLimit).bigEndian) { Data($0) }) // codeLimit
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt8(32)) { Data($0) }) // hashSize
        codeDirectory.append(contentsOf: withUnsafeBytes(of: CS_HASHTYPE_SHA256) { Data($0) }) // hashType
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt8(0)) { Data($0) }) // platform
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt8(0xC)) { Data($0) }) // pageSize (1<<12)
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // spare2
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // scatterOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // teamOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // spare3
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // codeLimit64
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // execSegBase
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // execSegLimit
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // execSegFlags
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // runtime
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // preEncryptOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // jitConstraintOffset
        codeDirectory.append(identifierData)
        for hash in pageHashes {
            codeDirectory.append(hash)
        }
        while codeDirectory.count < codeDirectoryPadded {
            codeDirectory.append(0)
        }

        // 生成 SuperBlob
        let superBlobSize = 12 + codeDirectoryPadded
        var superBlob = Data(capacity: superBlobSize)
        superBlob.append(contentsOf: withUnsafeBytes(of: CS_MAGIC_EMBEDDED_SIGNATURE.bigEndian) { Data($0) })
        superBlob.append(contentsOf: withUnsafeBytes(of: UInt32(superBlobSize).bigEndian) { Data($0) })
        superBlob.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian) { Data($0) }) // count
        superBlob.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // type (CodeDirectory)
        superBlob.append(contentsOf: withUnsafeBytes(of: UInt32(12).bigEndian) { Data($0) }) // offset
        superBlob.append(codeDirectory)

        // 在文件末尾追加签名数据
        let signatureOffset = data.count
        var result = data
        result.append(superBlob)

        if hasCodeSignature {
            // 修改已有的 LC_CODE_SIGNATURE 指向新签名
            result.replaceSubrange(
                codeSigCmdOffset + 8..<codeSigCmdOffset + 12,
                with: withUnsafeBytes(of: UInt32(signatureOffset)) { Data($0) }
            )
            result.replaceSubrange(
                codeSigCmdOffset + 12..<codeSigCmdOffset + 16,
                with: withUnsafeBytes(of: UInt32(superBlob.count)) { Data($0) }
            )
        } else {
            // 添加新的 LC_CODE_SIGNATURE load command
            let newCmdSize: UInt32 = 16
            var newCmd = Data()
            newCmd.append(contentsOf: withUnsafeBytes(of: LC_CODE_SIGNATURE) { Data($0) })
            newCmd.append(contentsOf: withUnsafeBytes(of: newCmdSize) { Data($0) })
            newCmd.append(contentsOf: withUnsafeBytes(of: UInt32(signatureOffset + Int(newCmdSize))) { Data($0) })
            newCmd.append(contentsOf: withUnsafeBytes(of: UInt32(superBlob.count)) { Data($0) })

            let insertOffset = 32 + Int(sizeofcmds)
            result.insert(contentsOf: newCmd, at: insertOffset)

            // 更新 mach_header
            result.replaceSubrange(16..<20, with: withUnsafeBytes(of: ncmds + 1) { Data($0) })
            result.replaceSubrange(20..<24, with: withUnsafeBytes(of: sizeofcmds + newCmdSize) { Data($0) })

            // 更新所有 LC_SEGMENT_64 的 fileoff（加 newCmdSize）
            var updateOffset = 32
            let updatedNcmds = ncmds + 1
            for _ in 0..<Int(updatedNcmds) {
                guard updateOffset + 8 <= result.count else { break }
                let cmd = readUInt32(result, offset: updateOffset, bigEndian: isBigEndian)
                let cmdsize = readUInt32(result, offset: updateOffset + 4, bigEndian: isBigEndian)
                if cmd == LC_SEGMENT_64 && updateOffset + 56 <= result.count {
                    let fileoff = readUInt64(result, offset: updateOffset + 40, bigEndian: isBigEndian)
                    result.replaceSubrange(
                        updateOffset + 40..<updateOffset + 48,
                        with: withUnsafeBytes(of: fileoff + UInt64(newCmdSize)) { Data($0) }
                    )
                }
                updateOffset += Int(cmdsize)
            }
        }

        return result
    }

    // MARK: - 工具函数

    private static func readUInt32(_ data: Data, offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let value = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) }
        return bigEndian ? value.bigEndian : value
    }

    private static func readUInt64(_ data: Data, offset: Int, bigEndian: Bool) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let value = data.subdata(in: offset..<offset + 8).withUnsafeBytes { $0.load(as: UInt64.self) }
        return bigEndian ? value.bigEndian : value
    }
}

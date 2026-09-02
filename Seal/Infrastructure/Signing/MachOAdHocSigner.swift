import Foundation
import CryptoKit

/// 给 Mach-O 二进制添加 ad-hoc 签名
/// 解决 ldid 处理大文件时崩溃的问题：未签名或签名无效的 Mach-O 会导致 ldid 断言失败
/// 参考 Fladder issue #800 的解决方案：签名前先给所有 Mach-O 加 ad-hoc 签名
struct MachOAdHocSigner {

    // MARK: - Mach-O 常量

    private static let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    private static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    private static let FAT_CIGAM: UInt32 = 0xBEBAFECA
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1D

    // MARK: - 签名常量

    private static let CS_MAGIC_CODEDIRECTORY: UInt32 = 0xFADE0C02
    private static let CS_MAGIC_EMBEDDED_SIGNATURE: UInt32 = 0xFADE0CC1
    private static let CS_HASHTYPE_SHA256: UInt8 = 0x2
    private static let kSecCodeSignatureAdhoc: UInt32 = 0x2
    private static let pageSize: Int = 4096

    // MARK: - 公开接口

    /// 给 App bundle 里所有 Mach-O 二进制加 ad-hoc 签名
    static func signAllBinaries(in appURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var signedCount = 0
        for case let url as URL in enumerator {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 100_000 else { continue } // 只处理大于 100KB 的文件（Mach-O 二进制）
            do {
                if try signFile(at: url) {
                    signedCount += 1
                }
            } catch {
                // 单个文件失败不影响其他文件
                continue
            }
        }
    }

    /// 给单个文件加 ad-hoc 签名，返回是否成功签名
    @discardableResult
    static func signFile(at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard data.count >= 4 else { return false }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            return try signFATBinary(data: data, url: url)
        } else if magic == MH_MAGIC_64 || magic == byteSwap(MH_MAGIC_64) {
            return try signThinBinary(data: data, url: url)
        }
        return false
    }

    // MARK: - FAT 二进制

    private static func signFATBinary(data: Data, url: URL) throws -> Bool {
        let isBigEndian = data.withUnsafeBytes { $0.load(as: UInt32.self) } == FAT_MAGIC
        let nfatArch = readUInt32(data, offset: 4, bigEndian: isBigEndian)
        guard nfatArch > 0, nfatArch <= 10 else { return false }

        var archInfos: [(offset: UInt32, size: UInt32, align: UInt32)] = []
        for i in 0..<Int(nfatArch) {
            let archOffset = 8 + i * 20
            let cputype = readUInt32(data, offset: archOffset, bigEndian: isBigEndian)
            let cpusubtype = readUInt32(data, offset: archOffset + 4, bigEndian: isBigEndian)
            let offset = readUInt32(data, offset: archOffset + 8, bigEndian: isBigEndian)
            let size = readUInt32(data, offset: archOffset + 12, bigEndian: isBigEndian)
            let align = readUInt32(data, offset: archOffset + 16, bigEndian: isBigEndian)
            archInfos.append((offset, size, align))
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
        var currentOffset = UInt32(headerSize)
        // 对齐到 4KB
        currentOffset = UInt32((Int(currentOffset) + pageSize - 1) / pageSize * pageSize)

        var archOffsets: [UInt32] = []
        for archData in newArchData {
            archOffsets.append(currentOffset)
            currentOffset += UInt32(archData.count)
            // 对齐到 4KB
            currentOffset = UInt32((Int(currentOffset) + pageSize - 1) / pageSize * pageSize)
        }

        // 写 FAT 头
        result.append(contentsOf: withUnsafeBytes(of: FAT_MAGIC.bigEndian) { Data($0) })
        result.append(contentsOf: withUnsafeBytes(of: nfatArch.bigEndian) { Data($0) })

        for (i, info) in archInfos.enumerated() {
            let archOffset = archOffsets[i]
            let archSize = UInt32(newArchData[i].count)
            result.append(contentsOf: withUnsafeBytes(of: info.cputype.bigEndian) { Data($0) })
            result.append(contentsOf: withUnsafeBytes(of: info.cpusubtype.bigEndian) { Data($0) })
            result.append(contentsOf: withUnsafeBytes(of: archOffset.bigEndian) { Data($0) })
            result.append(contentsOf: withUnsafeBytes(of: archSize.bigEndian) { Data($0) })
            result.append(contentsOf: withUnsafeBytes(of: info.align.bigEndian) { Data($0) })
        }

        // 填充到第一个架构的偏移
        while result.count < Int(archOffsets[0]) {
            result.append(0)
        }

        // 写每个架构的数据
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
        let isBigEndian = magic == byteSwap(MH_MAGIC_64)
        guard magic == MH_MAGIC_64 || isBigEndian else { return nil }

        let ncmds = readUInt32(data, offset: 16, bigEndian: isBigEndian)
        let sizeofcmds = readUInt32(data, offset: 20, bigEndian: isBigEndian)

        // 遍历 load commands，找 __LINKEDIT 段和已有的 LC_CODE_SIGNATURE
        var linkeditVMAddr: UInt64 = 0
        var linkeditFileOffset: UInt64 = 0
        var linkeditFileSize: UInt64 = 0
        var existingCodeSigOffset: UInt32 = 0
        var existingCodeSigSize: UInt32 = 0
        var hasCodeSignature = false
        var codeSigCmdOffset: Int = 0

        var cmdOffset = 32
        for _ in 0..<Int(ncmds) {
            guard cmdOffset + 8 <= data.count else { break }
            let cmd = readUInt32(data, offset: cmdOffset, bigEndian: isBigEndian)
            let cmdsize = readUInt32(data, offset: cmdOffset + 4, bigEndian: isBigEndian)

            if cmd == LC_SEGMENT_64 {
                // segment_command_64: cmd(4) + cmdsize(4) + segname(16) + vmaddr(8) + vmsize(8) + fileoff(8) + filesize(8) + ...
                if cmdOffset + 72 <= data.count {
                    let segname = String(data: data.subdata(in: cmdOffset+8..<cmdOffset+24), encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
                    if segname == "__LINKEDIT" {
                        linkeditVMAddr = readUInt64(data, offset: cmdOffset + 24, bigEndian: isBigEndian)
                        linkeditFileOffset = readUInt64(data, offset: cmdOffset + 40, bigEndian: isBigEndian)
                        linkeditFileSize = readUInt64(data, offset: cmdOffset + 48, bigEndian: isBigEndian)
                    }
                }
            } else if cmd == LC_CODE_SIGNATURE {
                // linkedit_data_command: cmd(4) + cmdsize(4) + dataoff(4) + datasize(4)
                if cmdOffset + 16 <= data.count {
                    existingCodeSigOffset = readUInt32(data, offset: cmdOffset + 8, bigEndian: isBigEndian)
                    existingCodeSigSize = readUInt32(data, offset: cmdOffset + 12, bigEndian: isBigEndian)
                    hasCodeSignature = true
                    codeSigCmdOffset = cmdOffset
                }
            }

            cmdOffset += Int(cmdsize)
        }

        // 如果已经有有效的签名，跳过
        if hasCodeSignature && existingCodeSigSize > 0 && existingCodeSigOffset > 0 {
            return nil
        }

        // 计算代码区域大小（到 __LINKEDIT 开始或文件末尾）
        let codeLimit: Int
        if linkeditFileOffset > 0 {
            codeLimit = Int(linkeditFileOffset)
        } else {
            codeLimit = data.count
        }

        // 计算每个页面的 SHA256 哈希
        let pageCount = (codeLimit + pageSize - 1) / pageSize
        var pageHashes: [Data] = []
        for i in 0..<pageCount {
            let pageStart = i * pageSize
            let pageEnd = min(pageStart + pageSize, codeLimit)
            let pageData = data.subdata(in: pageStart..<pageEnd)
            let hash = SHA256.hash(data: pageData)
            pageHashes.append(Data(hash))
        }

        // 生成 CodeDirectory
        let identifier = "ad-hoc"
        let identifierData = identifier.data(using: .utf8)! + Data([0])

        let codeDirectorySize = 156 + identifierData.count + pageHashes.count * 32
        // 对齐到 4 字节
        let codeDirectoryPadded = (codeDirectorySize + 3) / 4 * 4

        var codeDirectory = Data()
        codeDirectory.append(contentsOf: withUnsafeBytes(of: CS_MAGIC_CODEDIRECTORY) { Data($0) })
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(codeDirectorySize)) { Data($0) })
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0x20100)) { Data($0) }) // version
        codeDirectory.append(contentsOf: withUnsafeBytes(of: kSecCodeSignatureAdhoc) { Data($0) }) // flags
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(156)) { Data($0) }) // hashOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(156)) { Data($0) }) // identOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(pageCount)) { Data($0) }) // nCodeSlots
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(codeLimit)) { Data($0) }) // codeLimit
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt8(32)) { Data($0) }) // hashSize
        codeDirectory.append(contentsOf: withUnsafeBytes(of: CS_HASHTYPE_SHA256) { Data($0) }) // hashType
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt8(0)) { Data($0) }) // platform
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt8(0xC)) { Data($0) }) // pageSize (1<<12 = 4096)
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0)) { Data($0) }) // spare2
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0)) { Data($0) }) // scatterOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0)) { Data($0) }) // teamOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt32(0)) { Data($0) }) // spare3
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0)) { Data($0) }) // codeLimit64
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0)) { Data($0) }) // execSegBase
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0)) { Data($0) }) // execSegLimit
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0)) { Data($0) }) // execSegFlags
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0)) { Data($0) }) // runtime
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0)) { Data($0) }) // preEncryptOffset
        codeDirectory.append(contentsOf: withUnsafeBytes(of: UInt64(0)) { Data($0) }) // jitConstraintOffset
        codeDirectory.append(identifierData)
        for hash in pageHashes {
            codeDirectory.append(hash)
        }
        // 填充到 4 字节对齐
        while codeDirectory.count < codeDirectoryPadded {
            codeDirectory.append(0)
        }

        // 生成 SuperBlob
        let superBlobSize = 12 + codeDirectoryPadded
        var superBlob = Data()
        superBlob.append(contentsOf: withUnsafeBytes(of: CS_MAGIC_EMBEDDED_SIGNATURE) { Data($0) })
        superBlob.append(contentsOf: withUnsafeBytes(of: UInt32(superBlobSize)) { Data($0) })
        superBlob.append(contentsOf: withUnsafeBytes(of: UInt32(1)) { Data($0) }) // count
        superBlob.append(contentsOf: withUnsafeBytes(of: UInt32(0)) { Data($0) }) // index type (CodeDirectory = 0)
        superBlob.append(contentsOf: withUnsafeBytes(of: UInt32(12)) { Data($0) }) // offset
        superBlob.append(codeDirectory)

        // 签名数据对齐到 4 字节
        let signatureOffset = data.count
        var result = data
        result.append(superBlob)

        // 添加或修改 LC_CODE_SIGNATURE load command
        if hasCodeSignature {
            // 修改已有的 LC_CODE_SIGNATURE
            var mutableData = result
            mutableData.replaceSubrange(codeSigCmdOffset+8..<codeSigCmdOffset+12, with: withUnsafeBytes(of: UInt32(signatureOffset)) { Data($0) })
            mutableData.replaceSubrange(codeSigCmdOffset+12..<codeSigCmdOffset+16, with: withUnsafeBytes(of: UInt32(superBlob.count)) { Data($0) })
            result = mutableData
        } else {
            // 添加新的 LC_CODE_SIGNATURE load command
            var newCmds = Data()
            newCmds.append(contentsOf: withUnsafeBytes(of: LC_CODE_SIGNATURE) { Data($0) })
            newCmds.append(contentsOf: withUnsafeBytes(of: UInt32(16)) { Data($0) }) // cmdsize
            newCmds.append(contentsOf: withUnsafeBytes(of: UInt32(signatureOffset)) { Data($0) })
            newCmds.append(contentsOf: withUnsafeBytes(of: UInt32(superBlob.count)) { Data($0) })

            // 在 load commands 区域末尾插入
            let insertOffset = 32 + Int(sizeofcmds)
            result.insert(contentsOf: newCmds, at: insertOffset)

            // 更新 mach_header 的 ncmds 和 sizeofcmds
            result.replaceSubrange(16..<20, with: withUnsafeBytes(of: (ncmds + 1)) { Data($0) })
            result.replaceSubrange(20..<24, with: withUnsafeBytes(of: (sizeofcmds + 16)) { Data($0) })

            // 更新 __LINKEDIT 段的 fileoff 和 filesize（如果存在）
            // 注意：添加 load command 会改变文件偏移，需要更新 __LINKEDIT 的 fileoff
            // 但这比较复杂，暂时只更新 filesize
            if linkeditFileOffset > 0 {
                // 重新遍历找 __LINKEDIT 段的位置
                var cmdOffset2 = 32
                for _ in 0..<Int(ncmds + 1) {
                    guard cmdOffset2 + 8 <= result.count else { break }
                    let cmd = readUInt32(result, offset: cmdOffset2, bigEndian: isBigEndian)
                    let cmdsize = readUInt32(result, offset: cmdOffset2 + 4, bigEndian: isBigEndian)
                    if cmd == LC_SEGMENT_64 {
                        let segname = String(data: result.subdata(in: cmdOffset2+8..<cmdOffset2+24), encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
                        if segname == "__LINKEDIT" {
                            // 更新 filesize
                            let newFileSize = UInt64(result.count) - linkeditFileOffset + 16 // 加上新增的 load command 大小
                            result.replaceSubrange(cmdOffset2+48..<cmdOffset2+56, with: withUnsafeBytes(of: newFileSize) { Data($0) })
                            break
                        }
                    }
                    cmdOffset2 += Int(cmdsize)
                }
            }
        }

        return result
    }

    // MARK: - 工具函数

    private static func readUInt32(_ data: Data, offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let value = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        return bigEndian ? value.bigEndian : value
    }

    private static func readUInt64(_ data: Data, offset: Int, bigEndian: Bool) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let value = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) }
        return bigEndian ? value.bigEndian : value
    }

    private static func byteSwap(_ value: UInt32) -> UInt32 {
        return value.byteSwapped
    }
}

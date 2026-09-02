import Foundation
import CryptoKit

/// 纯 Swift 实现的完整代码签名，不依赖 ldid
/// 对齐 ldid 官方 CodeDirectory v0x20400 结构
/// 大文件分块处理，不一次性加载，解决 ldid.cpp(538) 内存不足崩溃
enum MachOFullSigner {
    private static let pageSize = 4096
    private static let csMagicCodeDirectory: UInt32 = 0xFADE0C02
    private static let csMagicEmbeddedSignature: UInt32 = 0xFADE0CC1
    private static let csMagicBlobWrapper: UInt32 = 0xFADE0B01

    // SuperBlob slot types
    private static let slotCodeDirectory: UInt32 = 0x00000000
    private static let slotCertificateChain: UInt32 = 0x00000002
    private static let slotEntitlements: UInt32 = 0x00000005
    private static let slotSignature: UInt32 = 0x00001000

    // CodeDirectory 特殊槽位：entitlements 是 slot -5，所以 nSpecialSlots=5
    private static let entitlementsSlot: Int = -5
    private static let nSpecialSlots: UInt32 = 5

    /// 给 IPA 中所有 Mach-O 二进制加完整证书签名
    static func signAllBinaries(
        in appURL: URL,
        certificateData: Data,
        privateKey: SecKey,
        teamID: String,
        bundleID: String = "ad-hoc",
        entitlements: Data? = nil
    ) throws {
        let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return }

        var machOFiles: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 100_000 else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 4),
                  header.count >= 4 else { continue }
            let magic = header.withUnsafeBytes { $0.load(as: UInt32.self) }
            if magic == 0xFEEDFACF || magic == 0xCAFEBABE || magic == 0xBEBAFECA {
                machOFiles.append(url)
            }
        }

        for url in machOFiles {
            try signMachO(at: url, certificateData: certificateData, privateKey: privateKey, teamID: teamID, bundleID: bundleID, entitlements: entitlements)
        }
    }

    private static func signMachO(
        at url: URL,
        certificateData: Data,
        privateKey: SecKey,
        teamID: String,
        bundleID: String,
        entitlements: Data?
    ) throws {
        let data = try Data(contentsOf: url)
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            try signFAT(data: data, url: url, certificateData: certificateData, privateKey: privateKey, teamID: teamID, bundleID: bundleID, entitlements: entitlements)
        } else {
            let signed = try signThin(data: data, certificateData: certificateData, privateKey: privateKey, teamID: teamID, bundleID: bundleID, entitlements: entitlements)
            try signed.write(to: url, options: .atomic)
        }
    }

    // MARK: - FAT 二进制

    private struct FatArch {
        let cputype: UInt32
        let cpusubtype: UInt32
        let offset: UInt32
        let size: UInt32
        let align: UInt32
    }

    private static func signFAT(
        data: Data,
        url: URL,
        certificateData: Data,
        privateKey: SecKey,
        teamID: String,
        bundleID: String,
        entitlements: Data?
    ) throws {
        let isBigEndian = data.withUnsafeBytes { $0.load(as: UInt32.self) } == 0xCAFEBABE
        let nfatArch = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let archCount = isBigEndian ? nfatArch.bigEndian : nfatArch

        var archs: [FatArch] = []
        for i in 0..<Int(archCount) {
            let off = 8 + i * 20
            let cputype = data.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }
            let cpusubtype = data.withUnsafeBytes { $0.load(fromByteOffset: off + 4, as: UInt32.self) }
            let offset = data.withUnsafeBytes { $0.load(fromByteOffset: off + 8, as: UInt32.self) }
            let size = data.withUnsafeBytes { $0.load(fromByteOffset: off + 12, as: UInt32.self) }
            let align = data.withUnsafeBytes { $0.load(fromByteOffset: off + 16, as: UInt32.self) }
            archs.append(FatArch(
                cputype: isBigEndian ? cputype.bigEndian : cputype,
                cpusubtype: isBigEndian ? cpusubtype.bigEndian : cpusubtype,
                offset: isBigEndian ? offset.bigEndian : offset,
                size: isBigEndian ? size.bigEndian : size,
                align: isBigEndian ? align.bigEndian : align
            ))
        }

        var output = Data()
        output.append(contentsOf: withUnsafeBytes(of: (isBigEndian ? 0xCAFEBABE : 0xBEBAFECA).bigEndian) { Data($0) })
        output.append(contentsOf: withUnsafeBytes(of: archCount.bigEndian) { Data($0) })

        var signedArchs: [Data] = []
        for arch in archs {
            let archData = data.subdata(in: Int(arch.offset)..<Int(arch.offset + arch.size))
            let signed = try signThin(data: archData, certificateData: certificateData, privateKey: privateKey, teamID: teamID, bundleID: bundleID, entitlements: entitlements)
            signedArchs.append(signed)
        }

        var currentOffset = 8 + Int(archCount) * 20
        for (i, arch) in archs.enumerated() {
            let signedSize = UInt32(signedArchs[i].count)
            output.append(contentsOf: withUnsafeBytes(of: arch.cputype.bigEndian) { Data($0) })
            output.append(contentsOf: withUnsafeBytes(of: arch.cpusubtype.bigEndian) { Data($0) })
            output.append(contentsOf: withUnsafeBytes(of: UInt32(currentOffset).bigEndian) { Data($0) })
            output.append(contentsOf: withUnsafeBytes(of: signedSize.bigEndian) { Data($0) })
            output.append(contentsOf: withUnsafeBytes(of: arch.align.bigEndian) { Data($0) })
            currentOffset += Int(signedSize)
            let pad = (pageSize - (currentOffset % pageSize)) % pageSize
            currentOffset += pad
        }

        for (i, signedData) in signedArchs.enumerated() {
            output.append(signedData)
            if i < signedArchs.count - 1 {
                let pad = (pageSize - (output.count % pageSize)) % pageSize
                output.append(Data(repeating: 0, count: pad))
            }
        }

        try output.write(to: url, options: .atomic)
    }

    // MARK: - Thin 二进制签名

    private static func signThin(
        data: Data,
        certificateData: Data,
        privateKey: SecKey,
        teamID: String,
        bundleID: String,
        entitlements: Data?
    ) throws -> Data {
        let ncmds = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        let sizeofcmds = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }

        var linkeditFileOffset: UInt64 = 0
        var linkeditCmdOffset: Int = 0
        var existingCodeSigOffset: UInt32 = 0
        var existingCodeSigCmdOffset: Int = 0
        var hasCodeSignature = false
        var segmentOffsets: [(fileoff: UInt64, index: Int)] = []
        var execSegBase: UInt64 = 0
        var execSegLimit: UInt64 = 0
        var execSegFlags: UInt64 = 0

        var cmdOffset = 32
        for _ in 0..<ncmds {
            let cmd = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset, as: UInt32.self) }
            let cmdsize = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 4, as: UInt32.self) }

            if cmd == 0x19 { // LC_SEGMENT_64
                let segname = String(data: data.subdata(in: cmdOffset+8..<cmdOffset+24), encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? ""
                let fileoff = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 40, as: UInt64.self) }
                if segname == "__LINKEDIT" {
                    linkeditFileOffset = fileoff
                    linkeditCmdOffset = cmdOffset
                }
                if segname == "__TEXT" {
                    execSegBase = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 24, as: UInt64.self) }
                    execSegLimit = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 32, as: UInt64.self) }
                    let segFlags = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 56, as: UInt32.self) }
                    execSegFlags = (segFlags & 0x1) != 0 ? 1 : 0
                }
                segmentOffsets.append((fileoff: fileoff, index: cmdOffset))
            }

            if cmd == 0x1D { // LC_CODE_SIGNATURE
                existingCodeSigOffset = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 8, as: UInt32.self) }
                existingCodeSigCmdOffset = cmdOffset
                hasCodeSignature = true
            }

            cmdOffset += Int(cmdsize)
        }

        // 第一步：构造待签名的 output（截断旧签名 / 插入新 LC_CODE_SIGNATURE）
        var output: Data
        var codeLimit: Int
        var actualLinkeditOffset: UInt64

        if hasCodeSignature {
            // 截断旧签名数据，codeLimit = 旧签名开始位置
            codeLimit = Int(existingCodeSigOffset)
            output = data.prefix(upTo: codeLimit)
            actualLinkeditOffset = linkeditFileOffset
        } else {
            // 插入新的 LC_CODE_SIGNATURE load command（16字节）
            let newCmdSize: UInt32 = 16
            var header = data
            let newNcmds = ncmds + 1
            let newSizeofcmds = sizeofcmds + newCmdSize
            withUnsafeBytes(of: newNcmds) { header.replaceSubrange(16..<20, with: $0) }
            withUnsafeBytes(of: newSizeofcmds) { header.replaceSubrange(20..<24, with: $0) }

            // 所有段的 fileoff +16
            for seg in segmentOffsets {
                let newFileoff = seg.fileoff + UInt64(newCmdSize)
                withUnsafeBytes(of: newFileoff) { header.replaceSubrange(seg.index+40..<seg.index+48, with: $0) }
            }

            output = header
            let lcOffset = 32 + Int(sizeofcmds)
            var lcData = Data()
            lcData.append(contentsOf: withUnsafeBytes(of: UInt32(0x1D).bigEndian) { Data($0) })
            lcData.append(contentsOf: withUnsafeBytes(of: newCmdSize.bigEndian) { Data($0) })
            lcData.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // dataoff 占位
            lcData.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // datasize 占位
            output.insert(contentsOf: lcData, at: lcOffset)

            codeLimit = output.count
            actualLinkeditOffset = linkeditFileOffset + UInt64(newCmdSize)
            existingCodeSigCmdOffset = lcOffset
        }

        // 第二步：基于 output（签名前的数据）计算页面哈希
        let pageHashes = computePageHashes(data: output, codeLimit: codeLimit)

        // 构建 entitlements blob
        let entitlementsBlob = entitlements.map { makeBlobWrapper(data: $0) }

        // 生成 CodeDirectory
        let codeDirectory = makeCodeDirectory(
            pageHashes: pageHashes,
            codeLimit: codeLimit,
            teamID: teamID,
            bundleID: bundleID,
            entitlementsBlob: entitlementsBlob,
            execSegBase: execSegBase,
            execSegLimit: execSegLimit,
            execSegFlags: execSegFlags
        )

        // 签名 CodeDirectory
        let signature = try signCodeDirectory(codeDirectory, privateKey: privateKey)

        // 组装 SuperBlob
        let superBlob = makeSuperBlob(
            codeDirectory: codeDirectory,
            certificateData: certificateData,
            signature: signature,
            entitlementsBlob: entitlementsBlob
        )

        // 第三步：更新 LC_CODE_SIGNATURE 的 dataoff 和 datasize
        let sigOffset = UInt32(codeLimit)
        let sigSize = UInt32(superBlob.count)
        withUnsafeBytes(of: sigOffset.bigEndian) { output.replaceSubrange(existingCodeSigCmdOffset+8..<existingCodeSigCmdOffset+12, with: $0) }
        withUnsafeBytes(of: sigSize.bigEndian) { output.replaceSubrange(existingCodeSigCmdOffset+12..<existingCodeSigCmdOffset+16, with: $0) }

        // 第四步：更新 __LINKEDIT 段的 filesize
        let newLinkeditSize = UInt64(codeLimit) + UInt64(superBlob.count) - actualLinkeditOffset
        withUnsafeBytes(of: newLinkeditSize.bigEndian) { output.replaceSubrange(linkeditCmdOffset+48..<linkeditCmdOffset+56, with: $0) }

        // 第五步：追加签名数据
        output.append(superBlob)

        return output
    }

    // MARK: - 页面哈希（分块，不爆内存）

    private static func computePageHashes(data: Data, codeLimit: Int) -> [SHA256.Digest] {
        var hashes: [SHA256.Digest] = []
        var offset = 0
        while offset < codeLimit {
            let end = min(offset + pageSize, codeLimit)
            let page = data.subdata(in: offset..<end)
            hashes.append(SHA256.hash(data: page))
            offset = end
        }
        return hashes
    }

    // MARK: - 生成 CodeDirectory（对齐 ldid v0x20400）

    /// CodeDirectory blob 结构：
    /// Blob header (8): magic + length
    /// CodeDirectory struct (80): version flags hashOffset identOffset nSpecialSlots nCodeSlots codeLimit hashSize hashType platform pageSize spare2 scatterOffset teamIDOffset spare3 codeLimit64 execSegBase execSegLimit execSegFlags
    /// identifier + null
    /// teamID + null
    /// special slot hashes (nSpecialSlots * 32)
    /// code slot hashes (nCodeSlots * 32)
    private static func makeCodeDirectory(
        pageHashes: [SHA256.Digest],
        codeLimit: Int,
        teamID: String,
        bundleID: String,
        entitlementsBlob: Data?,
        execSegBase: UInt64,
        execSegLimit: UInt64,
        execSegFlags: UInt64
    ) -> Data {
        let blobHeaderSize = 8  // magic + length
        let cdStructSize = 80   // sizeof(CodeDirectory) in ldid
        let headerSize = blobHeaderSize + cdStructSize  // 88

        let identifier = bundleID.data(using: .utf8)! + Data([0])
        let teamIDData = teamID.data(using: .utf8)! + Data([0])
        let hashSize = 32 // SHA256

        // 偏移计算（对齐 ldid：offset 从 blob 开头算）
        var offset = headerSize
        let identOffset = offset
        offset += identifier.count

        let teamIDOffset = offset
        offset += teamIDData.count

        // 特殊槽位区域（nSpecialSlots 个哈希）
        offset += Int(nSpecialSlots) * hashSize
        let hashOffset = offset

        let codeDirectorySize = offset + pageHashes.count * hashSize
        let codeDirectoryPadded = (codeDirectorySize + 3) / 4 * 4

        var cd = Data(capacity: codeDirectoryPadded)

        // Blob header
        cd.append(contentsOf: withUnsafeBytes(of: csMagicCodeDirectory.bigEndian) { Data($0) })
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(codeDirectorySize).bigEndian) { Data($0) })

        // CodeDirectory struct (80 bytes)
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0x20400).bigEndian) { Data($0) }) // version
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // flags (正式签名)
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(hashOffset).bigEndian) { Data($0) }) // hashOffset
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(identOffset).bigEndian) { Data($0) }) // identOffset
        cd.append(contentsOf: withUnsafeBytes(of: nSpecialSlots.bigEndian) { Data($0) }) // nSpecialSlots
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(pageHashes.count).bigEndian) { Data($0) }) // nCodeSlots

        let codeLimit32 = codeLimit > Int(UInt32.max) ? UInt32.max : UInt32(codeLimit)
        cd.append(contentsOf: withUnsafeBytes(of: codeLimit32.bigEndian) { Data($0) }) // codeLimit

        cd.append(contentsOf: [UInt8(hashSize)]) // hashSize
        cd.append(contentsOf: [2]) // hashType (SHA256)
        cd.append(contentsOf: [0]) // platform
        cd.append(contentsOf: [12]) // pageSize (1<<12 = 4096)
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // spare2
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // scatterOffset
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(teamIDOffset).bigEndian) { Data($0) }) // teamIDOffset
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // spare3

        let codeLimit64 = codeLimit > Int(UInt32.max) ? UInt64(codeLimit) : 0
        cd.append(contentsOf: withUnsafeBytes(of: codeLimit64.bigEndian) { Data($0) }) // codeLimit64
        cd.append(contentsOf: withUnsafeBytes(of: execSegBase.bigEndian) { Data($0) }) // execSegBase
        cd.append(contentsOf: withUnsafeBytes(of: execSegLimit.bigEndian) { Data($0) }) // execSegLimit
        cd.append(contentsOf: withUnsafeBytes(of: execSegFlags.bigEndian) { Data($0) }) // execSegFlags

        // identifier + teamID
        cd.append(identifier)
        cd.append(teamIDData)

        // 特殊槽位哈希（先全填零，再填 entitlements）
        var specialHashes = Data(repeating: 0, count: Int(nSpecialSlots) * hashSize)
        if let entBlob = entitlementsBlob {
            let entHash = SHA256.hash(data: entBlob)
            // entitlements 是 slot -5，对应索引 nSpecialSlots - 5 = 0
            let slotIndex = Int(nSpecialSlots) + entitlementsSlot // 5 + (-5) = 0
            let byteOffset = slotIndex * hashSize
            entHash.withUnsafeBytes { specialHashes.replaceSubrange(byteOffset..<byteOffset+hashSize, with: $0) }
        }
        cd.append(specialHashes)

        // 代码页面哈希
        for hash in pageHashes {
            cd.append(contentsOf: hash)
        }

        while cd.count < codeDirectoryPadded { cd.append(0) }
        return cd
    }

    // MARK: - 签名 CodeDirectory

    private static func signCodeDirectory(_ codeDirectory: Data, privateKey: SecKey) throws -> Data {
        let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any]
        let keyType = attributes?[kSecAttrKeyType as String] as? String
        let isEC = keyType == (kSecAttrKeyTypeEC as String) || keyType == (kSecAttrKeyTypeECSECPrimeRandom as String)

        var error: Unmanaged<CFError>?
        let signature: Data?
        if isEC {
            let hash = Data(SHA256.hash(data: codeDirectory))
            signature = SecKeyCreateSignature(
                privateKey,
                .ecdsaSignatureDigestX962SHA256,
                hash as CFData,
                &error
            ) as Data?
        } else {
            let hash = Data(Insecure.SHA1.hash(data: codeDirectory))
            signature = SecKeyCreateSignature(
                privateKey,
                .rsaSignatureDigestPKCS1v15SHA1,
                hash as CFData,
                &error
            ) as Data?
        }

        guard let sig = signature else {
            let err = error?.takeRetainedValue()
            throw NSError(domain: "MachOFullSigner", code: 4, userInfo: [NSLocalizedDescriptionKey: "签名失败: \(err?.localizedDescription ?? "未知错误")"])
        }
        return sig
    }

    // MARK: - 组装 SuperBlob（对齐 ldid）

    /// SuperBlob 结构：
    /// header (12): magic + length + count
    /// index (count * 8): type + offset
    /// slots: CodeDirectory, CertificateChain, Entitlements(可选), Signature
    private static func makeSuperBlob(
        codeDirectory: Data,
        certificateData: Data,
        signature: Data,
        entitlementsBlob: Data?
    ) -> Data {
        let certBlob = makeBlobWrapper(data: certificateData)
        let sigBlob = makeBlobWrapper(data: signature)

        var slots: [(type: UInt32, data: Data)] = [
            (slotCodeDirectory, codeDirectory),
            (slotCertificateChain, certBlob),
        ]
        if let ent = entitlementsBlob {
            slots.append((slotEntitlements, ent))
        }
        slots.append((slotSignature, sigBlob))

        let headerSize = 12 // magic + length + count
        let indexSize = slots.count * 8
        var currentOffset = headerSize + indexSize
        var indexData = Data()
        var blobData = Data()
        for slot in slots {
            indexData.append(contentsOf: withUnsafeBytes(of: slot.type.bigEndian) { Data($0) })
            indexData.append(contentsOf: withUnsafeBytes(of: UInt32(currentOffset).bigEndian) { Data($0) })
            blobData.append(slot.data)
            currentOffset += slot.data.count
        }
        let totalSize = currentOffset

        var blob = Data(capacity: totalSize)
        blob.append(contentsOf: withUnsafeBytes(of: csMagicEmbeddedSignature.bigEndian) { Data($0) })
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(totalSize).bigEndian) { Data($0) })
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(slots.count).bigEndian) { Data($0) })
        blob.append(indexData)
        blob.append(blobData)
        return blob
    }

    private static func makeBlobWrapper(data: Data) -> Data {
        let total = 8 + data.count
        let padded = (total + 3) / 4 * 4
        var blob = Data(capacity: padded)
        blob.append(contentsOf: withUnsafeBytes(of: csMagicBlobWrapper.bigEndian) { Data($0) })
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(total).bigEndian) { Data($0) })
        blob.append(data)
        while blob.count < padded { blob.append(0) }
        return blob
    }
}

import Foundation
import CryptoKit

/// 纯 Swift 实现的完整代码签名，不依赖 ldid
/// 大文件分块处理，不一次性加载，解决 ldid.cpp(538) 内存不足崩溃
enum MachOFullSigner {
    private static let pageSize = 4096
    private static let csMagicCodeDirectory: UInt32 = 0xFADE0C02
    private static let csMagicEmbeddedSignature: UInt32 = 0xFADE0CC1
    private static let csMagicBlobWrapper: UInt32 = 0xFADE0B01
    private static let kSecCodeSignatureAdhoc: UInt32 = 0x2

    /// 给 IPA 中所有 Mach-O 二进制加完整证书签名
    static func signAllBinaries(
        in appURL: URL,
        certificateP12: Data,
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
            // MH_MAGIC_64 (0xFEEDFACF) 或 FAT (0xCAFEBABE / 0xBEBAFECA)
            if magic == 0xFEEDFACF || magic == 0xCAFEBABE || magic == 0xBEBAFECA {
                machOFiles.append(url)
            }
        }

        for url in machOFiles {
            try signMachO(at: url, certificateP12: certificateP12, teamID: teamID, bundleID: bundleID, entitlements: entitlements)
        }
    }

    private static func signMachO(
        at url: URL,
        certificateP12: Data,
        teamID: String,
        bundleID: String,
        entitlements: Data?
    ) throws {
        let data = try Data(contentsOf: url)
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            try signFAT(data: data, url: url, certificateP12: certificateP12, teamID: teamID, bundleID: bundleID, entitlements: entitlements)
        } else {
            let signed = try signThin(data: data, certificateP12: certificateP12, teamID: teamID, bundleID: bundleID, entitlements: entitlements)
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
        certificateP12: Data,
        teamID: String,
        bundleID: String,
        entitlements: Data?
    ) throws {
        let isBigEndian = data.withUnsafeBytes { $0.load(as: UInt32.self) } == 0xCAFEBABE
        let nfatArch = data.withUnsafeBytes {
            $0.load(fromByteOffset: 4, as: UInt32.self)
        }
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
            let signed = try signThin(data: archData, certificateP12: certificateP12, teamID: teamID, bundleID: bundleID, entitlements: entitlements)
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
        certificateP12: Data,
        teamID: String,
        bundleID: String,
        entitlements: Data?
    ) throws -> Data {
        // 解析 load commands，找到 __LINKEDIT 和 LC_CODE_SIGNATURE
        let ncmds = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        let sizeofcmds = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }

        var linkeditFileOffset: UInt64 = 0
        var linkeditFileSize: UInt64 = 0
        var existingCodeSigOffset: UInt32 = 0
        var existingCodeSigSize: UInt32 = 0
        var hasCodeSignature = false
        var segmentOffsets: [(fileoff: UInt64, index: Int)] = []

        var cmdOffset = 32
        for _ in 0..<ncmds {
            let cmd = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset, as: UInt32.self) }
            let cmdsize = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 4, as: UInt32.self) }

            if cmd == 0x19 { // LC_SEGMENT_64
                let segname = String(data: data.subdata(in: cmdOffset+8..<cmdOffset+24), encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? ""
                let fileoff = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 40, as: UInt64.self) }
                let filesize = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 48, as: UInt64.self) }
                if segname == "__LINKEDIT" {
                    linkeditFileOffset = fileoff
                    linkeditFileSize = filesize
                }
                segmentOffsets.append((fileoff: fileoff, index: cmdOffset))
            }

            if cmd == 0x1D { // LC_CODE_SIGNATURE
                existingCodeSigOffset = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 8, as: UInt32.self) }
                existingCodeSigSize = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 12, as: UInt32.self) }
                hasCodeSignature = true
            }

            cmdOffset += Int(cmdsize)
        }

        let codeLimit = linkeditFileOffset > 0 ? Int(linkeditFileOffset) : data.count

        // 分块计算页面哈希
        let pageHashes = computePageHashes(data: data, codeLimit: codeLimit)

        // 从 P12 提取证书和私钥
        let (certificateData, privateKey) = try extractCertificateAndKey(from: certificateP12)

        // 生成 CodeDirectory
        let codeDirectory = try makeCodeDirectory(
            pageHashes: pageHashes,
            codeLimit: codeLimit,
            teamID: teamID,
            bundleID: bundleID,
            certificateData: certificateData,
            data: data
        )

        // 签名 CodeDirectory
        let signature = try signCodeDirectory(codeDirectory, privateKey: privateKey)

        // 组装 SuperBlob
        let superBlob = makeSuperBlob(
            codeDirectory: codeDirectory,
            certificateData: certificateData,
            signature: signature,
            entitlements: entitlements
        )

        // 写入 Mach-O
        var output = data
        if hasCodeSignature {
            // 修改现有 LC_CODE_SIGNATURE 指向新签名
            cmdOffset = 32
            for _ in 0..<ncmds {
                let cmd = output.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset, as: UInt32.self) }
                let cmdsize = output.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 4, as: UInt32.self) }
                if cmd == 0x1D {
                    let newOffset = UInt32(output.count)
                    let newSize = UInt32(superBlob.count)
                    withUnsafeBytes(of: newOffset.bigEndian) { output.replaceSubrange(cmdOffset+8..<cmdOffset+12, with: $0) }
                    withUnsafeBytes(of: newSize.bigEndian) { output.replaceSubrange(cmdOffset+12..<cmdOffset+16, with: $0) }
                    break
                }
                cmdOffset += Int(cmdsize)
            }
            output.append(superBlob)
        } else {
            // 新增 LC_CODE_SIGNATURE load command
            let newCmdSize: UInt32 = 16
            var header = output
            // 修改 mach_header ncmds 和 sizeofcmds
            let newNcmds = ncmds + 1
            let newSizeofcmds = sizeofcmds + newCmdSize
            withUnsafeBytes(of: newNcmds) { header.replaceSubrange(16..<20, with: $0) }
            withUnsafeBytes(of: newSizeofcmds) { header.replaceSubrange(20..<24, with: $0) }

            // 所有段的 fileoff 增加 16（因为插入了新 load command）
            for seg in segmentOffsets {
                let newFileoff = seg.fileoff + UInt64(newCmdSize)
                withUnsafeBytes(of: newFileoff) { header.replaceSubrange(seg.index+40..<seg.index+48, with: $0) }
            }

            output = header
            // 在 load commands 末尾插入新 LC_CODE_SIGNATURE
            let lcOffset = 32 + Int(sizeofcmds)
            var lcData = Data()
            lcData.append(contentsOf: withUnsafeBytes(of: UInt32(0x1D).bigEndian) { Data($0) }) // LC_CODE_SIGNATURE
            lcData.append(contentsOf: withUnsafeBytes(of: newCmdSize.bigEndian) { Data($0) })
            lcData.append(contentsOf: withUnsafeBytes(of: UInt32(output.count).bigEndian) { Data($0) }) // dataoff
            lcData.append(contentsOf: withUnsafeBytes(of: UInt32(superBlob.count).bigEndian) { Data($0) }) // datasize
            output.insert(contentsOf: lcData, at: lcOffset)
            output.append(superBlob)
        }

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

    // MARK: - 从 P12 提取证书和私钥

    private static func extractCertificateAndKey(from p12Data: Data) throws -> (Data, SecKey) {
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, [kSecImportExportPassphrase: "" as CFString] as CFDictionary, &items)
        guard status == errSecSuccess,
              let items = items as? [[String: Any]],
              let first = items.first,
              let identity = first[kSecImportItemIdentity as String] as! SecIdentity? else {
            throw NSError(domain: "MachOFullSigner", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法从 P12 提取证书和私钥"])
        }

        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let cert = certificate else {
            throw NSError(domain: "MachOFullSigner", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法提取证书"])
        }

        var privateKey: SecKey?
        SecIdentityCopyPrivateKey(identity, &privateKey)
        guard let key = privateKey else {
            throw NSError(domain: "MachOFullSigner", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法提取私钥"])
        }

        let certData = SecCertificateCopyData(cert) as Data
        return (certData, key)
    }

    // MARK: - 生成 CodeDirectory

    private static func makeCodeDirectory(
        pageHashes: [SHA256.Digest],
        codeLimit: Int,
        teamID: String,
        bundleID: String,
        certificateData: Data,
        data: Data
    ) throws -> Data {
        let headerSize = 108
        let identifier = bundleID.data(using: .utf8)! + Data([0])
        let teamIDData = teamID.data(using: .utf8)! + Data([0])
        let hashOffset = headerSize + identifier.count + teamIDData.count
        let codeDirectorySize = headerSize + identifier.count + teamIDData.count + pageHashes.count * 32
        let codeDirectoryPadded = (codeDirectorySize + 3) / 4 * 4

        // 查找可执行段 (__TEXT)
        var execSegBase: UInt64 = 0
        var execSegLimit: UInt64 = 0
        var execSegFlags: UInt64 = 0
        let ncmds = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        var cmdOffset = 32
        for _ in 0..<ncmds {
            let cmd = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset, as: UInt32.self) }
            let cmdsize = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 4, as: UInt32.self) }
            if cmd == 0x19 {
                let segname = String(data: data.subdata(in: cmdOffset+8..<cmdOffset+24), encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? ""
                if segname == "__TEXT" {
                    execSegBase = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 24, as: UInt64.self) } // vmaddr
                    execSegLimit = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 32, as: UInt64.self) } // vmsize
                    let segFlags = data.withUnsafeBytes { $0.load(fromByteOffset: cmdOffset + 56, as: UInt32.self) }
                    execSegFlags = (segFlags & 0x1) != 0 ? 1 : 0 // SG_HIGHVM 位
                }
            }
            cmdOffset += Int(cmdsize)
        }

        var cd = Data(capacity: codeDirectoryPadded)
        cd.append(contentsOf: withUnsafeBytes(of: csMagicCodeDirectory.bigEndian) { Data($0) })
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(codeDirectorySize).bigEndian) { Data($0) })
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0x20100).bigEndian) { Data($0) }) // version
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // flags (正式签名，非 ad-hoc)
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(hashOffset).bigEndian) { Data($0) }) // hashOffset
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(headerSize).bigEndian) { Data($0) }) // identOffset
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(pageHashes.count).bigEndian) { Data($0) }) // nCodeSlots
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(codeLimit).bigEndian) { Data($0) }) // codeLimit
        cd.append(contentsOf: [32]) // hashSize
        cd.append(contentsOf: [2])  // hashType (SHA256)
        cd.append(contentsOf: [0])  // platform
        cd.append(contentsOf: [12]) // pageSize (1<<12 = 4096)
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // spare2
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // scatterOffset
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(headerSize + identifier.count).bigEndian) { Data($0) }) // teamOffset
        cd.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }) // spare3
        cd.append(contentsOf: withUnsafeBytes(of: UInt64(codeLimit).bigEndian) { Data($0) }) // codeLimit64
        cd.append(contentsOf: withUnsafeBytes(of: execSegBase.bigEndian) { Data($0) }) // execSegBase
        cd.append(contentsOf: withUnsafeBytes(of: execSegLimit.bigEndian) { Data($0) }) // execSegLimit
        cd.append(contentsOf: withUnsafeBytes(of: execSegFlags.bigEndian) { Data($0) }) // execSegFlags
        cd.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // runtime
        cd.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // preEncryptOffset
        cd.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) }) // jitConstraintOffset
        cd.append(identifier)
        cd.append(teamIDData)
        for hash in pageHashes {
            cd.append(contentsOf: hash)
        }
        while cd.count < codeDirectoryPadded { cd.append(0) }
        return cd
    }

    // MARK: - 签名 CodeDirectory

    private static func signCodeDirectory(_ codeDirectory: Data, privateKey: SecKey) throws -> Data {
        // 自动检测私钥类型：RSA 用 PKCS1v15+SHA1，ECDSA 用 X962+SHA256
        let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any]
        let keyType = attributes?[kSecAttrKeyType as String] as? String
        let isEC = keyType == (kSecAttrKeyTypeEC as String) || keyType == (kSecAttrKeyTypeECSECPrimeRandom as String)

        var error: Unmanaged<CFError>?
        let signature: Data?
        if isEC {
            let hash = SHA256.hash(data: codeDirectory)
            signature = SecKeyCreateSignature(
                privateKey,
                .ecdsaSignatureDigestX962SHA256,
                hash as CFData,
                &error
            ) as Data?
        } else {
            let hash = Insecure.SHA1.hash(data: codeDirectory)
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

    // MARK: - 组装 SuperBlob

    private static func makeSuperBlob(
        codeDirectory: Data,
        certificateData: Data,
        signature: Data,
        entitlements: Data?
    ) -> Data {
        let codeDirPadded = codeDirectory.count
        let certBlob = makeBlobWrapper(data: certificateData)
        let certPadded = certBlob.count
        let sigBlob = makeBlobWrapper(data: signature)
        let sigPadded = sigBlob.count

        var slots: [(type: UInt32, data: Data)] = [
            (0x00000000, codeDirectory),  // CodeDirectory
            (0x00000002, certBlob),        // 证书链
            (0x00001000, sigBlob),         // 签名
        ]
        if let entitlements {
            let entBlob = makeBlobWrapper(data: entitlements)
            slots.append((0x00000005, entBlob)) // entitlements
        }

        let headerSize = 12
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

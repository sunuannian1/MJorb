import Foundation
import UIKit
import ZIPFoundation

struct SigningWorkspace: Sendable {
    let limits: ArchiveLimits
    let bundleIDMapper: BundleIDMapper

    init(
        limits: ArchiveLimits = ArchiveLimits(),
        bundleIDMapper: BundleIDMapper = BundleIDMapper()
    ) {
        self.limits = limits
        self.bundleIDMapper = bundleIDMapper
    }

    func prepare(
        ipaURL: URL,
        workspaceRoot: URL,
        originalBundleID: String,
        teamID: String,
        targetMainBundleID: String? = nil,
        preferredDisplayName: String? = nil,
        preferredIconData: Data? = nil
    ) throws -> PreparedSigningWorkspace {
        // 大 IPA 优化：用系统 unzipItem 流式解压（ZIPFoundation extract 对 500MB+ 文件
        // 可能因内存/写入失败报 DataError）。仍用 ZIPFoundation Archive 只读条目元数据做安全验证。
        let archive = try Archive(url: ipaURL, accessMode: .read)
        let entries = Array(archive)
        try validate(entries)

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: workspaceRoot)
        try fileManager.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        do {
            // 系统 API 流式解压，不加载大文件到内存
            try fileManager.unzipItem(at: ipaURL, to: workspaceRoot)
            try Task.checkCancellation()

            let payloadURL = workspaceRoot.appending(
                path: "Payload",
                directoryHint: .isDirectory
            )
            let appURLs = try fileManager.contentsOfDirectory(
                at: payloadURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "app" }
            guard appURLs.count == 1, let appURL = appURLs.first else {
                throw Self.signingFailure(
                    reason: "未找到主应用",
                    code: "SEAL-SIGN-401"
                )
            }

            let mappedMain = bundleIDMapper.mainBundleID(
                original: originalBundleID,
                teamID: teamID,
                requested: targetMainBundleID
            )
            var mappings = [originalBundleID: mappedMain]
            try updateBundleIdentifier(at: appURL, to: mappedMain)
            // 参照 SideStore 官方逻辑：替换 URL Schemes，避免同 Bundle ID 不同后缀的 App 冲突
            // 不修改被签名 App 的 URL Scheme，避免破坏依赖自定义 scheme 的 App（如 LiveContainer）
            if let preferredDisplayName = normalizedDisplayName(preferredDisplayName) {
                try updateDisplayName(at: appURL, to: preferredDisplayName)
            }
            if let preferredIconData {
                try replacePrimaryAppIcon(at: appURL, imageData: preferredIconData)
            }

            // 自动移除免费账号不支持的内容：Watch App、App Clip
            // 参照 SideStore/AltStore 官方逻辑，这些内容免费账号无法签名
            try removeUnsupportedBundles(in: appURL)

            // 大 IPA 优化：剥离 arm64e 架构，只保留 arm6
            // iOS 设备全是 arm64，arm64e 无用且会导致 ldid 处理大文件时内存不足崩溃
            // 剥离后由 MachOAdHocSigner 重新加 ad-hoc 签名，ALTSigner 再覆盖签名
            try stripArm64eArchitecture(in: appURL)

            let extensionURLs = try appExtensionURLs(in: appURL)
            for extensionURL in extensionURLs {
                try Task.checkCancellation()
                let original = try bundleIdentifier(at: extensionURL)
                let mapped = bundleIDMapper.extensionBundleID(
                    original: original,
                    originalMainBundleID: originalBundleID,
                    mappedMainBundleID: mappedMain
                )
                try updateBundleIdentifier(at: extensionURL, to: mapped)
                mappings[original] = mapped
            }
            // 移除旧的 _CodeSignature 目录（不修改 Mach-O 里的 LC_CODE_SIGNATURE）
            try removeOldSignatures(in: appURL)

            // 给所有 Mach-O 加 ad-hoc 签名，避免 ALTSigner/ldid 处理未签名二进制时崩溃
            // 参考 Fladder issue #800：未签名或签名无效的 Mach-O 会导致 ldid 断言失败
            try MachOAdHocSigner.signAllBinaries(in: appURL)

            return PreparedSigningWorkspace(
                rootURL: workspaceRoot,
                payloadURL: payloadURL,
                appURL: appURL,
                mappedMainBundleID: mappedMain,
                bundleIDMappings: mappings
            )
        } catch {
            try? fileManager.removeItem(at: workspaceRoot)
            throw error
        }
    }

    func package(
        _ workspace: PreparedSigningWorkspace,
        outputURL: URL
    ) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)
        // 大 IPA 用不压缩存储：二进制已被编译器压缩，再 deflate 收益<5%但耗时占30%+
        // 不压缩还能让 iOS 安装时更快（无需解压）
        try fileManager.zipItem(
            at: workspace.payloadURL,
            to: outputURL,
            shouldKeepParent: true,
            compressionMethod: .none
        )
    }

    func clean(_ workspace: PreparedSigningWorkspace) {
        try? FileManager.default.removeItem(at: workspace.rootURL)
    }


    func signedBundleTargets(in workspace: PreparedSigningWorkspace) throws -> [SignedBundleTarget] {
        var targets = [
            SignedBundleTarget(
                bundleURL: workspace.appURL,
                bundleIdentifier: try bundleIdentifier(at: workspace.appURL),
                isMainApplication: true
            )
        ]
        for extensionURL in try appExtensionURLs(in: workspace.appURL) {
            targets.append(
                SignedBundleTarget(
                    bundleURL: extensionURL,
                    bundleIdentifier: try bundleIdentifier(at: extensionURL),
                    isMainApplication: false
                )
            )
        }
        return targets
    }

    func removeExtension(
        mappedBundleIdentifier: String,
        from workspace: PreparedSigningWorkspace
    ) throws {
        for extensionURL in try appExtensionURLs(in: workspace.appURL) {
            if try bundleIdentifier(at: extensionURL) == mappedBundleIdentifier {
                try FileManager.default.removeItem(at: extensionURL)
                return
            }
        }
    }

    private func validate(_ entries: [Entry]) throws {
        guard entries.count <= limits.maximumEntryCount else {
            throw Self.signingFailure(
                reason: "解压内容超过安全上限",
                code: "SEAL-SIGN-402"
            )
        }
        var expandedSize: UInt64 = 0
        for entry in entries {
            guard ArchivePathValidator.isSafe(entry.path), entry.type != .symlink else {
                throw Self.signingFailure(
                    reason: "IPA 包含不安全路径",
                    code: "SEAL-SIGN-403"
                )
            }
            let (sum, overflow) = expandedSize.addingReportingOverflow(entry.uncompressedSize)
            guard overflow == false, sum <= limits.maximumExpandedSize else {
                throw Self.signingFailure(
                    reason: "解压内容超过安全上限",
                    code: "SEAL-SIGN-402a"
                )
            }
            expandedSize = sum
        }
    }

    private func appExtensionURLs(in appURL: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var values: [URL] = []
        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: Set(keys))
            if resourceValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard resourceValues.isDirectory == true else { continue }
            if url.pathExtension.lowercased() == "appex" {
                values.append(url)
                enumerator.skipDescendants()
            }
        }
        return values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func bundleIdentifier(at bundleURL: URL) throws -> String {
        let infoURL = bundleURL.appending(path: "Info.plist")
        let data = try Data(contentsOf: infoURL)
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let info = value as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier.isEmpty == false else {
            throw Self.signingFailure(
                reason: "应用标识无效",
                code: "SEAL-SIGN-404b"
            )
        }
        return identifier
    }

    private func updateBundleIdentifier(
        at bundleURL: URL,
        to identifier: String
    ) throws {
        let infoURL = bundleURL.appending(path: "Info.plist")
        let data = try Data(contentsOf: infoURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        )
        guard var info = value as? [String: Any] else {
            throw Self.signingFailure(
                reason: "应用信息无效",
                code: "SEAL-SIGN-404c"
            )
        }
        info["CFBundleIdentifier"] = identifier
        info.removeValue(forKey: "DTXcode")
        info.removeValue(forKey: "DTXcodeBuild")
        let updated = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: format,
            options: 0
        )
        try updated.write(to: infoURL, options: .atomic)
    }

    private func normalizedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func updateDisplayName(at appURL: URL, to displayName: String) throws {
        try mutateInfoPlist(at: appURL.appending(path: "Info.plist")) { info in
            info["CFBundleDisplayName"] = displayName
            info["CFBundleName"] = displayName
        }

        let localizationURLs = (try? FileManager.default.contentsOfDirectory(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for localizationURL in localizationURLs where localizationURL.pathExtension == "lproj" {
            let stringsURL = localizationURL.appending(path: "InfoPlist.strings")
            guard FileManager.default.fileExists(atPath: stringsURL.path) else { continue }
            do {
                let data = try Data(contentsOf: stringsURL)
                var format = PropertyListSerialization.PropertyListFormat.openStep
                let value = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [.mutableContainersAndLeaves],
                    format: &format
                )
                guard var strings = value as? [String: Any] else { continue }
                strings["CFBundleDisplayName"] = displayName
                strings["CFBundleName"] = displayName
                let updated = try PropertyListSerialization.data(
                    fromPropertyList: strings,
                    format: format,
                    options: 0
                )
                try updated.write(to: stringsURL, options: .atomic)
            } catch {
                // A malformed optional localization must not corrupt the IPA.
                continue
            }
        }
    }

    private func replacePrimaryAppIcon(at appURL: URL, imageData: Data) throws {
        guard let image = UIImage(data: imageData), image.size.width > 0, image.size.height > 0 else {
            throw Self.signingFailure(reason: "自定义 App 图标无法读取", code: "SEAL-CUSTOM-004")
        }

        let variants: [(name: String, pixels: CGFloat)] = [
            ("SealCustomIcon60@2x.png", 120),
            ("SealCustomIcon60@3x.png", 180),
            ("SealCustomIcon76@2x.png", 152),
            ("SealCustomIcon83.5@2x.png", 167)
        ]
        for variant in variants {
            let rendered = try renderedSquareIcon(image, pixels: variant.pixels)
            try rendered.write(to: appURL.appending(path: variant.name), options: .atomic)
        }

        try mutateInfoPlist(at: appURL.appending(path: "Info.plist")) { info in
            var phoneIcons = (info["CFBundleIcons"] as? [String: Any]) ?? [:]
            var phonePrimary = (phoneIcons["CFBundlePrimaryIcon"] as? [String: Any]) ?? [:]
            phonePrimary["CFBundleIconFiles"] = ["SealCustomIcon60"]
            phonePrimary.removeValue(forKey: "CFBundleIconName")
            phoneIcons["CFBundlePrimaryIcon"] = phonePrimary
            info["CFBundleIcons"] = phoneIcons

            var padIcons = (info["CFBundleIcons~ipad"] as? [String: Any]) ?? [:]
            var padPrimary = (padIcons["CFBundlePrimaryIcon"] as? [String: Any]) ?? [:]
            padPrimary["CFBundleIconFiles"] = ["SealCustomIcon76", "SealCustomIcon83.5"]
            padPrimary.removeValue(forKey: "CFBundleIconName")
            padIcons["CFBundlePrimaryIcon"] = padPrimary
            info["CFBundleIcons~ipad"] = padIcons
            info["CFBundleIconFiles"] = ["SealCustomIcon60", "SealCustomIcon76"]
            info.removeValue(forKey: "CFBundleIconName")
        }
    }

    private func renderedSquareIcon(_ image: UIImage, pixels: CGFloat) throws -> Data {
        guard let source = image.cgImage else {
            throw Self.signingFailure(reason: "自定义 App 图标无法处理", code: "SEAL-CUSTOM-004a")
        }
        let side = min(source.width, source.height)
        let sourceRect = CGRect(
            x: (source.width - side) / 2,
            y: (source.height - side) / 2,
            width: side,
            height: side
        )
        guard let cgImage = source.cropping(to: sourceRect) else {
            throw Self.signingFailure(reason: "自定义 App 图标无法处理", code: "SEAL-CUSTOM-004b")
        }
        let cropped = UIImage(cgImage: cgImage, scale: 1, orientation: image.imageOrientation)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format)
        let output = renderer.image { _ in
            cropped.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        guard let png = output.pngData() else {
            throw Self.signingFailure(reason: "自定义 App 图标无法编码", code: "SEAL-CUSTOM-004c")
        }
        return png
    }

    private func mutateInfoPlist(
        at infoURL: URL,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let data = try Data(contentsOf: infoURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        )
        guard var info = value as? [String: Any] else {
            throw Self.signingFailure(reason: "应用信息无效", code: "SEAL-SIGN-404d")
        }
        mutation(&info)
        let updated = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: format,
            options: 0
        )
        try updated.write(to: infoURL, options: .atomic)
    }

    /// 替换 URL Schemes，避免同 Bundle ID 不同后缀的 App 冲突
    /// 参照 SideStore 官方逻辑
    private func updateURLSchemes(in appURL: URL, originalBundleID: String, newBundleID: String) throws {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        try mutateInfoPlist(at: infoURL) { info in
            // 原始没有 CFBundleURLTypes 或格式不符时，不修改，保留原始状态
            guard var urlTypes = info["CFBundleURLTypes"] as? [[String: Any]], !urlTypes.isEmpty else {
                return
            }
            let newScheme = newBundleID.replacingOccurrences(of: ".", with: "-")
            // 已有相同 scheme 则不重复添加
            let alreadyExists = urlTypes.contains { urlType in
                (urlType["CFBundleURLSchemes"] as? [String])?.contains(newScheme) ?? false
            }
            guard !alreadyExists else { return }
            // 新 scheme 追加到末尾，确保原始第一个 scheme（如 livecontainer）保持在第一位
            urlTypes.append([
                "CFBundleTypeRole": "Editor",
                "CFBundleURLName": newBundleID,
                "CFBundleURLSchemes": [newScheme]
            ])
            info["CFBundleURLTypes"] = urlTypes
        }
    }

    /// 自动移除免费账号不支持的内容：Watch App、App Clip
    /// 参照 SideStore/AltStore 官方逻辑
    private func removeUnsupportedBundles(in appURL: URL) throws {
        let fileManager = FileManager.default

        // 移除 Watch App（免费账号不支持 Watch 签名）
        let watchURL = appURL.appendingPathComponent("Watch")
        if fileManager.fileExists(atPath: watchURL.path) {
            try fileManager.removeItem(at: watchURL)
        }

        // 移除 App Clip（免费账号不支持 App Clip）
        let appClipsURL = appURL.appendingPathComponent("AppClips")
        if fileManager.fileExists(atPath: appClipsURL.path) {
            try fileManager.removeItem(at: appClipsURL)
        }

        // 移除 PlugIns 中的 App Clip 和 WatchKit 扩展（arm64_32 32-bit，rork-sign 不支持）
        if let plugInsURL = appURL.appendingPathComponent("PlugIns") as URL?,
           fileManager.fileExists(atPath: plugInsURL.path) {
            let appexContents = try fileManager.contentsOfDirectory(
                at: plugInsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for appexURL in appexContents where appexURL.pathExtension == "appex" {
                let infoURL = appexURL.appendingPathComponent("Info.plist")
                if let infoData = try? Data(contentsOf: infoURL),
                   let info = try? PropertyListSerialization.propertyList(
                       from: infoData,
                       options: [],
                       format: nil
                   ) as? [String: Any],
                   let extensionPoint = info["NSExtensionPointIdentifier"] as? String,
                   extensionPoint == "com.apple.app-clip" || extensionPoint == "com.apple.watchkit" {
                    try fileManager.removeItem(at: appexURL)
                }
            }
        }
    }

    private func removeOldSignatures(in appURL: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        var signatureDirectories: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent == "_CodeSignature" {
            signatureDirectories.append(url)
            enumerator.skipDescendants()
        }
        for directory in signatureDirectories {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// 大 IPA 优化：剥离 arm64e 架构，只保留 arm64
    /// iOS 设备全是 arm64，arm64e 无用且会导致 ldid 处理大文件时内存不足
    private func stripArm64eArchitecture(in appURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            // 只处理大于 1MB 的文件，小文件不需要剥离
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 1_000_000 else { continue }

            // 读取文件头，判断是否是 FAT 二进制（magic=0xCAFEBABE）
            let handle = try? FileHandle(forReadingFrom: url)
            defer { try? handle?.close() }
            guard let headerData = try? handle?.read(upToCount: 8),
                  headerData.count >= 8 else { continue }

            let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard magic == 0xCAFEBABE || magic == 0xBEBAFECA else { continue }

            // 读取 FAT 头和架构列表
            let nfatArch = headerData.withUnsafeBytes {
                $0.load(fromByteOffset: 4, as: UInt32.self)
            }.bigEndian
            guard nfatArch > 1 else { continue }

            let archTableSize = Int(nfatArch) * 20
            guard let archData = try? handle?.read(upToCount: archTableSize),
                  archData.count >= archTableSize else { continue }

            // 遍历架构列表，找 arm64（cputype=0x0100000C, cpusubtype=0）
            var arm64Offset: UInt32 = 0
            var arm64Size: UInt32 = 0
            var found = false

            for i in 0..<Int(nfatArch) {
                let archOffset = i * 20
                let cputype = archData.withUnsafeBytes {
                    $0.load(fromByteOffset: archOffset, as: UInt32.self)
                }.bigEndian
                let cpusubtype = archData.withUnsafeBytes {
                    $0.load(fromByteOffset: archOffset + 4, as: UInt32.self)
                }.bigEndian
                let offset = archData.withUnsafeBytes {
                    $0.load(fromByteOffset: archOffset + 8, as: UInt32.self)
                }.bigEndian
                let size = archData.withUnsafeBytes {
                    $0.load(fromByteOffset: archOffset + 12, as: UInt32.self)
                }.bigEndian

                if cputype == 0x0100000C && cpusubtype != 2 {
                    arm64Offset = offset
                    arm64Size = size
                    found = true
                    break
                }
            }

            guard found, arm64Size > 0 else { continue }

            // 分块流式写入，避免一次性加载大文件到内存导致崩溃
            let tempURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).arm64tmp")
            try? fileManager.removeItem(at: tempURL)
            guard fileManager.createFile(atPath: tempURL.path, contents: nil) else { continue }

            let writeHandle = try? FileHandle(forWritingTo: tempURL)
            defer { try? writeHandle?.close() }

            try? handle?.seek(toOffset: UInt64(arm64Offset))
            var remaining = Int(arm64Size)
            let chunkSize = 10 * 1024 * 1024 // 10MB
            var success = true

            while remaining > 0 {
                let readSize = min(chunkSize, remaining)
                guard let chunk = try? handle?.read(upToCount: readSize),
                      chunk.count > 0 else {
                    success = false
                    break
                }
                try? writeHandle?.write(contentsOf: chunk)
                remaining -= chunk.count
            }

            guard success, remaining == 0 else {
                try? fileManager.removeItem(at: tempURL)
                continue
            }

            try? writeHandle?.close()
            // 用临时文件替换原文件
            do {
                try fileManager.removeItem(at: url)
                try fileManager.moveItem(at: tempURL, to: url)
            } catch {
                try? fileManager.removeItem(at: tempURL)
            }
        }
    }

    private static func signingFailure(
        reason: String,
        code: String
    ) -> ImportFailure {
        ImportFailure(
            title: "无法签名",
            reason: reason,
            recovery: "检查 IPA",
            code: code
        )
    }
}

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
            // 对齐 SideStore 官方：添加新 Bundle ID 对应的 URL Scheme（保留原始 scheme 不变）
            try updateURLSchemes(in: appURL, originalBundleID: originalBundleID, newBundleID: mappedMain)
            // 对齐 SideStore：添加已安装应用 UTI
            try addInstalledAppUTI(in: appURL, bundleID: mappedMain)
            if let preferredDisplayName = normalizedDisplayName(preferredDisplayName) {
                try updateDisplayName(at: appURL, to: preferredDisplayName)
            }
            if let preferredIconData {
                try replacePrimaryAppIcon(at: appURL, imageData: preferredIconData)
            }

            // 自动移除免费账号不支持的内容：Watch App、App Clip
            // 参照 SideStore/AltStore 官方逻辑，这些内容免费账号无法签名
            try removeUnsupportedBundles(in: appURL)
            // 对齐 SideStore：清理 SC_Info/Manifest.plist 中指向已删除扩展的引用
            try removeMissingAppExtensionReferences(in: appURL)

            // 清理 ESign 等其它签名工具留下的注入脚本/标记残留（容错，不阻断签名）。
            removeThirdPartyInjectionArtifacts(in: appURL)

            // 大 IPA 优化：剥离 arm64e 架构，只保留 arm64（iOS 设备均为 arm64）。
            // 按 offset/size 字节级切出 arm64 slice，副本内部签名偏移依然有效，
            // 后续统一由 RorkSigner 重签。
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
            // 移除旧的 _CodeSignature 目录（不修改 Mach-O 里的 LC_CODE_SIGNATURE）。
            // Mach-O 的旧签名/未签名状态统一交给 RorkSigner 处理：有 LC_CODE_SIGNATURE
            // 时按旧 dataoff 干净截断重签，无签名时用 load-command 空闲区插入新签名。
            // 对齐官方 SideStore/zsign：这里不做任何 ad-hoc 预处理——预处理反而会残留旧
            // 签名 blob、抹掉原始 entitlements、漏平移 chained-fixups 数据偏移，导致闪退。
            try removeOldSignatures(in: appURL)

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
        // 必须显式 deflate 压缩：ZIPFoundation 的 zipItem 默认 compressionMethod 是
        // .none（store 不压缩），iOS installd / CoreDevice 对 store-mode ZIP 兼容性差，
        // 大文件/非标准结构 IPA 会在定位/解压阶段失败并误报 MissingPackagePath。
        // 真机可用的 jas 以及爱思/AltStore/SideStore 标准 IPA 全部用 deflate 压缩。
        try fileManager.zipItem(
            at: workspace.payloadURL,
            to: outputURL,
            shouldKeepParent: true,
            compressionMethod: .deflate
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
        let originalIdentifier = info["CFBundleIdentifier"] as? String
        info["CFBundleIdentifier"] = identifier
        // 对齐 SideStore/AltStore：保留原始 Bundle ID 供运行时识别
        if let originalIdentifier, originalIdentifier.isEmpty == false {
            info["ALTBundleID"] = originalIdentifier
        }
        // 对齐 AltStore：占位符，实际配对字符串由运行时注入
        info["ALTDevicePairingString"] = "<insert pairing file here>"
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

    // MARK: - SC_Info / Manifest.plist cleanup (对齐 SideStore)

    /// 移除 SC_Info/Manifest.plist 中指向已被删除扩展的引用。
    /// DRM 正版 IPA 的 SC_Info/Manifest.plist 会列出所有扩展，若扩展被删除而 Manifest 未更新，
    /// installd 校验时会报 MissingBundle 或安装失败。
    private func removeMissingAppExtensionReferences(in appURL: URL) throws {
        let scInfoURL = appURL.appendingPathComponent("SC_Info")
        guard FileManager.default.fileExists(atPath: scInfoURL.path) else { return }

        let manifestURL = scInfoURL.appendingPathComponent("Manifest.plist")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }

        let data = try Data(contentsOf: manifestURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        )
        guard var manifest = value as? [String: Any] else { return }

        let pluginsURL = appURL.appendingPathComponent("PlugIns")
        var changed = false

        // SinfOptions: [SinfID: [BundlePath: ...]]
        if var sinfOptions = manifest["SinfOptions"] as? [String: Any] {
            for (key, entry) in sinfOptions {
                guard let dict = entry as? [String: Any],
                      let bundlePath = dict["BundlePath"] as? String else { continue }
                let appexName = (bundlePath as NSString).lastPathComponent
                let appexURL = pluginsURL.appendingPathComponent(appexName)
                if FileManager.default.fileExists(atPath: appexURL.path) == false {
                    sinfOptions.removeValue(forKey: key)
                    changed = true
                }
            }
            manifest["SinfOptions"] = sinfOptions
        }

        // SinfIDs 数组形式
        if var sinfIDs = manifest["SinfIDs"] as? [[String: Any]] {
            sinfIDs.removeAll { entry in
                guard let bundlePath = entry["BundlePath"] as? String else { return false }
                let appexName = (bundlePath as NSString).lastPathComponent
                let appexURL = pluginsURL.appendingPathComponent(appexName)
                let missing = FileManager.default.fileExists(atPath: appexURL.path) == false
                if missing { changed = true }
                return missing
            }
            manifest["SinfIDs"] = sinfIDs
        }

        if changed {
            let updated = try PropertyListSerialization.data(
                fromPropertyList: manifest,
                format: format,
                options: 0
            )
            try updated.write(to: manifestURL, options: .atomic)
        }
    }

    // MARK: - Exported UTIs (对齐 SideStore)

    /// 给重签后的 App 添加自定义 UTI，用于 Seal 检测已安装应用。
    private func addInstalledAppUTI(in appURL: URL, bundleID: String) throws {
        try mutateInfoPlist(at: appURL.appending(path: "Info.plist")) { info in
            let utiIdentifier = "com.mjorb.seal.installed-app"
            var exportedUTIs = info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
            if exportedUTIs.contains(where: { ($0["UTTypeIdentifier"] as? String) == utiIdentifier }) {
                return
            }
            exportedUTIs.append([
                "UTTypeIdentifier": utiIdentifier,
                "UTTypeDescription": "Seal Installed App",
                "UTTypeConformsTo": ["public.data"],
                "UTTypeTagSpecification": [
                    "com.mjorb.seal.bundle-id": [bundleID]
                ]
            ])
            info["UTExportedTypeDeclarations"] = exportedUTIs
        }
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
    /// 大 IPA 优化：剥离非 arm64 架构，只保留 arm64
    /// 支持 fat32(0xCAFEBABE) 和 fat64(0xCAFEBABF)，rork-sign 只支持 64-bit slice
    /// 清理其它签名/注入工具留下的残留（prepare 阶段、重签之前）。
    ///
    /// 部分 IPA 曾被 ESign 等工具签过，会在 .app 内留下注入脚本与工具标记（实测样本：
    /// `lzlukvca_inject.js`、`SignedByEsign`）。它们不被主二进制 LC_LOAD_DYLIB 引用，
    /// 但会夹带旧工具的运行时注入逻辑、干扰重签一致性，重签前移除。
    ///
    /// 安全边界：只删除白名单中、且不是可执行/库/bundle 的条目；.dylib/.framework/
    /// .appex/.bundle 等即使同名也绝不删——它们可能被 LC_LOAD_DYLIB 引用，盲删会让
    /// dyld 启动即闪退（去注入 dylib 必须同步移除 load command，属 Mach-O 改写，不在此）。
    private func removeThirdPartyInjectionArtifacts(in appURL: URL) {
        let residueNames: Set<String> = [
            "lzlukvca_inject.js", // ESign 注入脚本
            "signedbyesign"       // ESign 签名标记（文件或目录，大小写不敏感匹配）
        ]
        let protectedExtensions: Set<String> = [
            "dylib", "framework", "appex", "bundle", "app", "so", "a"
        ]
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        var matches: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            guard residueNames.contains(name) else { continue }
            guard protectedExtensions.contains(url.pathExtension.lowercased()) == false else { continue }
            matches.append(url)
        }
        // 先收集再删除，避免边遍历边改目录导致枚举失效；残留清理失败不阻断签名主流程。
        for url in matches {
            try? fileManager.removeItem(at: url)
        }
    }

    private func stripArm64eArchitecture(in appURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            let handle = try? FileHandle(forReadingFrom: url)
            defer { try? handle?.close() }
            guard let headerData = try? handle?.read(upToCount: 8),
                  headerData.count >= 8 else { continue }

            // 本地小端读取：大端 fat32(CA FE BA BE)->0xBEBAFECA, 大端 fat64(CA FE BA BF)->0xBFBAFECA
            let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let isFat64 = (magic == 0xBFBAFECA)
            guard magic == 0xBEBAFECA || isFat64 else { continue }

            // FAT 头全是大端，nfatArch 在偏移4
            let nfatArch = headerData.withUnsafeBytes {
                $0.load(fromByteOffset: 4, as: UInt32.self)
            }.bigEndian
            guard nfatArch >= 1 else { continue }

            // fat32 arch record=20字节, fat64=32字节
            let archRecordSize = isFat64 ? 32 : 20
            let archTableSize = Int(nfatArch) * archRecordSize
            guard let archData = try? handle?.read(upToCount: archTableSize),
                  archData.count >= archTableSize else { continue }

            // 遍历架构列表，找普通 arm64（排除 arm64e）
            var arm64Offset: UInt64 = 0
            var arm64Size: UInt64 = 0
            var found = false

            for i in 0..<Int(nfatArch) {
                let base = i * archRecordSize
                let cputype = archData.withUnsafeBytes {
                    $0.load(fromByteOffset: base, as: UInt32.self)
                }.bigEndian
                let cpusubtype = archData.withUnsafeBytes {
                    $0.load(fromByteOffset: base + 4, as: UInt32.self)
                }.bigEndian

                // cpusubtype 低24位是 subtype(0=ALL,1=V8,2=arm64e)，高8位是 capability bits
                guard cputype == 0x0100000C, (cpusubtype & 0x00FFFFFF) != 2 else { continue }

                if isFat64 {
                    // fat64: offset 在 base+8 (8字节), size 在 base+16 (8字节)
                    arm64Offset = archData.withUnsafeBytes {
                        $0.load(fromByteOffset: base + 8, as: UInt64.self)
                    }.bigEndian
                    arm64Size = archData.withUnsafeBytes {
                        $0.load(fromByteOffset: base + 16, as: UInt64.self)
                    }.bigEndian
                } else {
                    // fat32: offset 在 base+8 (4字节), size 在 base+12 (4字节)
                    arm64Offset = UInt64(archData.withUnsafeBytes {
                        $0.load(fromByteOffset: base + 8, as: UInt32.self)
                    }.bigEndian)
                    arm64Size = UInt64(archData.withUnsafeBytes {
                        $0.load(fromByteOffset: base + 12, as: UInt32.self)
                    }.bigEndian)
                }
                found = true
                break
            }

            guard found, arm64Size > 0 else { continue }

            // 分块流式写入 arm64 slice
            let tempURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).arm64tmp")
            try? fileManager.removeItem(at: tempURL)
            guard fileManager.createFile(atPath: tempURL.path, contents: nil) else { continue }

            let writeHandle = try? FileHandle(forWritingTo: tempURL)
            defer { try? writeHandle?.close() }

            try? handle?.seek(toOffset: arm64Offset)
            var remaining = Int(arm64Size)
            let chunkSize = 10 * 1024 * 1024
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

//
//  Install.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge

public protocol InstallProvider {
    func yeetAppAfc(bundleId: String, ipaBytes: Data) throws
    func installIpa(bundleId: String) throws
    func removeApp(bundleId: String) throws
}

public class Install {
    private static let providerLock = NSLock()
    private static var provider: InstallProvider?

    private static func getProvider() throws -> any InstallProvider {
        providerLock.lock()
        defer { providerLock.unlock() }
        if let provider { return provider }
        let selected: any InstallProvider = Muxer.isrppairing
            ? RPInstall()
            : LockDownInstall()
        provider = selected
        return selected
    }

    public static func resetProvider() {
        providerLock.lock()
        provider = nil
        providerLock.unlock()
    }

    public static func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        try getProvider().yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }
    public static func installIpa(bundleId: String) throws {
        try getProvider().installIpa(bundleId: bundleId)
    }
    public static func removeApp(bundleId: String) throws {
        try getProvider().removeApp(bundleId: bundleId)
    }
}

public class LockDownInstall: InstallProvider {
    public func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        print("[minimuxer] Yeeting IPA for bundle ID: \(bundleId)")

        let deviceIP = try DeviceEndpoint.shared.ip()
        print("[minimuxer] AFC: verifying device connectivity at \(deviceIP)...")
        guard Minimuxer.testDeviceConnection(ifaddr: deviceIP) else {
            print("[minimuxer] ERROR: Device not reachable before AFC start")
            throw MinimuxerError.NoConnection
        }
        print("[minimuxer] AFC: device reachable, fetching device handle")

        let device = try Device.getFirstDevice()
        print("[minimuxer] AFC: creating AFC client...")
        guard let afc = RustAfc.connect(device: device.internalInstance, label: "minimuxer") else {
            print("[minimuxer] ERROR: Could not start AFC service")
            throw MinimuxerError.CreateAfc
        }
        print("[minimuxer] AFC: client created successfully")

        let pkg = MuxerConstants.pkgPath
        // 经典 lockdown 通道（非 RSD）沿用 SideStore minimuxer 真机验证过的布局：
        // PublicStaging/<bundleId>/app.ipa，按 Bundle ID 建子目录。这与 RSD 通道的固定
        // 单文件 PublicStaging/idevice.ipa 是两套不同约定，不能混用。路径不带 "./" 前缀
        // （Swift port 已验证可行的形态，规避历史 mkdirP 空段问题）。
        let appDir = "\(pkg)/\(bundleId)"
        mkdirP(appDir, afc: afc)
        let stagedPath = "\(appDir)/app.ipa"
        // 覆盖前删除旧包，避免「w」打开不截断导致旧包尾部残留成损坏 zip。
        _ = afc.remove(path: stagedPath)

        if !afc.writeFile(path: stagedPath, data: ipaBytes) {
            print("[minimuxer] ERROR: Unable to write IPA to device")
            throw MinimuxerError.RwAfc
        }
        print("[minimuxer] Successfully staged IPA")
    }
    
    /// 根据 instproxy lookup 结果决定是否走 Upgrade（纯逻辑，便于单测）。
    /// - 返回非空 plist 字符串：设备已存在该 Bundle ID（含残留占位）→ 需要 Upgrade。
    /// - 返回 nil（未安装）或空串：全新 Install。查询失败 lookup 也返回 nil，按首装处理，
    ///   避免查询抖动阻断安装。
    static func shouldUpgrade(lookupResult: String?) -> Bool {
        guard let result = lookupResult else { return false }
        return result.isEmpty == false
    }

    private func mkdirP(_ path: String, afc: RustAfc) {
        var current = ""
        for part in path.split(separator: "/") where !part.isEmpty {
            current = current.isEmpty ? String(part) : "\(current)/\(part)"
            _ = afc.mkdir(path: current)
        }
    }

    public func installIpa(bundleId: String) throws {
        print("[minimuxer] Installing app for bundle ID: \(bundleId)")
        let device = try Device.getFirstDevice()
        guard let inst = RustInstProxy.connect(device: device.internalInstance, label: "ideviceinstaller") else {
            print("[minimuxer] ERROR: Unable to start instproxy")
            throw MinimuxerError.CreateInstproxy
        }
        // 经典通道暂存布局：PublicStaging/<bundleId>/app.ipa（与 yeetAppAfc 保持一致）。
        let path = "\(MuxerConstants.pkgPath)/\(bundleId)/app.ipa"

        // 设备上已存在同一 Bundle ID（上次失败留下的占位、多开副本、续签覆盖）时必须走
        // Upgrade；对已存在的 Bundle ID 发全新 Install 会在定位阶段报 MissingPackagePath。
        // lookup 命中已存在记录（非空 plist）→ Upgrade；无记录或查询返回 nil → 全新 Install，
        // 查询失败也按未安装处理，不阻断首装。
        let alreadyInstalled = Self.shouldUpgrade(lookupResult: inst.lookup(appId: bundleId))
        let action = alreadyInstalled ? "Upgrade" : "Install"
        print("[minimuxer] \(action)...")

        let deviceError: String? = alreadyInstalled
            ? inst.upgrade(path: path, bundleId: bundleId)
            : inst.install(path: path, bundleId: bundleId)

        if let deviceError = deviceError {
            print("[minimuxer] ERROR: \(action) failed: \(deviceError)")
            // 兜底：设备上有 lookup 看不到的残留安装记录（上次失败占位）时，
            // Install/Upgrade 都会被 installd 以 MissingPackagePath 拒绝。
            // 卸载清掉残留记录（不动 AFC 暂存包）后全新安装。
            guard deviceError.contains("MissingPackagePath") else {
                throw MinimuxerError.InstallApp(deviceError)
            }
            print("[minimuxer] MissingPackagePath fallback: removing stale record and retrying fresh Install")
            _ = inst.uninstall(bundleId: bundleId)
            if let retryError = inst.install(path: path, bundleId: bundleId) {
                print("[minimuxer] ERROR: fresh Install after cleanup failed: \(retryError)")
                throw MinimuxerError.InstallApp(retryError)
            }
        }
        print("[minimuxer] \(action) done!")
    }

    public func removeApp(bundleId: String) throws {
        print("[minimuxer] Removing app: \(bundleId)")
        let device = try Device.getFirstDevice()
        guard let inst = RustInstProxy.connect(device: device.internalInstance, label: "minimuxer-remove-app") else {
            print("[minimuxer] ERROR: Unable to start instproxy")
            throw MinimuxerError.CreateInstproxy
        }
        print("[minimuxer] Removing...")
        if !inst.uninstall(bundleId: bundleId) {
            print("[minimuxer] ERROR: Unable to uninstall app")
            throw MinimuxerError.UninstallApp
        }
        print("[minimuxer] Remove done!")
    }
}

public class RPInstall: InstallProvider {
    /// yeet 与 install 之间暂存 IPA 字节：合并调用要求两步共享同一隧道会话窗口
    private static let pendingLock = NSLock()
    private static var pendingIPAs: [String: Data] = [:]

    public func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        // 保存字节，installIpa 时走合并调用（Rust 侧重新上传并立即安装）
        RPInstall.pendingLock.lock()
        RPInstall.pendingIPAs[bundleId] = ipaBytes
        RPInstall.pendingLock.unlock()
        try RustIdevice.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }

    public func installIpa(bundleId: String) throws {
        RPInstall.pendingLock.lock()
        let pendingBytes = RPInstall.pendingIPAs.removeValue(forKey: bundleId)
        RPInstall.pendingLock.unlock()

        if let pendingBytes {
            // 上传与安装在一段调用内完成，消除两段 FFI 之间暂存文件消失的窗口
            try RustIdevice.stageAndInstall(bundleId: bundleId, ipaBytes: pendingBytes)
        } else {
            try RustIdevice.installIpa(bundleId: bundleId)
        }
    }

    public func removeApp(bundleId: String) throws {
        try RustIdevice.removeApp(bundleId: bundleId)
    }
}

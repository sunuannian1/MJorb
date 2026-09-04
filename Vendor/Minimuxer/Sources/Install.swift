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
        // 对齐官方 idevice：固定 PublicStaging/idevice.ipa 单文件路径（旧的按 bundle id
        // 分子目录在新版系统上会触发 MissingPackagePath）。安装串行，固定名覆盖即可。
        mkdirP(pkg, afc: afc)
        let stagedPath = "\(pkg)/idevice.ipa"
        // 覆盖前删除旧包，避免「w」打开不截断导致旧包尾部残留成损坏 zip。
        _ = afc.remove(path: stagedPath)

        if !afc.writeFile(path: stagedPath, data: ipaBytes) {
            print("[minimuxer] ERROR: Unable to write IPA to device")
            throw MinimuxerError.RwAfc
        }
        print("[minimuxer] Successfully staged IPA")
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
        let path = "\(MuxerConstants.pkgPath)/idevice.ipa"
        print("[minimuxer] Installing...")
        if let installError = inst.install(path: path) {
            print("[minimuxer] ERROR: Install failed: \(installError)")
            throw MinimuxerError.InstallApp(installError)
        }
        print("[minimuxer] Install done!")
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
    public func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        try RustIdevice.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }
    public func installIpa(bundleId: String) throws {
        try RustIdevice.installIpa(bundleId: bundleId)
    }
    public func removeApp(bundleId: String) throws {
        try RustIdevice.removeApp(bundleId: bundleId)
    }
}

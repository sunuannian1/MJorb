import Foundation
import UIKit
@preconcurrency import AltSign

enum ApplePortalSigningStage {
    case account
    case device
    case certificate
    case appID
    case provisioningProfile
    case signing
    case packaging
}

enum ApplePortalAppIDResolver {
    static func matches(
        existingBundleIdentifier: String,
        requestedBundleIdentifier: String
    ) -> Bool {
        existingBundleIdentifier.caseInsensitiveCompare(requestedBundleIdentifier) == .orderedSame
    }
}

enum ApplePortalSigningFailure {
    static func make(stage: ApplePortalSigningStage, error: Error) -> ImportFailure {
        if AppleServiceFailurePolicy.isNetworkError(error) {
            return AppleServiceFailurePolicy.networkFailure(
                title: "Apple 服务暂时不可用",
                reason: "当前网络或 Apple 服务不可用。Apple ID 状态不会被修改。"
            )
        }
        let nsError = error as NSError
        let diagnostic = "[\(nsError.domain) \(nsError.code)] \(nsError.localizedDescription)"
        let details: (title: String, reason: String, recovery: String, code: String)
        switch stage {
        case .account:
            if nsError.code == 1100 || diagnostic.contains("session has expired") || diagnostic.contains("1100") {
                details = (
                    "Apple 会话已过期",
                    "当前 Apple ID 的登录状态已过期，需要重新登录后才能签名或续签。\nApple 返回：\(diagnostic)",
                    "重新登录",
                    "SEAL-AUTH-107"
                )
            } else {
                details = (
                    "Apple 账户操作失败",
                    "Apple 返回了无法分类的账户错误。账号状态未改变。\nApple 返回：\(diagnostic)",
                    "重试",
                    "SEAL-VERIFY-500"
                )
            }
        case .device:
            details = (
                "设备注册失败",
                "Apple 返回：设备注册未完成。\nApple 返回：\(diagnostic)",
                "检查设备配对",
                "SEAL-DEVICE-203"
            )
        case .certificate:
            return certificateFailure(error: error, diagnostic: diagnostic)
        case .appID:
            return appIDFailure(error: error, diagnostic: diagnostic)
        case .provisioningProfile:
            details = (
                "描述文件失败",
                "Apple 返回：描述文件生成失败。\nApple 返回：\(diagnostic)",
                "重试",
                "SEAL-PROFILE-303"
            )
        case .signing:
            details = (
                "签名失败",
                "签名工具未能完成当前 IPA。\n详情：\(diagnostic)",
                "重试",
                "SEAL-SIGN-501"
            )
        case .packaging:
            details = (
                "打包失败",
                "签名后的 IPA 无法完成打包。\n详情：\(diagnostic)",
                "重试",
                "SEAL-SIGN-502"
            )
        }
        return ImportFailure(
            title: details.title,
            reason: details.reason,
            recovery: details.recovery,
            code: details.code
        )
    }

    private static func appIDFailure(error: Error, diagnostic: String) -> ImportFailure {
        let nsError = error as NSError
        let rawMessage = nsError.localizedDescription
        let normalized = rawMessage.lowercased()

        if nsError.code == 3011
            || normalized.contains("bundle identifier is unavailable")
            || normalized.contains("already registered by another developer account")
            || normalized.contains("bundle identifier unavailable") {
            return ImportFailure(
                title: "Bundle ID 已被占用",
                reason: "这个 Bundle ID 已被其他开发者账号注册，当前账号无法使用。",
                recovery: "更换一个新的 Bundle ID，或使用注册该 Bundle ID 的原账号签名",
                code: "SEAL-APPID-302"
            )
        }

        // 免费账号 App ID 数量上限（AltStore 官方错误码 1009）
        if nsError.code == 1009
            || normalized.contains("maximum")
            || normalized.contains("limit")
            || normalized.contains("too many")
            || normalized.contains("no more")
            || (normalized.contains("app id") && (normalized.contains("exceed") || normalized.contains("reached"))) {
            return ImportFailure(
                title: "7 天内最多注册 10 个 App ID",
                reason: "已达到 App ID 数量上限。App ID 无法手动删除，7 天后自动过期。请到「已签名 App」查看过期时间，或换其他 Apple ID 签名。",
                recovery: "知道了",
                code: "SEAL-APPID-304"
            )
        }

        return ImportFailure(
            title: "App ID 创建失败",
            reason: "Apple 服务器未能创建该应用的 App ID。Apple 返回：\(diagnostic)",
            recovery: "检查网络后重试；如持续失败，尝试更换 Bundle ID 或使用其他开发者账号",
            code: "SEAL-APPID-303"
        )
    }

    private static func certificateFailure(error: Error, diagnostic: String) -> ImportFailure {
        let nsError = error as NSError
        let rawMessage = nsError.localizedDescription
        let normalized = rawMessage.lowercased()

        if normalized.contains("maximum")
            || normalized.contains("limit")
            || normalized.contains("too many")
            || normalized.contains("invalidcertificaterequest") {
            return ImportFailure(
                title: "无法创建签名证书",
                reason: "Apple 服务器未能创建签名证书。可能原因：该账号证书数量已达上限、或网络不稳定。",
                recovery: "检查网络后重试；如持续失败请在「我的」中撤销旧证书后再试",
                code: "SEAL-CERT-204a"
            )
        }

        if normalized.contains("network")
            || normalized.contains("timed out")
            || normalized.contains("cannot connect")
            || nsError.domain == NSURLErrorDomain {
            return ImportFailure(
                title: "证书服务连接失败",
                reason: "Apple 返回：证书服务暂时不可用",
                recovery: "重试",
                code: "SEAL-CERT-205"
            )
        }

        if normalized.contains("unauthorized")
            || normalized.contains("authentication")
            || normalized.contains("session")
            || normalized.contains("forbidden") {
            return ImportFailure(
                title: "账号需要重新验证",
                reason: "Apple 返回：认证状态无效",
                recovery: "前往「我的」页面重新登录该 Apple ID",
                code: "SEAL-AUTH-102c"
            )
        }

        return ImportFailure(
            title: "证书准备失败",
            reason: "Apple 服务器未能准备好签名证书。\nApple 返回：\(diagnostic)",
            recovery: "检查网络后重试；如持续失败请在「我的」中撤销旧证书后再试",
            code: "SEAL-CERT-203"
        )
    }

}

actor ApplePortalSigningService {
    private let anisetteProvider: any AnisetteProvider
    private let signingWorkspace: SigningWorkspace
    private let accountClient: AppleAccountClient
    private let verificationCodeProvider: (@MainActor @Sendable () async -> String?)?

    init(
        anisetteProvider: any AnisetteProvider = AnisetteV3Client(),
        signingWorkspace: SigningWorkspace = SigningWorkspace(),
        verificationCodeProvider: (@MainActor @Sendable () async -> String?)? = nil
    ) {
        self.anisetteProvider = anisetteProvider
        self.signingWorkspace = signingWorkspace
        self.accountClient = AppleAccountClient(anisetteProvider: anisetteProvider)
        self.verificationCodeProvider = verificationCodeProvider
    }

    func sign(
        app: AppRecord,
        account: AppleAccountRecord,
        secret: AccountSecret,
        deviceIdentifier: String,
        originalIPAURL: URL,
        workspaceRoot: URL,
        targetBundleIdentifier: String? = nil,
        preferredIconData: Data? = nil,
        selectedCertificateSerialNumber: String? = nil,
        allowDroppingExtensions: Bool,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void,
        progress: @Sendable (SigningStage) async -> Void
    ) async throws -> PortalSigningResult {
        let secretState = SigningSecretState(secret)
        let persistence: @Sendable (AccountSecret, String) async throws -> Void = {
            updatedSecret, serialNumber in
            try await persistSigningMaterial(updatedSecret, serialNumber)
            await secretState.update(updatedSecret)
        }

        do {
            return try await signOnce(
                app: app,
                account: account,
                secret: await secretState.value(),
                deviceIdentifier: deviceIdentifier,
                originalIPAURL: originalIPAURL,
                workspaceRoot: workspaceRoot,
                targetBundleIdentifier: targetBundleIdentifier,
                preferredIconData: preferredIconData,
                selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                allowDroppingExtensions: allowDroppingExtensions,
                persistSigningMaterial: persistence,
                progress: progress
            )
        } catch let failure as ImportFailure where failure.code == "SEAL-AUTH-107" {
            // Apple 会话过期（1100），如果保存了密码则自动重新登录
            let currentSecret = await secretState.value()
            guard let password = currentSecret.password else { throw failure }
            do {
                let newSecret: AccountSecret
                if let verificationCodeProvider {
                    newSecret = try await accountClient.reauthenticate(
                        email: currentSecret.email,
                        password: password,
                        verificationCode: verificationCodeProvider
                    )
                } else {
                    newSecret = try await accountClient.reauthenticate(
                        email: currentSecret.email,
                        password: password,
                        verificationCode: { nil }
                    )
                }
                try await persistSigningMaterial(newSecret, currentSecret.certificateSerialNumber ?? "")
                await secretState.update(newSecret)
                return try await signOnce(
                    app: app,
                    account: account,
                    secret: newSecret,
                    deviceIdentifier: deviceIdentifier,
                    originalIPAURL: originalIPAURL,
                    workspaceRoot: workspaceRoot,
                    targetBundleIdentifier: targetBundleIdentifier,
                    preferredIconData: preferredIconData,
                    selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                    allowDroppingExtensions: allowDroppingExtensions,
                    persistSigningMaterial: persistence,
                    progress: progress
                )
            } catch {
                // 自动重登失败（可能需要验证码），提示用户手动重新登录，不标记ID失效
                throw Self.failure(
                    title: "需要重新验证 Apple ID",
                    reason: "当前 Apple ID 的登录状态已过期，且自动重新登录需要双重验证码。请前往「我的」页面，重新验证该 Apple ID 后再签名。",
                    recovery: "去验证 Apple ID",
                    code: "SEAL-AUTH-107a"
                )
            }
        } catch let failure as ImportFailure where Self.shouldRetryWithFreshSigningCertificate(failure) {
            var refreshedSecret = await secretState.value()
            refreshedSecret.certificateP12 = nil
            refreshedSecret.certificateSerialNumber = nil
            refreshedSecret.certificateMachineIdentifier = nil
            await secretState.update(refreshedSecret)
            let retryWorkspaceRoot = workspaceRoot.appending(path: "FreshCertificateRetry-\(UUID().uuidString)")
            return try await signOnce(
                app: app,
                account: account,
                secret: refreshedSecret,
                deviceIdentifier: deviceIdentifier,
                originalIPAURL: originalIPAURL,
                workspaceRoot: retryWorkspaceRoot,
                targetBundleIdentifier: targetBundleIdentifier,
                preferredIconData: preferredIconData,
                selectedCertificateSerialNumber: nil,
                allowDroppingExtensions: allowDroppingExtensions,
                persistSigningMaterial: persistence,
                progress: progress
            )
        } catch ALTAppleAPIError.invalidAnisetteData {
            await anisetteProvider.resetProvisioning()
            do {
                return try await signOnce(
                    app: app,
                    account: account,
                    secret: await secretState.value(),
                    deviceIdentifier: deviceIdentifier,
                    originalIPAURL: originalIPAURL,
                    workspaceRoot: workspaceRoot,
                    targetBundleIdentifier: targetBundleIdentifier,
                    preferredIconData: preferredIconData,
                    selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                    allowDroppingExtensions: allowDroppingExtensions,
                    persistSigningMaterial: persistence,
                    progress: progress
                )
            } catch let failure as ImportFailure {
                throw failure
            } catch {
                throw Self.failure(
                    title: "签名请求失败",
            reason: "Apple 服务器未能完成签名请求。可能原因：网络不稳定、或 Apple 服务暂时不可用。",
            recovery: "检查网络后稍后重试；如持续失败请查看日志",
                    code: "SEAL-SIGN-501"
                )
            }
        }
    }

    private static func shouldRetryWithFreshSigningCertificate(_ failure: ImportFailure) -> Bool {
        if failure.code == "SEAL-PROFILE-313" { return true }
        let message = "\(failure.title) \(failure.reason) \(failure.recovery)"
        return failure.title.localizedCaseInsensitiveContains("描述文件校验失败")
            && message.localizedCaseInsensitiveContains("证书")
    }

    private func signOnce(
        app: AppRecord,
        account: AppleAccountRecord,
        secret: AccountSecret,
        deviceIdentifier: String,
        originalIPAURL: URL,
        workspaceRoot: URL,
        targetBundleIdentifier: String?,
        preferredIconData: Data?,
        selectedCertificateSerialNumber: String?,
        allowDroppingExtensions: Bool,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void,
        progress: @Sendable (SigningStage) async -> Void
    ) async throws -> PortalSigningResult {
        var stage: ApplePortalSigningStage = .account
        do {
            try Task.checkCancellation()
            await progress(.preparingAccount)
            let anisette = try await anisetteProvider.fetch()
            let session = ALTAppleAPISession(
                dsid: secret.dsid,
                authToken: secret.authToken,
                anisetteData: anisette
            )
            let altAccount = ALTAccount()
            altAccount.appleID = secret.email
            altAccount.identifier = secret.accountIdentifier
            let teams = try await fetchTeams(account: altAccount, session: session)
            try Task.checkCancellation()
            guard let team = teams.first(where: { $0.identifier == account.teamID }) else {
                throw Self.failure(
                    title: "Team 不匹配",
                    reason: "当前 Apple ID 中没有找到已保存的 Team。Seal 不会静默切换到其他 Team。",
                    recovery: "选择 Team",
                    code: "SEAL-AUTH-112d"
                )
            }
            let deviceName = await MainActor.run { UIDevice.current.name }
            stage = .device
            _ = try await ensureDevice(
                identifier: deviceIdentifier,
                name: deviceName,
                team: team,
                session: session
            )
            try Task.checkCancellation()

            await progress(.preparingCertificate)
            stage = .certificate
            let identity = try await signingIdentity(
                account: account,
                secret: secret,
                team: team,
                session: session,
                deviceName: deviceName,
                selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                persistSigningMaterial: persistSigningMaterial
            )
            try Task.checkCancellation()

            stage = .packaging
            let prepared = try signingWorkspace.prepare(
                ipaURL: originalIPAURL,
                workspaceRoot: workspaceRoot,
                originalBundleID: app.originalBundleIdentifier,
                teamID: team.identifier,
                targetMainBundleID: targetBundleIdentifier,
                preferredDisplayName: app.preferredDisplayName,
                preferredIconData: preferredIconData
            )
            try Task.checkCancellation()

            await progress(.preparingAppID)
            stage = .appID
            let profilePreparation = try await provisioningProfiles(
                mappings: prepared.bundleIDMappings,
                mappedMainBundleID: prepared.mappedMainBundleID,
                appName: app.displayName,
                appURL: prepared.appURL,
                workspace: prepared,
                allowDroppingExtensions: allowDroppingExtensions,
                team: team,
                session: session,
                progress: progress
            )
            try Task.checkCancellation()
            guard profilePreparation.profiles.contains(where: {
                $0.bundleIdentifier == prepared.mappedMainBundleID
            }) else {
                throw Self.failure(
                    title: "无法签名",
                    reason: "主应用描述文件缺失",
                    recovery: "检查网络后重试；如持续失败请重新导入 IPA",                    code: "SEAL-PROFILE-303"
                )
            }

            await progress(.signing)
            stage = .signing
            try await signApp(
                at: prepared.appURL,
                team: team,
                certificate: identity.certificate,
                profiles: profilePreparation.profiles
            )
            try Task.checkCancellation()

            let profileBindings = try validateEmbeddedProfiles(
                in: prepared,
                teamID: team.identifier,
                certificateSerialNumber: identity.certificate.serialNumber,
                deviceIdentifier: deviceIdentifier,
                requestedEntitlements: profilePreparation.requestedEntitlements
            )
            guard let mainBinding = profileBindings[prepared.mappedMainBundleID] else {
                throw Self.failure(
                    title: "描述文件校验失败",
                    reason: "签名完成后未找到主应用的 embedded.mobileprovision：\(prepared.mappedMainBundleID)。",
                    recovery: "重新获取描述文件",
                    code: "SEAL-PROFILE-317a"
                )
            }

            stage = .packaging
            let signedIPAURL = prepared.rootURL.appending(path: "Signed.ipa")
            try signingWorkspace.package(prepared, outputURL: signedIPAURL)

            return PortalSigningResult(
                mappedMainBundleID: prepared.mappedMainBundleID,
                mappedBundleIdentifiers: prepared.bundleIDMappings,
                expirationDate: mainBinding.expirationDate,
                signedIPAURL: signedIPAURL,
                updatedSecret: identity.secret,
                certificateSerialNumber: identity.certificate.serialNumber,
                certificateMachineIdentifier: identity.certificate.machineIdentifier,
                deviceIdentifier: deviceIdentifier,
                teamID: team.identifier,
                profileBindings: profileBindings,
                droppedExtensionBundleIdentifiers:
                    profilePreparation.droppedExtensionBundleIdentifiers
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ALTAppleAPIError.invalidAnisetteData {
            throw ALTAppleAPIError(.invalidAnisetteData)
        } catch ALTAppleAPIError.maximumAppIDLimitReached {
            throw Self.failure(
                title: "App ID 名额已满",
                reason: "Apple 返回 App ID 数量已达到账号上限。",
                recovery: "使用其他 Bundle ID 或开发者账号。",
                code: "SEAL-APPID-301"
            )
        } catch ALTAppleAPIError.incorrectCredentials {
            throw Self.failure(
                title: "账号需要验证",
                reason: "Apple ID 会话已失效",
                recovery: "前往「我的」页面重新登录该 Apple ID",
                code: "SEAL-AUTH-102d"
            )
        } catch ALTAppleAPIError.authenticationHandshakeFailed {
            throw Self.failure(
                title: "账号需要验证",
                reason: "Apple ID 会话已失效",
                recovery: "前往「我的」页面重新登录该 Apple ID",
                code: "SEAL-AUTH-102e"
            )
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            throw ApplePortalSigningFailure.make(stage: stage, error: error)
        }
    }

    private func fetchTeams(
        account: ALTAccount,
        session: ALTAppleAPISession
    ) async throws -> [ALTTeam] {
        let box: LegacyBox<[ALTTeam]> = try await withCheckedThrowingContinuation {
            continuation in
            ALTAppleAPI.shared.fetchTeams(for: account, session: session) { teams, error in
                Self.resume(continuation, value: teams, error: error)
            }
        }
        return box.value
    }

    private func ensureDevice(
        identifier: String,
        name: String,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTDevice {
        let devicesBox: LegacyBox<[ALTDevice]> = try await withCheckedThrowingContinuation {
            continuation in
            ALTAppleAPI.shared.fetchDevices(
                for: team,
                types: [.iphone, .ipad],
                session: session
            ) { devices, error in
                Self.resume(continuation, value: devices, error: error)
            }
        }
        if let device = devicesBox.value.first(where: { $0.identifier == identifier }) {
            return device
        }
        let deviceBox: LegacyBox<ALTDevice> = try await withCheckedThrowingContinuation {
            continuation in
            ALTAppleAPI.shared.registerDevice(
                name: name,
                identifier: identifier,
                type: .iphone,
                team: team,
                session: session
            ) { device, error in
                Self.resume(continuation, value: device, error: error)
            }
        }
        return deviceBox.value
    }

    private func signingIdentity(
        account: AppleAccountRecord,
        secret: AccountSecret,
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String,
        selectedCertificateSerialNumber: String?,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void
    ) async throws -> SigningIdentity {
        let certificates = try await fetchCertificates(team: team, session: session)
        try Task.checkCancellation()

        if let selectedCertificateSerialNumber,
           let data = secret.certificateP12,
           let remote = certificates.first(where: {
               $0.serialNumber.caseInsensitiveCompare(selectedCertificateSerialNumber) == .orderedSame
           }),
           let local = try? ALTCertificate(p12Data: data, password: nil),
           local.serialNumber.caseInsensitiveCompare(selectedCertificateSerialNumber) == .orderedSame {
            local.machineIdentifier = remote.machineIdentifier
            return SigningIdentity(certificate: local, secret: secret)
        }

        if let serial = secret.certificateSerialNumber,
           let data = secret.certificateP12,
           let remote = certificates.first(where: {
               $0.serialNumber.caseInsensitiveCompare(serial) == .orderedSame
           }),
           let local = try? ALTCertificate(p12Data: data, password: nil),
           local.serialNumber.caseInsensitiveCompare(serial) == .orderedSame {
            local.machineIdentifier = remote.machineIdentifier
            return SigningIdentity(certificate: local, secret: secret)
        }

        return try await createSigningIdentity(
            secret: secret,
            certificates: certificates,
            team: team,
            session: session,
            deviceName: deviceName,
            persistSigningMaterial: persistSigningMaterial
        )
    }

    private func createSigningIdentity(
        secret: AccountSecret,
        certificates: [ALTCertificate],
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void
    ) async throws -> SigningIdentity {
        let requested: ALTCertificate
        do {
            let created = try await addCertificate(
                team: team,
                session: session,
                deviceName: deviceName
            )
            try Task.checkCancellation()
            requested = created
        } catch {
            guard Self.isCertificateLimitError(error) else { throw error }
            requested = try await recoverCertificateCapacityAndCreate(
                initialCertificates: certificates,
                protectedSerialNumber: secret.certificateSerialNumber,
                team: team,
                session: session,
                deviceName: deviceName
            )
        }

        do {
            guard let certificate = try await waitForCreatedCertificate(
                serialNumber: requested.serialNumber,
                team: team,
                session: session
            ) else {
                throw Self.failure(
                    title: "证书创建结果不一致",
                    reason: "Apple 已返回新证书，但重新同步后无法确认该证书。",
                    recovery: "重新同步证书",
                    code: "SEAL-CERT-209a"
                )
            }
            certificate.privateKey = requested.privateKey
            guard let p12 = certificate.p12Data() else {
                throw Self.failure(
                    title: "无法保存新证书",
                    reason: "Apple 已创建证书，但本机无法将证书与私钥合成 P12。",
                    recovery: "重试签名",
                    code: "SEAL-CERT-202a"
                )
            }

            var updatedSecret = secret
            updatedSecret.certificateP12 = p12
            updatedSecret.certificateSerialNumber = certificate.serialNumber
            updatedSecret.certificateMachineIdentifier = certificate.machineIdentifier

            try await persistSigningMaterial(updatedSecret, certificate.serialNumber)
            return SigningIdentity(certificate: certificate, secret: updatedSecret)
        } catch {
            let cleanedUp = await cleanUpNewCertificate(
                serialNumber: requested.serialNumber,
                certificate: requested,
                team: team,
                session: session,
                secret: secret
            )
            guard cleanedUp else {
                throw Self.failure(
                    title: "签名失败",
                    reason: "Apple 返回：无法创建签名证书",
                    recovery: "重试",
                    code: "SEAL-CERT-215c"
                )
            }
            if let failure = error as? ImportFailure { throw failure }
            throw error
        }
    }

    private func waitForCreatedCertificate(
        serialNumber: String,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTCertificate? {
        let maxAttempts = 10
        let retryDelayNanoseconds: UInt64 = 500_000_000
        var lastFetchError: Error?
        var hadSuccessfulFetch = false

        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()

            do {
                let certificates = try await fetchCertificates(team: team, session: session)
                hadSuccessfulFetch = true
                if let certificate = certificates.first(where: {
                    $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame
                }) {
                    return certificate
                }
            } catch {
                lastFetchError = error
            }

            if attempt + 1 < maxAttempts {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        if hadSuccessfulFetch {
            return nil
        }
        if let lastFetchError {
            throw lastFetchError
        }
        return nil
    }
    private func recoverCertificateCapacityAndCreate(
        initialCertificates: [ALTCertificate],
        protectedSerialNumber: String?,
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String
    ) async throws -> ALTCertificate {
        let latest = (try? await fetchCertificates(team: team, session: session))
            ?? initialCertificates
        let protected = protectedSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = latest.filter { certificate in
            guard let protected, protected.isEmpty == false else { return true }
            return certificate.serialNumber.caseInsensitiveCompare(protected) != .orderedSame
        }

        for certificate in candidates {
            try Task.checkCancellation()
            guard (try? await revokeCertificate(certificate, team: team, session: session)) != nil else {
                continue
            }
            do {
                let created = try await addCertificate(
                    team: team,
                    session: session,
                    deviceName: deviceName
                )
                try Task.checkCancellation()
                return created
            } catch {
                guard Self.isCertificateLimitError(error) else { throw error }
            }
        }

        throw Self.failure(
            title: "签名失败",
            reason: "Apple 返回：无法创建签名证书",
            recovery: "重试",
            code: "SEAL-CERT-204b"
        )
    }

    private func cleanUpNewCertificate(
        serialNumber: String,
        certificate: ALTCertificate,
        team: ALTTeam,
        session: ALTAppleAPISession,
        secret: AccountSecret
    ) async -> Bool {
        if (try? await revokeCertificate(certificate, team: team, session: session)) != nil {
            return true
        }

        await anisetteProvider.resetProvisioning()
        guard let anisette = try? await anisetteProvider.fetch() else { return false }
        let refreshedSession = ALTAppleAPISession(
            dsid: secret.dsid,
            authToken: secret.authToken,
            anisetteData: anisette
        )
        guard let certificates = try? await fetchCertificates(
            team: team,
            session: refreshedSession
        ) else {
            return false
        }
        guard let exactCertificate = certificates.first(where: {
            $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame
        }) else {
            return true
        }
        return (try? await revokeCertificate(
            exactCertificate,
            team: team,
            session: refreshedSession
        )) != nil
    }

    private static func isCertificateLimitError(_ error: Error) -> Bool {
        if let apiError = error as? ALTAppleAPIError,
           case .invalidCertificateRequest = apiError {
            return true
        }
        let nsError = error as NSError
        let normalized = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription) \(String(describing: error))".lowercased()
        return nsError.code == 3022
            || normalized.contains("3022")
            || normalized.contains("maximum number of certificates")
            || normalized.contains("maximum") && normalized.contains("certificate")
            || normalized.contains("too many") && normalized.contains("certificate")
            || normalized.contains("invalidcertificaterequest")
    }

    private func fetchCertificates(
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> [ALTCertificate] {
        let box: LegacyBox<[ALTCertificate]> = try await withCheckedThrowingContinuation {
            continuation in
            ALTAppleAPI.shared.fetchCertificates(for: team, session: session) {
                certificates, error in
                Self.resume(continuation, value: certificates, error: error)
            }
        }
        return box.value
    }

    private func addCertificate(
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String
    ) async throws -> ALTCertificate {
        let box: LegacyBox<ALTCertificate> = try await withCheckedThrowingContinuation {
            continuation in
            ALTAppleAPI.shared.addCertificate(
                machineName: certificateMachineName(team: team, deviceName: deviceName),
                to: team,
                session: session
            ) { certificate, error in
                Self.resume(continuation, value: certificate, error: error)
            }
        }
        return box.value
    }

    private func certificateMachineName(team: ALTTeam, deviceName: String) -> String {
        let sanitizedDevice = deviceName
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        let devicePart = sanitizedDevice.isEmpty ? "Device" : String(sanitizedDevice.prefix(18))
        let teamPart = String(team.identifier.prefix(8))
        let timestamp = Int(Date().timeIntervalSince1970)
        return "Apple Development-\(teamPart)-\(devicePart)-\(timestamp)"
    }

    private func revokeCertificate(
        _ certificate: ALTCertificate,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            ALTAppleAPI.shared.revoke(certificate, for: team, session: session) {
                success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? URLError(.badServerResponse)
                    )
                }
            }
        }
    }

    private func provisioningProfiles(
        mappings: [String: String],
        mappedMainBundleID: String,
        appName: String,
        appURL: URL,
        workspace: PreparedSigningWorkspace,
        allowDroppingExtensions: Bool,
        team: ALTTeam,
        session: ALTAppleAPISession,
        progress: @Sendable (SigningStage) async -> Void
    ) async throws -> ProfilePreparation {
        guard let mainApplication = ALTApplication(fileURL: appURL) else {
            throw Self.failure(
                title: "无法签名",
                reason: "应用结构无效",
                recovery: "检查 IPA",
                code: "SEAL-SIGN-404a"
            )
        }
        var applications = [mainApplication.bundleIdentifier: mainApplication]
        for appExtension in mainApplication.appExtensions {
            applications[appExtension.bundleIdentifier] = appExtension
        }

        var existing = try await fetchAppIDs(team: team, session: session)

        // 免费账号 App ID 上限预检：主 App 必须签，扩展签不了自动跳过




        // 宽松策略：主 App 必须签，扩展签不了就自动跳过，不直接报错
        if team.type == .free {
            let maximumFreeAppIDs = 10
            let availableAppIDs = max(0, maximumFreeAppIDs - existing.count)
            // 主 App 都签不了才报错
            if availableAppIDs < 1 {
                let sortedExpirations = existing.compactMap { $0.expirationDate }.sorted()
                let earliestExpiration = sortedExpirations.first
                let expirationText = earliestExpiration.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "未知"
                throw Self.failure(
                    title: "App ID 数量不足",
                    reason: "当前 Apple ID 已有 \(existing.count) 个 App ID（上限 \(maximumFreeAppIDs)），连主 App 都无法创建。",
                    recovery: "最早的 App ID 将于 \(expirationText) 过期，过期后可重试；或使用其他 Apple ID 签名。",
                    code: "SEAL-APPID-LIMIT"
                )
            }
            // 扩展数量不足时，后面 Phase 1 会自动跳过签不了的扩展，只签主 App
        }

        var preparedAppIDs: [(original: String, mapped: String, appID: ALTAppID)] = []
        var requestedEntitlements: [String: [String: ProvisioningEntitlementValue]] = [:]
        var droppedExtensionBundleIdentifiers: [String] = []

        // Phase 1: only read/create/update App IDs. No provisioning profile is fetched here.
        for (originalBundleID, mappedBundleID) in mappings.sorted(by: { $0.key < $1.key }) {
            do {
                try Task.checkCancellation()
                var appID: ALTAppID
                if let found = existing.first(where: {
                    ApplePortalAppIDResolver.matches(
                        existingBundleIdentifier: $0.bundleIdentifier,
                        requestedBundleIdentifier: mappedBundleID
                    )
                }) {
                    appID = found
                } else {
                    do {
                        let createdBox: LegacyBox<ALTAppID> =
                            try await withCheckedThrowingContinuation { continuation in
                                // App ID 名称必须是 ASCII，Apple 不允许中文等非 ASCII 字符（错误码 3009）
                                // 官方 AltStore 用 Bundle ID 作为 App ID 名称，保证 ASCII 且唯一
                                let appIDName = String(mappedBundleID.prefix(50))
                                ALTAppleAPI.shared.addAppID(
                                    withName: appIDName,
                                    bundleIdentifier: mappedBundleID,
                                    team: team,
                                    session: session
                                ) { created, error in
                                    Self.resume(continuation, value: created, error: error)
                                }
                            }
                        appID = createdBox.value
                    } catch ALTAppleAPIError.bundleIdentifierUnavailable {
                        let refreshed = try await fetchAppIDs(team: team, session: session)
                        guard let found = refreshed.first(where: {
                            ApplePortalAppIDResolver.matches(
                                existingBundleIdentifier: $0.bundleIdentifier,
                                requestedBundleIdentifier: mappedBundleID
                            )
                        }) else {
                            throw ALTAppleAPIError(.bundleIdentifierUnavailable)
                        }
                        appID = found
                    }
                    existing.append(appID)
                }

                if let application = applications[originalBundleID] {
                    let entitlementSource = filteredAppIDEntitlements(from: application, team: team)
                    var entitlementValues: [String: ProvisioningEntitlementValue] = [:]
                    for (entitlement, value) in entitlementSource {
                        guard let converted = ProvisioningEntitlementValue.make(from: value) else {
                            throw Self.failure(
                                title: "应用权限无法解析",
                                reason: "\(mappedBundleID) 的权限 \(entitlement.rawValue) 包含无法校验的值类型。",
                                recovery: "检查 IPA 权限或使用支持该能力的账号",
                                code: "SEAL-ENTITLEMENT-403"
                            )
                        }
                        entitlementValues[entitlement.rawValue] = converted
                    }
                    requestedEntitlements[mappedBundleID] = entitlementValues
                    // 扩展 features 更新失败时降级为空 features 重试，主 App 失败则直接报错
                    do {
                        appID = try await updateFeatures(
                            appID: appID,
                            application: application,
                            team: team,
                            session: session
                        )
                        if team.type != .free {
                            try await assignAppGroups(
                                appID: appID,
                                application: application,
                                team: team,
                                session: session
                            )
                        }
                    } catch where mappedBundleID != mappedMainBundleID {
                        // 扩展降级：清空 features，用空 entitlements 继续签名
                        requestedEntitlements[mappedBundleID] = [:]
                    }
                }
                preparedAppIDs.append((originalBundleID, mappedBundleID, appID))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard mappedBundleID != mappedMainBundleID else { throw error }
                guard allowDroppingExtensions else {
                    throw Self.failure(
                        title: "签名失败",
                        reason: "Apple 返回：扩展无法创建 App ID",
                        recovery: "移除扩展后重试",
                        code: "SEAL-EXT-401"
                    )
                }
                try signingWorkspace.removeExtension(
                    mappedBundleIdentifier: mappedBundleID,
                    from: workspace
                )
                requestedEntitlements.removeValue(forKey: mappedBundleID)
                droppedExtensionBundleIdentifiers.append(originalBundleID)
            }
        }

        // Phase 2: App IDs are settled; now fetch/generate real provisioning profiles.
        await progress(.preparingProfiles)
        var profiles: [ALTProvisioningProfile] = []
        for preparedAppID in preparedAppIDs {
            do {
                try Task.checkCancellation()
                let profile = try await fetchProvisioningProfile(
                    for: preparedAppID.appID,
                    team: team,
                    session: session
                )
                profiles.append(profile)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as ImportFailure {
                if preparedAppID.mapped == mappedMainBundleID { throw failure }
                guard allowDroppingExtensions else { throw failure }
                try signingWorkspace.removeExtension(
                    mappedBundleIdentifier: preparedAppID.mapped,
                    from: workspace
                )
                requestedEntitlements.removeValue(forKey: preparedAppID.mapped)
                droppedExtensionBundleIdentifiers.append(preparedAppID.original)
            } catch {
                if preparedAppID.mapped == mappedMainBundleID {
                    throw ApplePortalSigningFailure.make(
                        stage: .provisioningProfile,
                        error: error
                    )
                }
                guard allowDroppingExtensions else {
                    throw Self.failure(
                        title: "签名失败",
                        reason: "Apple 返回：扩展无法生成描述文件",
                        recovery: "移除扩展后重试",
                        code: "SEAL-EXT-401a"
                    )
                }
                try signingWorkspace.removeExtension(
                    mappedBundleIdentifier: preparedAppID.mapped,
                    from: workspace
                )
                requestedEntitlements.removeValue(forKey: preparedAppID.mapped)
                droppedExtensionBundleIdentifiers.append(preparedAppID.original)
            }
        }

        return ProfilePreparation(
            profiles: profiles,
            requestedEntitlements: requestedEntitlements,
            droppedExtensionBundleIdentifiers: Array(Set(droppedExtensionBundleIdentifiers))
        )
    }

    private func fetchAppIDs(
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> [ALTAppID] {
        let box: LegacyBox<[ALTAppID]> = try await withCheckedThrowingContinuation {
            continuation in
            ALTAppleAPI.shared.fetchAppIDs(for: team, session: session) { appIDs, error in
                Self.resume(continuation, value: appIDs, error: error)
            }
        }
        return box.value
    }

    private func fetchProvisioningProfile(
        for appID: ALTAppID,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTProvisioningProfile {
        let box: LegacyBox<ALTProvisioningProfile> = try await withCheckedThrowingContinuation {
            continuation in
            ALTAppleAPI.shared.fetchProvisioningProfile(
                for: appID,
                deviceType: .iphone,
                team: team,
                session: session
            ) { profile, error in
                Self.resume(continuation, value: profile, error: error)
            }
        }
        return box.value
    }


    private func updateFeatures(
        appID: ALTAppID,
        application: ALTApplication,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTAppID {
        let filteredEntitlements = filteredAppIDEntitlements(
            from: application,
            team: team
        )
        var features: [ALTFeature: Any] = [:]
        for (entitlement, value) in filteredEntitlements {
            if let feature = ALTFeature(entitlement: entitlement) {
                features[feature] = value
            }
        }
        if team.type != .free,
           let groups = filteredEntitlements[.appGroups] as? [String],
           groups.isEmpty == false {
            features[.appGroups] = true
        }

        // If there is nothing Apple needs to toggle, keep the existing App ID as-is.
        // This avoids sending empty or signer-managed entitlement payloads that Apple
        // rejects as "provided parameters are invalid" for free accounts.
        guard features.isEmpty == false || filteredEntitlements.isEmpty == false else {
            return appID
        }

        guard let updated = appID.copy() as? ALTAppID else {
            throw Self.failure(
                title: "无法签名",
                reason: "应用能力更新失败",
                recovery: "检查网络后重试；如持续失败请重新导入 IPA",                code: "SEAL-PROFILE-304"
            )
        }
        updated.features = features
        updated.entitlements = filteredEntitlements
        do {
            return try await submitUpdatedAppID(updated, team: team, session: session)
        } catch {
            guard Self.isInvalidAppIDParameterError(error),
                  team.type == .free,
                  let fallback = appID.copy() as? ALTAppID else {
                throw error
            }
            fallback.features = [:]
            fallback.entitlements = [:]
            return try await submitUpdatedAppID(fallback, team: team, session: session)
        }
    }

    private func filteredAppIDEntitlements(
        from application: ALTApplication,
        team: ALTTeam
    ) -> [ALTEntitlement: Any] {
        let signerManagedEntitlements: Set<String> = [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "get-task-allow"
        ]
        var filtered: [ALTEntitlement: Any] = [:]
        for (entitlement, value) in application.entitlements {
            if signerManagedEntitlements.contains(entitlement.rawValue) {
                continue
            }
            if team.type == .free,
               ALTFreeDeveloperCanUseEntitlement(entitlement) == false {
                continue
            }
            if team.type == .free, entitlement == .appGroups {
                continue
            }
            filtered[entitlement] = value
        }
        return filtered
    }

    private func submitUpdatedAppID(
        _ updated: ALTAppID,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTAppID {
        let box: LegacyBox<ALTAppID> = try await withCheckedThrowingContinuation {
            continuation in
            ALTAppleAPI.shared.update(
                updated,
                team: team,
                session: session
            ) { appID, error in
                Self.resume(continuation, value: appID, error: error)
            }
        }
        return box.value
    }

    private static func isInvalidAppIDParameterError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let normalized = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription) \(String(describing: error))".lowercased()
        return nsError.code == 3001
            || normalized.contains("3001")
            || normalized.contains("provided parameters are invalid")
    }

    private func assignAppGroups(
        appID: ALTAppID,
        application: ALTApplication,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws {
        guard let originalGroups = application.entitlements[.appGroups] as? [String],
              originalGroups.isEmpty == false else { return }
        let mappedIdentifiers = originalGroups.map {
            signingWorkspace.bundleIDMapper.appGroupID(
                original: $0,
                teamID: team.identifier
            )
        }
        let fetchedBox: LegacyBox<[ALTAppGroup]> =
            try await withCheckedThrowingContinuation { continuation in
                ALTAppleAPI.shared.fetchAppGroups(for: team, session: session) {
                    groups, error in
                    Self.resume(continuation, value: groups, error: error)
                }
            }
        var available = fetchedBox.value
        var assigned: [ALTAppGroup] = []
        for identifier in mappedIdentifiers {
            try Task.checkCancellation()
            if let existing = available.first(where: {
                $0.groupIdentifier == identifier
            }) {
                assigned.append(existing)
                continue
            }
            let suffix = identifier.split(separator: ".").last.map(String.init) ?? "Group"
            let createdBox: LegacyBox<ALTAppGroup> =
                try await withCheckedThrowingContinuation { continuation in
                    ALTAppleAPI.shared.addAppGroup(
                        withName: "Seal Group \(suffix)",
                        groupIdentifier: identifier,
                        team: team,
                        session: session
                    ) { group, error in
                        Self.resume(continuation, value: group, error: error)
                    }
                }
            available.append(createdBox.value)
            assigned.append(createdBox.value)
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            ALTAppleAPI.shared.assign(
                appID,
                to: assigned,
                team: team,
                session: session
            ) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? URLError(.badServerResponse)
                    )
                }
            }
        }
    }

    private func validateEmbeddedProfiles(
        in workspace: PreparedSigningWorkspace,
        teamID: String,
        certificateSerialNumber: String,
        deviceIdentifier: String,
        requestedEntitlements: [String: [String: ProvisioningEntitlementValue]]
    ) throws -> [String: ProvisioningProfileBinding] {
        let reader = ProvisioningProfileReader()
        var bindings: [String: ProvisioningProfileBinding] = [:]

        for target in try signingWorkspace.signedBundleTargets(in: workspace) {
            let profileURL = target.bundleURL.appending(path: "embedded.mobileprovision")
            guard FileManager.default.fileExists(atPath: profileURL.path) else {
                throw Self.failure(
                    title: "描述文件校验失败",
                    reason: "\(target.bundleIdentifier) 没有 embedded.mobileprovision。主应用和每个扩展都必须独立包含正确的描述文件。",
                    recovery: "重新获取描述文件",
                    code: "SEAL-PROFILE-318"
                )
            }
            let data = try Data(contentsOf: profileURL)
            let binding = try reader.binding(from: data)
                .validated(
                    expectedTeamID: teamID,
                    expectedBundleID: target.bundleIdentifier,
                    expectedCertificateSerialNumber: certificateSerialNumber,
                    expectedDeviceIdentifier: deviceIdentifier
                )
            try ProvisioningProfileBinding.validateEntitlements(
                requested: requestedEntitlements[target.bundleIdentifier] ?? [:],
                profile: binding.entitlements,
                bundleIdentifier: target.bundleIdentifier
            )
            bindings[target.bundleIdentifier] = binding
        }
        return bindings
    }

    private func signApp(
        at appURL: URL,
        team: ALTTeam,
        certificate: ALTCertificate,
        profiles: [ALTProvisioningProfile]
    ) async throws {
        let signer = ALTSigner(team: team, certificate: certificate)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            _ = signer.signApp(at: appURL, provisioningProfiles: profiles) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? URLError(.cannotCreateFile)
                    )
                }
            }
        }
    }

    private static func resume<Value>(
        _ continuation: CheckedContinuation<LegacyBox<Value>, any Error>,
        value: Value?,
        error: Error?
    ) {
        if let value {
            continuation.resume(returning: LegacyBox(value))
        } else {
            continuation.resume(throwing: error ?? URLError(.badServerResponse))
        }
    }

    private static func failure(
        title: String,
        reason: String,
        recovery: String,
        code: String
    ) -> ImportFailure {
        ImportFailure(title: title, reason: reason, recovery: recovery, code: code)
    }
}

private struct SigningIdentity {
    let certificate: ALTCertificate
    let secret: AccountSecret
}

private struct ProfilePreparation {
    let profiles: [ALTProvisioningProfile]
    let requestedEntitlements: [String: [String: ProvisioningEntitlementValue]]
    let droppedExtensionBundleIdentifiers: [String]
}

private actor SigningSecretState {
    private var secret: AccountSecret

    init(_ secret: AccountSecret) {
        self.secret = secret
    }

    func update(_ secret: AccountSecret) {
        self.secret = secret
    }

    func value() -> AccountSecret {
        secret
    }
}

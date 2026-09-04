import Foundation
import Testing
@testable import Seal

/// 覆盖“拿不到设备标识”时的根因分类与用户引导，确保不同底层错误不再被统一吞成
/// “请确认 Wi-Fi/LocalDevVPN”，而是区分配对未认可 / 握手失败 / 隧道不可达。
struct InstallChannelDiagnosticClassificationTests {
    typealias Channel = MinimuxerInstallChannel

    @Test
    func classifiesPairVerifyRejectionAsUntrusted() {
        #expect(
            Channel.classifyDiscoveryFailure(
                "minimuxer (15): UnknownErrorType(\"PairVerifyFailed\")"
            ) == .pairingNotTrusted
        )
        #expect(
            Channel.classifyDiscoveryFailure("RemotePairingError::UserDeniedPairing")
                == .pairingNotTrusted
        )
        #expect(
            Channel.classifyDiscoveryFailure("pairingRejectedWithError wrapped")
                == .pairingNotTrusted
        )
    }

    @Test
    func classifiesTlsAndRsdAsHandshake() {
        #expect(Channel.classifyDiscoveryFailure("TLS-PSK handshake failed") == .handshake)
        #expect(Channel.classifyDiscoveryFailure("RsdHandshake through tunnel failed") == .handshake)
    }

    @Test
    func classifiesSocketAndTimeoutAsTunnel() {
        #expect(Channel.classifyDiscoveryFailure("Socket: connection refused") == .tunnel)
        #expect(Channel.classifyDiscoveryFailure("operation timed out") == .tunnel)
        #expect(Channel.classifyDiscoveryFailure("network is unreachable") == .tunnel)
    }

    @Test
    func unknownDetailFallsThroughToUnknown() {
        #expect(Channel.classifyDiscoveryFailure("something completely different") == .unknown)
    }

    @Test
    func untrustedPairingProducesDedicatedRepairGuidance() {
        let failure = Channel.discoveryFailure(
            tunnelReachable: true,
            detail: "UnknownErrorType(\"PairVerifyFailed\")"
        )
        #expect(failure.code == "SEAL-PAIR-211")
        #expect(failure.reason.contains("配对助手"))
        #expect(failure.reason.contains("PairVerifyFailed"))
    }

    @Test
    func unreachableTunnelKeepsVpnGuidance() {
        let failure = Channel.discoveryFailure(tunnelReachable: false, detail: nil)
        #expect(failure.code == "SEAL-INSTALL-701")
    }

    @Test
    func reachableUnknownFailureKeepsNotRespondingCodeAndSurfacesDetail() {
        let failure = Channel.discoveryFailure(
            tunnelReachable: true,
            detail: "minimuxer (-1): weird internal state"
        )
        #expect(failure.code == "SEAL-INSTALL-708")
        #expect(failure.reason.contains("底层返回"))
        #expect(failure.reason.contains("weird internal state"))
    }
}

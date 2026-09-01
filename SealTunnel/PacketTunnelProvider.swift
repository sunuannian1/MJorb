import Darwin
import Foundation
@preconcurrency import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum Key {
        static let deviceAddress = "TunnelDeviceIP"
        static let reflectedAddress = "TunnelFakeIP"
        static let subnetMask = "TunnelSubnetMask"
    }

    private var deviceAddress = "10.7.0.0"
    private var reflectedAddress = "10.7.0.1"
    private var subnetMask = "255.255.255.0"

    private var deviceValue: UInt32 = 0
    private var reflectedValue: UInt32 = 0
    private var isRunning = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let persisted = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        deviceAddress = stringValue(
            key: Key.deviceAddress,
            options: options,
            persisted: persisted
        ) ?? deviceAddress
        reflectedAddress = stringValue(
            key: Key.reflectedAddress,
            options: options,
            persisted: persisted
        ) ?? reflectedAddress
        subnetMask = stringValue(
            key: Key.subnetMask,
            options: options,
            persisted: persisted
        ) ?? subnetMask

        guard let parsedDevice = Self.ipv4Value(deviceAddress),
              let parsedReflected = Self.ipv4Value(reflectedAddress) else {
            completionHandler(
                NSError(
                    domain: "com.mjorb.seal.tunnel",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Seal Tunnel IPv4 configuration is invalid"
                    ]
                )
            )
            return
        }

        deviceValue = parsedDevice
        reflectedValue = parsedReflected

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: deviceAddress)
        let ipv4 = NEIPv4Settings(
            addresses: [deviceAddress],
            subnetMasks: [subnetMask]
        )
        ipv4.includedRoutes = [
            NEIPv4Route(
                destinationAddress: deviceAddress,
                subnetMask: subnetMask
            )
        ]
        // 不设置 excludedRoutes：部分隧道只需 includedRoutes 指定 10.7.0.0/24 进隧道，
        // 其余流量自然走物理接口。excludedRoutes=[.default()] 在纯蜂窝下会干扰默认路由
        // 回物理蜂窝接口，导致外网（添加 Apple ID / 签名请求）被黑洞。
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            guard error == nil else {
                completionHandler(error)
                return
            }

            self.isRunning = true
            self.readNextPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        isRunning = false
        setTunnelNetworkSettings(nil) { _ in
            completionHandler()
        }
    }

    private func readNextPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isRunning else { return }

            var reflectedPackets = packets
            for index in reflectedPackets.indices {
                guard protocols.indices.contains(index),
                      protocols[index].int32Value == AF_INET else {
                    continue
                }
                self.reflectIPv4Packet(&reflectedPackets[index])
            }

            self.packetFlow.writePackets(
                reflectedPackets,
                withProtocols: protocols
            )
            self.readNextPackets()
        }
    }

    private func reflectIPv4Packet(_ packet: inout Data) {
        guard packet.count >= 20 else { return }

        let start = packet.startIndex
        guard packet[start] >> 4 == 4 else { return }

        let source = Self.readUInt32(packet, offset: 12)
        let destination = Self.readUInt32(packet, offset: 16)

        if source == deviceValue && destination == reflectedValue {
            Self.writeUInt32(reflectedValue, into: &packet, offset: 12)
            Self.writeUInt32(deviceValue, into: &packet, offset: 16)
        } else if source == reflectedValue && destination == deviceValue {
            Self.writeUInt32(deviceValue, into: &packet, offset: 12)
            Self.writeUInt32(reflectedValue, into: &packet, offset: 16)
        }
    }

    private func stringValue(
        key: String,
        options: [String: NSObject]?,
        persisted: [String: Any]?
    ) -> String? {
        if let value = options?[key] as? String {
            return value
        }
        return persisted?[key] as? String
    }

    private static func ipv4Value(_ address: String) -> UInt32? {
        let components = address.split(separator: ".")
        guard components.count == 4 else { return nil }

        var result: UInt32 = 0
        for component in components {
            guard let byte = UInt32(component), byte <= 255 else { return nil }
            result = (result << 8) | byte
        }
        return result
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let index = data.startIndex + offset
        return (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
    }

    private static func writeUInt32(
        _ value: UInt32,
        into data: inout Data,
        offset: Int
    ) {
        let index = data.startIndex + offset
        data[index] = UInt8((value >> 24) & 0xFF)
        data[index + 1] = UInt8((value >> 16) & 0xFF)
        data[index + 2] = UInt8((value >> 8) & 0xFF)
        data[index + 3] = UInt8(value & 0xFF)
    }
}

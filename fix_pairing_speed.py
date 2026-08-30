fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Infrastructure\Installation\MinimuxerInstallChannel.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

old = """            run(.minimuxer)
            do {
                let pairing = try await pairingStore.contents()
                try Minimuxer.start(pairingFile: pairing, logPath: logDirectory.path)
            } catch {
                return fail(.minimuxer, Self.connectionFailure(error))
            }
            await waitForNetworkRefresh(rounds: 40, delay: .milliseconds(500))
            guard let udid = try await readyDeviceIdentifier() else {
                if tunnelReachable == false {
                    return fail(.vpnTunnel, Self.vpnTunnelUnavailableFailure)
                }
                return fail(.deviceIdentifier, Self.deviceNotRespondingFailure)
            }"""

new = """            run(.minimuxer)
            do {
                let pairing = try await pairingStore.contents()
                try Minimuxer.start(pairingFile: pairing, logPath: logDirectory.path)
            } catch {
                return fail(.minimuxer, Self.connectionFailure(error))
            }
            // 优化：轮询检查设备，成功即退出，最多等待 20 秒
            var resolvedUDID: String?
            for _ in 0..<40 {
                NetworkObserver.shared.refreshEndpoint()
                resolvedUDID = try await readyDeviceIdentifier()
                if resolvedUDID != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let udid = resolvedUDID else {
                if tunnelReachable == false {
                    return fail(.vpnTunnel, Self.vpnTunnelUnavailableFailure)
                }
                return fail(.deviceIdentifier, Self.deviceNotRespondingFailure)
            }"""

if old in content:
    content = content.replace(old, new)
    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(content)
    print("Done!")
else:
    print("ERROR: old string not found")

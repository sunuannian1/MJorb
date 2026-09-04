import Testing
@testable import Seal

@MainActor
struct VerificationCodeBrokerTests {
    @Test
    func submitCodeCompletesRequestAndMarksSubmission() async {
        let broker = VerificationCodeBroker()

        let task = Task { @MainActor in
            await broker.request()
        }
        await waitUntilRequested(broker)

        #expect(broker.isRequested)
        broker.submit("12 34 56")

        let code = await task.value
        #expect(code == "123456")
        #expect(broker.isRequested == false)
        #expect(broker.hasSubmittedCode)
    }

    @Test
    func cancelResetsPendingAndSubmittedState() async {
        let broker = VerificationCodeBroker()

        let task = Task { @MainActor in
            await broker.request()
        }
        await waitUntilRequested(broker)
        broker.cancel()

        let code = await task.value
        #expect(code == nil)
        #expect(broker.isRequested == false)
        #expect(broker.hasSubmittedCode == false)
    }

    @Test
    func nonInteractiveRequestReturnsNilWithoutPrompting() async {
        let broker = VerificationCodeBroker()
        broker.setInteractivePromptAllowed(false)

        // 后台批量续签场景：不弹窗、不挂起，立即放弃 2FA。
        let code = await broker.request()

        #expect(code == nil)
        #expect(broker.isRequested == false)
        #expect(broker.hasSubmittedCode == false)
        #expect(broker.isInteractivePromptAllowed == false)
    }

    @Test
    func disablingInteractionCancelsPendingRequestAndCanBeReenabled() async {
        let broker = VerificationCodeBroker()

        let task = Task { @MainActor in
            await broker.request()
        }
        await waitUntilRequested(broker)
        #expect(broker.isRequested)

        // 续签开始时关闭交互，应取消正在等待的请求而不是悬挂。
        broker.setInteractivePromptAllowed(false)
        let code = await task.value
        #expect(code == nil)
        #expect(broker.isRequested == false)

        // 续签结束后恢复，用户主动签名的 2FA 输入必须照常工作。
        broker.setInteractivePromptAllowed(true)
        #expect(broker.isInteractivePromptAllowed)
        let interactiveTask = Task { @MainActor in
            await broker.request()
        }
        await waitUntilRequested(broker)
        #expect(broker.isRequested)
        broker.cancel()
        _ = await interactiveTask.value
    }

    private func waitUntilRequested(_ broker: VerificationCodeBroker) async {
        for _ in 0..<10 where broker.isRequested == false {
            await Task.yield()
        }
    }
}

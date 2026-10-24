import Foundation

@main struct BroadcastPauseTests {
    static func main() {
        let failure = "模型返回后：规划期间画面已变化；已用完两次重新观察。"
        let failed = PauseFixture()
        failed.paused = true
        failed.store.status = PauseStatus(phase: "暂停", detail: failure)
        failed.broadcastPaused(); failed.drain()
        precondition(failed.store.status.detail == failure && failed.captureState == "paused")
        precondition(failed.work!.cancellations == 1 && failed.hardwareStops == 1)
        failed.broadcastResumed(); failed.drain()
        precondition(failed.paused && failed.store.status.detail == failure)
        precondition(failed.work!.cancellations == 2 && failed.hardwareStops == 2)

        let interrupted = PauseFixture()
        interrupted.broadcastPaused(); interrupted.drain()
        let original = interrupted.store.status.detail
        precondition(interrupted.paused && original.hasPrefix("系统广播暂停"))
        interrupted.broadcastResumed(); interrupted.drain()
        precondition(interrupted.paused && interrupted.store.status.detail == original)

        let continued = PauseFixture()
        continued.config.continuedProcessingEnabled = true
        continued.store.status = PauseStatus(phase: "暂停", detail: failure)
        continued.broadcastPaused(); continued.drain()
        precondition(continued.finishReason == failure && continued.finishPhase == "暂停")
        precondition(continued.hardwareStops == 1 && continued.work!.cancellations > 0)

        let continuedResume = PauseFixture()
        continuedResume.config.continuedProcessingEnabled = true
        continuedResume.store.status = PauseStatus(phase: "暂停", detail: failure)
        continuedResume.broadcastResumed(); continuedResume.drain()
        precondition(continuedResume.paused && continuedResume.store.status.detail == failure)
        precondition(continuedResume.captureState == "paused" && continuedResume.hardwareStops == 1)

        let finished = PauseFixture()
        finished.stopped = true; finished.captureState = "stopped"
        finished.store.status = PauseStatus(phase: "完成", detail: "已从新画面确认结果")
        finished.broadcastPaused(); finished.broadcastResumed(); finished.drain()
        precondition(finished.captureState == "stopped" && finished.store.status.phase == "完成")
        precondition(finished.hardwareStops == 0 && finished.work!.cancellations == 0)
        print("PASS: production pause/resume callbacks preserve the first failure, keep STOP/cancellation, retain continued terminal reason, and ignore finished-session callbacks; no HID")
    }
}

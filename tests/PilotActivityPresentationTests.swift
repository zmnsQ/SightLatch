import Foundation

@main
struct PilotActivityPresentationTests {
    static func main() {
        let cases: [(String, PilotActivityStage)] = [
            ("待广播", .ready), ("观察", .observing), ("规划", .planning),
            ("执行", .executing), ("暂停", .needsInput), ("需输入", .needsInput),
            ("停止未确认，请急停", .failed), ("请核实硬件停止", .failed),
            ("完成", .completed), ("硬件已解除ARM", .stopped), ("停止", .stopped),
            ("https://private.example/secret?token=abc", .unknown)
        ]
        for (phase, expected) in cases {
            let stage = PilotActivityStage(phase: phase)
            precondition(stage == expected, "Unexpected classification: \(phase)")
            precondition(!stage.title.isEmpty && !stage.symbol.isEmpty && !stage.summary.isEmpty)
            precondition(!stage.summary.contains("token=") && !stage.title.contains("private.example"))
        }
        precondition(!PilotActivityStage.needsInput.isTerminal)
        precondition(!PilotActivityStage.failed.isTerminal)
        precondition(PilotActivityStage.completed.isTerminal && PilotActivityStage.stopped.isTerminal)
        precondition(!PilotActivityStage.executing.needsAttention)
        precondition(PilotActivityStage.needsInput.needsAttention)
        print("PASS: 12 phase mappings, safe summaries, terminal and alert classification")
    }
}

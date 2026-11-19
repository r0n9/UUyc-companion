import CoreGraphics
import Foundation

// 验证实际事务封装的错误传递与取消行为，不访问 WindowServer。
private enum TransactionSimulation {
    static var begin = CGError.success
    static var complete = CGError.success
    static var commits = 0
    static var cancellations = 0
}

func CGBeginDisplayConfiguration(_ configuration: UnsafeMutablePointer<CGDisplayConfigRef?>?) -> CGError {
    TransactionSimulation.begin
}

func CGCompleteDisplayConfiguration(_ configuration: CGDisplayConfigRef?, _ option: CGConfigureOption) -> CGError {
    TransactionSimulation.commits += 1
    return TransactionSimulation.complete
}

@discardableResult
func CGCancelDisplayConfiguration(_ configuration: CGDisplayConfigRef?) -> CGError {
    TransactionSimulation.cancellations += 1
    return .success
}

enum Log { static func info(_ message: String) {} }

@main struct DisplayConfigurationTests {
    static func main() {
        for error in [CGError.cannotComplete, CGError(rawValue: 1014)!] {
            TransactionSimulation.begin = error
            let result = applyDisplayConfig { _ in
                preconditionFailure("Configured after begin failed")
            }
            precondition(result == error)
        }
        precondition(TransactionSimulation.commits == 0 && TransactionSimulation.cancellations == 0)
        TransactionSimulation.begin = .success
        precondition(applyDisplayConfig { _ in .illegalArgument } == .illegalArgument)
        precondition(TransactionSimulation.commits == 0 && TransactionSimulation.cancellations == 1)
        TransactionSimulation.complete = CGError(rawValue: 1014)!
        precondition(applyDisplayConfig { _ in .success } == TransactionSimulation.complete)
        precondition(TransactionSimulation.commits == 1 && TransactionSimulation.cancellations == 2)
        TransactionSimulation.complete = .success
        precondition(applyDisplayConfig { _ in .success } == .success)
        precondition(TransactionSimulation.commits == 2 && TransactionSimulation.cancellations == 2)
        print("PASS: display transactions preserve begin/configure/commit errors and cancel only failed transactions")
    }
}

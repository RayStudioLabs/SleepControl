import Foundation
import Darwin

@main
enum SleepControlMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        let store = AIProtectionStore()
        do {
            if arguments.count == 3, arguments[1] == "--ai-event" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard data.count < 8 * 1024 * 1024,
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AIProtectionError.invalidEvent
                }
                let event = try AIEvent(source: arguments[2], payload: payload)
                try AIProtectionEngine(store: store).receive(event, ownerPID: AIProcess.owner(source: event.source))
                if (try store.snapshot()).protecting { try AIGuard.start(store: store) }
                // Stop/SubagentStop 必须返回 JSON；其他事件也接受空对象。
                FileHandle.standardOutput.write(Data("{}\n".utf8))
                return
            }
            if arguments.count == 2, arguments[1] == "--ai-guard" {
                try AIGuard.run(store: store)
                return
            }
            SleepControlApp.main()
        } catch {
            FileHandle.standardError.write(Data(("SleepControl: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}

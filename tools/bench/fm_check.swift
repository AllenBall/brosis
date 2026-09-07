import Foundation
import FoundationModels

@main
struct Probe {
    static func main() async {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            print("FoundationModels: AVAILABLE")
            let session = LanguageModelSession(instructions: "You classify short activity descriptions into one of: coding, writing, browsing, communication, media, other. Reply with just the label.")
            let t0 = Date()
            do {
                let resp = try await session.respond(to: "Editing main.swift in Xcode, window title 'brosis — main.swift'")
                print("response:", resp.content, "| latency(s):", String(format: "%.2f", Date().timeIntervalSince(t0)))
            } catch { print("respond error:", error) }
        case .unavailable(let reason):
            print("FoundationModels: UNAVAILABLE reason=\(reason)")
        }
    }
}

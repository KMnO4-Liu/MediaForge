import Foundation
import SwiftUI
import Darwin

/// Diagnostic mode exercises the very same engine discovery and queue model as
/// the GUI, without modifying the user's settings or requiring GUI automation.
@main
@MainActor
struct MediaForgeEntry {
    static func main() async {
        if CommandLine.arguments.contains("--self-check") {
            do {
                let report = try await AppSelfCheck.run()
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("SELF-CHECK FAILED: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        MediaForgeApp.main()
    }
}

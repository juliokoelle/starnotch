import AppKit
import NotchCore
import SwiftUI

/// Previews of the command palette and the agents inbox, with the made-up sessions and loops of
/// `PreviewDirector.snapshot`:
///
///     --preview palette                  the palette, no query
///     --preview palette:<query>          typed, e.g. palette:rate
///     --preview palette-approval         a prompt arrives while typing: the palette stays; the prompt shows once it closes (after 3 s)
///     --preview inbox                    a Claude Code prompt in front, a question, a finished turn, a failed loop
///     --preview inbox:arrival            opens on the failed loop; the prompt and the question arrive behind it
///     --preview inbox:question           an MCP question with options in front
///     --preview inbox:blocked            a session the Claude app says needs you, in front
///     --preview inbox:skipped            the only prompt skipped: it still waits
///     --preview inbox:done | inbox:loop  a finished turn, or a failed loop alone
///     --preview inbox:empty              nothing needs you
///     --preview inbox:ears | inbox:peek  the count beside the closed notch, or in the hover peek
extension PreviewDirector {
    func runCommand(_ name: String) {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let variant = parts.count > 1 ? parts[1] : ""
        agents.cast.previewCharacter = "astra"
        var snapshot = Self.snapshot(agentsActive: true)
        switch variant {
        case "loop": snapshot.agents.removeAll { !$0.isBusy }
        case "done": snapshot.loops.removeAll { $0.last?.status == .fail }
        case "empty", "skipped":
            snapshot.agents.removeAll { !$0.isBusy }
            snapshot.loops.removeAll { $0.last?.status == .fail }
        case "blocked":
            if let index = snapshot.agents.firstIndex(where: { $0.id == "preview-notes" }) {
                snapshot.agents[index].needsYou = "Allow access to the Figma connector?"
                snapshot.agents[index].since = Date().addingTimeInterval(-4 * 60)
            }
        default: break
        }
        agents.usePreview(snapshot)
        agents.previewPlan = StatusSnapshot(
            sessionID: "preview", fiveHour: .init(usedPercentage: 62, resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
            sevenDay: .init(usedPercentage: 48, resetsAt: Date().addingTimeInterval(4 * 86_400)), capturedAt: Date())
        Task {
            try? await Task.sleep(for: .seconds(1))
            if parts[0] == "palette" {
                notch.openPalette()
                guard !variant.isEmpty, let palette = notch.model.palette else { return }
                try? await Task.sleep(for: .milliseconds(400))
                for end in variant.indices {
                    palette.query = String(variant[...end])
                    try? await Task.sleep(for: .milliseconds(60))
                }
                return
            }
            if parts[0] == "palette-approval" {
                notch.openPalette(query: "rate")
                try? await Task.sleep(for: .milliseconds(600))
                let json = #"{"session_id":"preview-main","cwd":"/Users/me/projects/notch","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}"#
                if let request = ApprovalRequest.parse(Data(json.utf8), id: "preview-palette") { notch.model.approvals?.preview(request) }
                try? await Task.sleep(for: .seconds(2.4))
                notch.collapse()
                return
            }
            switch variant {
            case "ears": return
            case "peek":
                notch.tourPeek()
                return
            default: break
            }
            let approval = #"{"session_id":"preview-main","cwd":"/Users/me/projects/notch","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin r4-design","description":"Push the branch"}}"#
            let question = #"{"starnotch_provider":"mcp","hook_event_name":"PermissionRequest","tool_name":"Cursor","tool_input":{"command":"Which database should the export use?"},"starnotch_options":["Postgres","SQLite","Decide later"]}"#
            let requests = switch variant {
            case "question": [question]
            case "", "arrival": [approval, question]
            case "skipped": [approval]
            default: [String]()
            }
            @MainActor func send() {
                for (index, json) in requests.enumerated() {
                    if let request = ApprovalRequest.parse(Data(json.utf8), id: "preview-\(index)") {
                        notch.model.approvals?.preview(request)
                    }
                }
            }
            // Arrival: they come in while the inbox shows something else, and queue behind it.
            if variant != "arrival" {
                send()
                try? await Task.sleep(for: .milliseconds(300))
            }
            notch.openInbox()
            try? await Task.sleep(for: .milliseconds(300))
            if variant == "arrival" { send() }
            if variant == "skipped" {
                try? await Task.sleep(for: .milliseconds(600))
                notch.model.inbox?.skip()
            }
        }
    }
}

import Foundation
import OsmoCore

/// The job-to-be-done for *this specific message* — richer than a keyboard app's
/// archetypes because Osmo reasons over full threads and goals (adds negotiate,
/// deescalate, persuade, scheduleTime). Inferred from the user's stated intent,
/// or from the thread when no intent is given.
public enum Move: String, Codable, Sendable, CaseIterable {
    case apologize
    case decline
    case comfort
    case deliverHardNews
    case flirt
    case nudge            // follow up on a dropped thread
    case celebrate
    case thank
    case checkIn
    case ask
    case negotiate
    case deescalate
    case persuade
    case scheduleTime
    case answer           // straightforwardly answer their question
    case smallTalk
    case plain

    public static func classify(_ text: String?) -> Move {
        guard let lower = text?.lowercased(), !lower.isEmpty else { return .plain }
        for (move, keys) in table {
            for k in keys where TextMatch.word(lower, k) { return move }
        }
        return .plain
    }

    // Priority-ordered.
    private static let table: [(Move, [String])] = [
        (.apologize, ["sorry", "apologize", "apologise", "apology", "my bad", "my fault",
                      "messed up", "screwed up", "forgive", "make it up"]),
        (.deescalate, ["calm", "de-escalate", "deescalate", "defuse", "not fight",
                       "lower the temperature", "smooth", "cool things"]),
        (.negotiate, ["negotiate", "counter", "push back", "counteroffer", "ask for more",
                      "lower the price", "better terms", "haggle"]),
        (.decline, ["say no", "decline", "turn down", "can't make it", "cant make it",
                    "back out", "rain check", "raincheck", "pass on", "reject", "not going to make"]),
        (.deliverHardNews, ["bad news", "break the news", "hard news", "breaking up",
                            "break up", "end things", "let them go", "have to tell", "come clean"]),
        (.comfort, ["comfort", "cheer up", "going through", "tough time", "hard time",
                    "condolence", "passed away", "lost their", "grieving", "console", "there for them"]),
        (.persuade, ["persuade", "convince", "get them to", "win them over", "sell them on",
                     "pitch", "make the case"]),
        (.scheduleTime, ["schedule", "set up a time", "find a time", "book", "calendar",
                         "when are you free", "grab time", "hop on a call"]),
        (.flirt, ["flirt", "flirty", "ask out", "cute", "tease", "smooth", "first date", "second date"]),
        (.nudge, ["follow up", "following up", "followup", "remind", "reminder", "nudge",
                  "haven't heard", "havent heard", "no response", "didn't reply", "bump", "chase"]),
        (.celebrate, ["congrat", "celebrate", "proud of", "got the job", "promotion",
                      "promoted", "passed", "graduated", "engaged", "big win"]),
        (.thank, ["thank", "thanks", "grateful", "gratitude", "appreciate"]),
        (.checkIn, ["check in", "checking in", "check on", "thinking of", "see how"]),
        (.scheduleTime, ["meet up", "get together", "plans"]),
        (.ask, ["ask", "favor", "favour", "borrow", "invite", "request", "need them to", "help me"]),
        (.answer, ["reply", "respond", "answer", "get back to"])
    ]
}

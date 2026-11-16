import ActivityKit
import Foundation

/// Live Activity attributes for a DSH agent background task. Shared by the
/// Runner target (ShellBoxPlugin starts / updates / ends it) and the
/// PetLiveActivity widget extension (DSHAgentLiveActivity renders it), exactly
/// like PetActivityAttributes. The extension cannot read the app's sandbox, so
/// everything the widget shows must be in these two fields.
@available(iOS 16.2, *)
struct DSHActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// Task title ("DSH agent" when privacy mode hides it).
    var title: String
    /// "running" | "completed" | "failed" | "expired".
    var status: String
    /// Short summary; nil when there is nothing to say or privacy mode hides it.
    var detail: String?
  }

  /// When the task started, for the widget's own timer.
  var startedAt: Date
}

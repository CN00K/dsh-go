import ActivityKit
import Foundation

/// Live Activity attributes for a DSH agent background task. Shared by the
/// Runner target and the PetLiveActivity widget extension
/// (DSHAgentLiveActivity renders it), exactly like PetActivityAttributes.
/// The extension cannot read the app's sandbox, so everything the widget
/// shows must be in these two fields.
///
/// PORT NOTE (D5c): feat's Runner-side starter was ShellBoxPlugin, which
/// 1.1.1 does not have; no fused caller starts a DSHActivityAttributes
/// activity yet (see NOTES.md). The widget is registered but dormant
/// until a starter is wired to ContinuedRun / the notify path.
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

import ActivityKit
import ImageIO
import OSLog
import SwiftUI
import UIKit
import WidgetKit

@main
struct PetLiveActivityBundle: WidgetBundle {
  var body: some Widget { PetLiveActivity(); DSHAgentLiveActivity() }
}

struct PetLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: PetActivityAttributes.self) { context in
      LockScreenCard(context: context)
        .activityBackgroundTint(Palette.background)
        .activitySystemActionForegroundColor(Palette.primary)
        .widgetURL(context.attributes.url)
    } dynamicIsland: { context in
      DynamicIsland {
        // The selected pet is the visual anchor. PetSprite keeps the exact
        // inline still from Dart ahead of the staged/bundled pack, so an
        // imported pet remains the same pet in the island too.
        DynamicIslandExpandedRegion(.leading) {
          PetIslandBadge(state: context.state, label: compactLabel(context))
            .padding(.leading, 2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .leading, spacing: 5) {
            Text("DSH GO")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Palette.secondary)
              .textCase(.uppercase)
              .tracking(0.4)
            HStack(spacing: 6) {
              Text(headline(context))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PhaseStyle.of(context.state.phase).tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
              CompactStatus(state: context.state, stale: context.isStale,
                label: compactLabel(context))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.trailing, 6)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 7) {
            PhaseGlyph(style: PhaseStyle.of(context.state.phase), size: 12)
            Text(detail(context))
              .font(.system(size: 12))
              .foregroundStyle(Palette.secondary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 8)
          .padding(.top, 1)
        }
      } compactLeading: {
        // The compact island still uses the selected pet, never a fixed emoji.
        PetSprite(state: context.state, label: compactLabel(context),
          bodyHeight: 12, maxHeight: 16, maxWidth: 20)
          .frame(width: 22, height: 20, alignment: .center)
      } compactTrailing: {
        CompactStatus(state: context.state, stale: context.isStale, label: compactLabel(context))
          .frame(width: 30, height: 20, alignment: .trailing)
          .clipped()
      } minimal: {
        // The one thing worth recognizing at a glance.
        MinimalPet(state: context.state, label: compactLabel(context))
          .frame(height: 20, alignment: .center)
      }
      .widgetURL(context.attributes.url)
      .keylineTint(PhaseStyle.of(context.state.phase).tint)
    }
  }

  private func compactLabel(_ context: ActivityViewContext<PetActivityAttributes>) -> String {
    context.isStale ? context.state.staleLabel : context.state.label
  }

  private func headline(_ context: ActivityViewContext<PetActivityAttributes>) -> String {
    context.isStale ? context.state.staleLabel : context.state.label
  }

  private func detail(_ context: ActivityViewContext<PetActivityAttributes>) -> String {
    if let detail = context.state.detail, !detail.isEmpty { return detail }
    return context.isStale ? context.state.staleLabel : context.state.label
  }
}

/// The lock screen's card: the pet, then the headline and one line of detail.
/// Same black surface and palette as the island, so the two read as one thing.
private struct LockScreenCard: View {
  let context: ActivityViewContext<PetActivityAttributes>

  private var text: String { context.isStale ? context.state.staleLabel : context.state.label }

  var body: some View {
    HStack(spacing: 14) {
      PetSprite(state: context.state, label: text, bodyHeight: 34, maxHeight: 44, maxWidth: 54)
        .frame(width: 52, alignment: .center)
      VStack(alignment: .leading, spacing: 3) {
        Text(text)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(PhaseStyle.of(context.state.phase).tint)
          .lineLimit(1)
        if let detail = context.state.detail {
          Text(detail)
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      PhaseGlyph(style: PhaseStyle.of(context.state.phase), size: 16)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }
}

// MARK: - Palette

/// The one palette of docs/design: a black surface, quiet greys, and colour
/// only where it tells waiting from working from done from failed.
private enum Palette {
  static let background = Color.black
  static let primary = Color(red: 0.961, green: 0.961, blue: 0.969)   // #F5F5F7
  static let secondary = Color(red: 0.596, green: 0.596, blue: 0.616) // #98989D
  static let active = Color(red: 0.725, green: 0.647, blue: 0.961)    // #B9A5F5
  static let success = Color(red: 0.525, green: 0.851, blue: 0.667)   // #86D9AA
  static let waiting = Color(red: 0.957, green: 0.733, blue: 0.471)   // #F4BB78
  static let failure = Color(red: 0.945, green: 0.549, blue: 0.569)   // #F18C91
}

/// What one phase looks like: its colour, and the single symbol (if any) that
/// belongs beside it. Idle and thinking carry no symbol — the pet says it.
private struct PhaseStyle {
  let tint: Color
  let symbol: String?

  static func of(_ phase: String) -> PhaseStyle {
    switch phase {
    case "thinking": return PhaseStyle(tint: Palette.secondary, symbol: nil)
    case "working", "continuedProcessing": return PhaseStyle(tint: Palette.active, symbol: nil)
    case "waitingApproval": return PhaseStyle(tint: Palette.waiting, symbol: "hand.raised.fill")
    case "authorizationEnded": return PhaseStyle(tint: Palette.waiting, symbol: "pause.circle.fill")
    case "waitingRecovery": return PhaseStyle(tint: Palette.waiting, symbol: "clock.badge.exclamationmark")
    case "completed": return PhaseStyle(tint: Palette.success, symbol: "checkmark.circle.fill")
    case "error": return PhaseStyle(tint: Palette.failure, symbol: "exclamationmark.triangle.fill")
    default: return PhaseStyle(tint: Palette.secondary, symbol: nil)
    }
  }
}

private struct PhaseGlyph: View {
  let style: PhaseStyle
  let size: CGFloat

  var body: some View {
    if let symbol = style.symbol {
      Image(systemName: symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(style.tint)
    }
  }
}

/// A quiet frame that gives the chosen pet the main visual weight without
/// masking its transparent action window. The art itself remains responsible
/// for its proportions, including imported pixel-art packs.
private struct PetIslandBadge: View {
  let state: PetActivityAttributes.ContentState
  let label: String

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(PhaseStyle.of(state.phase).tint.opacity(0.16))
      PetSprite(state: state, label: label, bodyHeight: 37, maxHeight: 47, maxWidth: 56)
    }
    .frame(width: 62, height: 54)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
  }
}

/// The island's trailing side: one thing only. A running task counts up; a
/// waiting turn shows its mark; a finished one its check. Nothing at all while
/// the pet idles, so the collapsed island stays quiet.
private struct CompactStatus: View {
  let state: PetActivityAttributes.ContentState
  let stale: Bool
  let label: String

  var body: some View {
    if stale {
      Image(systemName: "clock.badge.exclamationmark")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Palette.waiting)
        .accessibilityLabel(label)
    } else if state.phase == "working" || state.phase == "continuedProcessing" {
      if let start = self.start {
        timer(start)
      } else {
        Circle()
          .fill(Palette.active)
          .frame(width: 5, height: 5)
          .accessibilityLabel(label)
      }
    } else if state.phase == "thinking" {
      Image(systemName: "ellipsis")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Palette.secondary)
        .accessibilityLabel(label)
    } else {
      PhaseGlyph(style: PhaseStyle.of(state.phase), size: 15)
        .accessibilityLabel(label)
    }
  }

  private var start: Date? {
    guard let ms = state.since, ms > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
  }

  private func timer(_ start: Date) -> some View {
    Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)
      .font(.system(size: 10, weight: .medium))
      .monospacedDigit()
      .foregroundStyle(PhaseStyle.of(state.phase).tint)
      .lineLimit(1)
      // Date.distantFuture gives the live timer a stable update range, but it
      // also makes Text reserve space for a much wider value. Keep the compact
      // trailing region sized for the value that is actually shown.
      .frame(width: 30, alignment: .trailing)
      .clipped()
      .accessibilityLabel(label)
  }
}

/// Minimal: just the pet, at the largest size that still reads as the character.
private struct MinimalPet: View {
  let state: PetActivityAttributes.ContentState
  let label: String

  var body: some View {
    // The inline still already is this pose. Use its state unchanged so the
    // image and petState describe the same thing; only a pack without a still
    // falls back to idle art, where an old pose image must not survive.
    PetSprite(state: displayedState, label: label, bodyHeight: 14, maxHeight: 18, maxWidth: 22)
      .frame(width: 22, alignment: .center)
  }

  private var displayedState: PetActivityAttributes.ContentState {
    if state.art != nil { return state }
    return PetActivityAttributes.ContentState(packId: state.packId, phase: "idle",
      petState: "idle", tier: nil, detail: nil, completionSeed: nil, since: nil,
      label: label, staleLabel: label)
  }
}

// MARK: - The pet

/// The chosen pet, drawn from its own sheet: the cell the pack names as that
/// animation's representative frame, at the animation's own box, scaled by the
/// body the pack declares. One window per animation (the body plus the props
/// that animation draws), never one giant canvas for every state.
private struct PetSprite: View {
  let state: PetActivityAttributes.ContentState
  let label: String
  let bodyHeight: CGFloat
  let maxHeight: CGFloat
  let maxWidth: CGFloat?

  var body: some View {
    if let data = state.art, let image = UIImage(data: data),
       image.size.width > 0, image.size.height > 0,
       let ratio = state.artBodyRatio, ratio.isFinite, ratio > 0 {
      let displayedRatio = min(max(ratio, 0.25), 4)
      let height = min(bodyHeight * displayedRatio, maxHeight)
      let width = height * image.size.width / image.size.height
      let scale = maxWidth.map { min(1, $0 / width) } ?? 1
      Image(uiImage: image)
        .resizable()
        .interpolation(state.artPixelArt == true ? .none : .medium)
        .frame(width: width * scale, height: height * scale)
        .accessibilityLabel(label)
    } else if let art = PetArt.sprite(packId: state.packId, phase: state.phase,
      petState: state.petState, tier: state.tier, seed: state.completionSeed,
      bodyHeight: bodyHeight, maxHeight: maxHeight, maxWidth: maxWidth) {
      art.image
        .resizable()
        .interpolation(.none)
        .frame(width: art.draw.width, height: art.draw.height)
        .offset(x: art.offset.width, y: art.offset.height)
        .frame(width: art.frame.width, height: art.frame.height, alignment: .topLeading)
        .clipped()
        .accessibilityLabel(label)
    } else {
      // Only a missing or undecodable inline still plus no staged/bundled pack
      // reaches this fallback; the native reason is logged by PetArt.
      Text(Emoji.face(packId: state.packId, phase: state.phase))
        .font(.system(size: bodyHeight))
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .accessibilityLabel(label)
    }
  }
}

/// The pet's own still, in points: [draw] is the cropped cell placed at
/// [offset] inside a window of [frame].
struct PetArtwork {
  let image: Image
  let draw: CGSize
  let offset: CGSize
  let frame: CGSize
}

/// Reads what the app staged in the App Group (`PetArtStore`): the pack's
/// `pack.json` plus the sheets it names, exactly as the app draws them.
enum PetArt {
  private static let log = Logger(subsystem: "io.github.ccch1mneyyy.dshApp",
    category: "pet-live-activity")

  private struct Animation {
    let sheet: String
    let frameWidth: Int
    let frameHeight: Int
    let cols: Int
    let box: CGRect
    let cells: [Int]
    /// The pack's chosen still, when it names a cell this animation plays.
    let preview: Int?
  }

  private struct Tier {
    let min: Int
    let anim: String
  }

  private struct Bonus {
    let anims: [String]
    let chance: Double
  }

  private struct Pack {
    /// The idle body, art pixels: the one measure everything scales by.
    let body: CGRect
    /// State name → its animations, first one main.
    let states: [String: [String]]
    let animations: [String: Animation]
    /// Busy state → tiers, highest first (the app's own table).
    let tiers: [String: [Tier]]
    /// State name → an occasional alternative (attention's extras).
    let bonus: [String: Bonus]
  }

  private static var packs: [String: (stamp: String, pack: Pack)] = [:]
  private static var sheets: [String: CGImage] = [:]
  private static var logged: Set<String> = []

  static func sprite(packId: String?, phase: String, petState: String?, tier: Int?,
    seed: String?, bodyHeight: CGFloat, maxHeight: CGFloat, maxWidth: CGFloat? = nil) -> PetArtwork? {
    guard let packId, bodyHeight > 0, maxHeight > 0 else {
      note(packId, "pack_not_staged")
      return nil
    }
    guard let (pack, directory) = source(packId) else {
      note(packId, "pack_not_staged")
      return nil
    }
    if let bundled = PetArtStore.bundled(packId), directory.path == bundled.path {
      note(packId, "using_bundled_art")
    }
    guard let name = animationName(pack, phase: phase, petState: petState,
      tier: tier, seed: seed) ?? pack.states["idle"]?.first,
          let animation = pack.animations[name] else {
      note(packId, "animation_missing")
      return nil
    }
    guard animation.frameWidth > 0, animation.frameHeight > 0, animation.cols > 0,
          !animation.cells.isEmpty else {
      note(packId, "animation_empty")
      return nil
    }
    guard let sheet = image(packId, animation.sheet, directory) else { return nil }
    let index = animation.preview.flatMap { animation.cells.contains($0) ? $0 : nil }
      ?? animation.cells[(animation.cells.count - 1) / 2]
    let cell = CGRect(x: CGFloat(index % animation.cols * animation.frameWidth),
                      y: CGFloat(index / animation.cols * animation.frameHeight),
                      width: CGFloat(animation.frameWidth), height: CGFloat(animation.frameHeight))
      .intersection(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
    guard cell.width >= 1, cell.height >= 1, let cropped = sheet.cropping(to: cell) else {
      note(packId, "cell_out_of_sheet")
      return nil
    }
    // This animation's own window: the body it draws plus whatever props it
    // adds (keyboard, hat, thinking cloud). Nothing else widens it, so the pet
    // keeps its size across states without shrinking into a shared canvas.
    let window = animation.box.union(pack.body)
    guard window.width > 0, window.height > 0 else { return nil }
    let widthScale = maxWidth.map { $0 / window.width } ?? .greatestFiniteMagnitude
    let scale = min(bodyHeight / pack.body.height, maxHeight / window.height, widthScale)
    return PetArtwork(
      image: Image(decorative: cropped, scale: 1),
      draw: CGSize(width: animation.box.width * scale, height: animation.box.height * scale),
      offset: CGSize(width: (animation.box.minX - window.minX) * scale,
        height: (animation.box.minY - window.minY) * scale),
      frame: CGSize(width: window.width * scale, height: window.height * scale))
  }

  /// The pack state a phase stands for, at the tier the app plays: the same
  /// table as `PetPack.animFor` in Dart, so island and app never disagree.
  private static func animationName(_ pack: Pack, phase: String, petState: String?,
    tier: Int?, seed: String?) -> String? {
    if phase == "completed", let celebration = celebration(pack, seed: seed) {
      return celebration
    }
    let phaseState: String = switch phase {
    case "thinking": "thinking"
    case "working", "continuedProcessing": "working"
    case "waitingApproval": "notification"
    case "completed": "attention"
    case "error": "error"
    case "authorizationEnded", "waitingRecovery": "idle"
    default: "idle"
    }
    // The app's selected state is exact: it may be working, juggling, sweeping,
    // or carrying inside a coarser Live Activity phase. Its tier wins first,
    // then that exact state's own first animation. Only when the payload has
    // no usable exact state do we fall back to the phase's equivalent state.
    if let petState, allows(petState, phase: phase) {
      if let tier, tier > 0 {
        for step in pack.tiers[petState] ?? [] where tier >= step.min {
          if pack.animations[step.anim] != nil { return step.anim }
        }
      }
      if let name = pack.states[petState]?.first, pack.animations[name] != nil {
        return name
      }
    }
    if let tier, tier > 0 {
      for step in pack.tiers[phaseState] ?? [] where tier >= step.min {
        if pack.animations[step.anim] != nil { return step.anim }
      }
    }
    if let name = pack.states[phaseState]?.first, pack.animations[name] != nil {
      return name
    }
    // PetPack.animFor ultimately falls back to idle, not to an arbitrary
    // animation, so keep the island's fallback identical.
    return pack.states["idle"]?.first
  }

  /// A finished turn's occasional extra pose (`bonus.attention`), picked from
  /// the turn's own seed: the same turn always celebrates the same way.
  private static func celebration(_ pack: Pack, seed: String?) -> String? {
    guard let bonus = pack.bonus["attention"], let seed, !bonus.anims.isEmpty else { return nil }
    let roll = Double(hash(seed) % 1000) / 1000
    guard roll < bonus.chance else { return nil }
    let anims = bonus.anims.filter { pack.animations[$0] != nil }
    guard !anims.isEmpty else { return nil }
    return anims[Int(hash(seed + "/pick") % UInt64(anims.count))]
  }

  private static func hash(_ text: String) -> UInt64 {
    var value: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
      value = (value ^ UInt64(byte)) &* 0x100000001b3
    }
    return value
  }

  /// A state the app sends may name its exact animation; only accept it when it
  /// still belongs to the phase, so a stale background update cannot lie.
  private static func allows(_ petState: String, phase: String) -> Bool {
    switch phase {
    case "working", "continuedProcessing":
      return ["working", "juggling", "sweeping", "carrying", "thinking"].contains(petState)
    case "thinking": return petState == "thinking"
    case "waitingApproval": return petState == "notification"
    case "completed": return petState == "attention"
    case "error": return petState == "error"
    default: return petState == "idle"
    }
  }

  /// The first place this pack really reads from: the app's staged copy in the
  /// App Group, else the built-in copy in this bundle. A half-written or
  /// unreadable staged copy falls through instead of leaving an emoji behind.
  private static func source(_ packId: String) -> (Pack, URL)? {
    for directory in PetArtStore.candidates(packId) {
      if let pack = read(packId, directory) { return (pack, directory) }
    }
    return nil
  }

  private static func read(_ packId: String, _ directory: URL) -> Pack? {
    // Keyed by the folder, not just the pack id: the staged copy and the
    // built-in one are two different packs that can share an id.
    let key = directory.path
    let stamp = (try? String(contentsOf: directory.appendingPathComponent("stamp"), encoding: .utf8)) ?? ""
    if let cached = packs[key], cached.stamp == stamp { return cached.pack }
    // A re-import can reuse a pack id with different bytes. Its stamp changes,
    // so drop that pack's images before reading the replacement sheets.
    sheets = sheets.filter { !$0.key.hasPrefix(key + "/") }
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("pack.json")),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let pack = pack(json) else {
      note(packId, "pack_unreadable")
      return nil
    }
    packs[key] = (stamp, pack)
    return pack
  }

  private static func pack(_ json: [String: Any]) -> Pack? {
    guard let body = rect(json["contentBox"]),
          let raw = json["animations"] as? [String: [String: Any]] else { return nil }
    var states: [String: [String]] = [:]
    for (state, names) in (json["states"] as? [String: [Any]]) ?? [:] {
      states[state] = names.compactMap { $0 as? String }
    }
    var parsed: [String: Animation] = [:]
    for (name, value) in raw {
      guard let sheet = value["sheet"] as? String, !sheet.isEmpty, !sheet.contains("/"),
            let frameWidth = number(value["frameW"]), let frameHeight = number(value["frameH"]),
            let cols = number(value["cols"]), cols > 0, let box = rect(value["box"]) else { continue }
      parsed[name] = Animation(sheet: sheet, frameWidth: frameWidth, frameHeight: frameHeight,
        cols: cols, box: box,
        cells: (value["frames"] as? [[String: Any]] ?? []).compactMap { number($0["i"]) },
        preview: number(value["preview"]))
    }
    guard !parsed.isEmpty else { return nil }
    var tiers: [String: [Tier]] = [:]
    for (state, steps) in (json["tiers"] as? [String: [Any]]) ?? [:] {
      tiers[state] = (steps.compactMap { $0 as? [String: Any] }).compactMap { step in
        guard let anim = step["anim"] as? String else { return nil }
        return Tier(min: number(step["min"]) ?? 1, anim: anim)
      }.sorted { $0.min > $1.min }
    }
    var bonus: [String: Bonus] = [:]
    for (state, value) in (json["bonus"] as? [String: [String: Any]]) ?? [:] {
      guard let anims = value["anims"] as? [String] else { continue }
      let chance = (value["chance"] as? NSNumber)?.doubleValue ?? 0
      bonus[state] = Bonus(anims: anims, chance: chance)
    }
    return Pack(body: body, states: states, animations: parsed, tiers: tiers, bonus: bonus)
  }

  private static func image(_ packId: String, _ sheet: String, _ directory: URL) -> CGImage? {
    let key = directory.path + "/" + sheet
    if let cached = sheets[key] { return cached }
    let url = directory.appendingPathComponent(sheet)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      note(packId, "sheet_unreadable")
      return nil
    }
    if sheets.count >= 3 { sheets.removeAll() }
    sheets[key] = image
    return image
  }

  /// One non-sensitive line per pack and reason, so a missing App Group, a
  /// half-copied pack or an undecodable sheet is visible in Console instead of
  /// hiding behind the emoji fallback forever.
  private static func note(_ packId: String?, _ reason: String) {
    let key = (packId ?? "none") + "/" + reason
    guard !logged.contains(key) else { return }
    logged.insert(key)
    log.notice("Live Activity art unavailable: \(key, privacy: .public)")
  }

  private static func number(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    return double.isFinite ? Int(double.rounded()) : nil
  }

  private static func rect(_ value: Any?) -> CGRect? {
    guard let raw = value as? [String: Any], let x = raw["x"] as? NSNumber,
          let y = raw["y"] as? NSNumber, let width = raw["w"] as? NSNumber,
          let height = raw["h"] as? NSNumber else { return nil }
    let rect = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
    guard rect.width > 0, rect.height > 0 else { return nil }
    return rect
  }
}

/// What a phase looks like while the art is not staged yet.
private enum Emoji {
  static func face(packId: String?, phase: String) -> String {
    switch packId {
    case "deepy-whale": return "🐳"
    case "whale-girl": return "🐋"
    default: return byPhase(phase)
    }
  }

  private static func byPhase(_ phase: String) -> String {
    switch phase {
    case "thinking": return "🐱💭"
    case "continuedProcessing": return "🐱🛠"
    case "authorizationEnded": return "😺"
    case "waitingRecovery": return "😺"
    case "working": return "🐱🛠"
    case "waitingApproval": return "🙀"
    case "completed": return "😸"
    case "error": return "😿"
    default: return "😺"
    }
  }
}

/// Live Activity for a DSH agent background task (Settings → iOS background
/// running → 实时活动). Minimal on purpose: title + status, no pet art.
/// Attributes live in Shared/DSHActivityAttributes.swift so the Runner target
/// can start / update / end this activity.
@available(iOS 16.2, *)
struct DSHAgentLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DSHActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 4) {
        Text(context.state.title)
          .font(.headline)
          .lineLimit(1)
        Text(dshActivityStatusText(context.state.status))
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if let detail = context.state.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .padding()
      .activityBackgroundTint(Color(.systemBackground))
      .activitySystemActionForegroundColor(.primary)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.state.title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(dshActivityStatusText(context.state.status))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if let detail = context.state.detail, !detail.isEmpty {
            Text(detail)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      } compactLeading: {
        Text("DSH")
          .font(.system(size: 12, weight: .bold))
      } compactTrailing: {
        Text(dshActivityStatusShort(context.state.status))
          .font(.system(size: 12))
      } minimal: {
        Text(dshActivityStatusShort(context.state.status))
          .font(.system(size: 12))
      }
    }
  }
}

private func dshActivityStatusText(_ status: String) -> String {
  let zh = Locale.current.languageCode == "zh"
  switch status {
  case "completed": return zh ? "已完成" : "Completed"
  case "failed": return zh ? "失败" : "Failed"
  case "expired": return zh ? "已结束" : "Ended"
  default: return zh ? "运行中" : "Running"
  }
}

private func dshActivityStatusShort(_ status: String) -> String {
  switch status {
  case "completed": return "✓"
  case "failed": return "✕"
  case "expired": return "—"
  default: return "…"
  }
}

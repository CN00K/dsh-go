import ActivityKit
import ImageIO
import SwiftUI
import WidgetKit

@main
struct PetLiveActivityBundle: WidgetBundle {
  var body: some Widget { PetLiveActivity() }
}

struct PetLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: PetActivityAttributes.self) { context in
      HStack(spacing: 12) {
        PetSprite(packId: context.state.packId, phase: context.state.phase,
          petState: context.state.petState, label: label(context), height: 34)
        Text(label(context)).font(.headline)
        Spacer()
        Image(systemName: context.isStale ? "clock.badge.exclamationmark" : appearance(context.state.phase).symbol)
      }
      .padding()
      .foregroundStyle(appearance(context.state.phase).color)
      .activityBackgroundTint(Color.black.opacity(0.9))
      .activitySystemActionForegroundColor(.white)
      .widgetURL(context.attributes.url)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          PetSprite(packId: context.state.packId, phase: context.state.phase,
            petState: context.state.petState, label: label(context), height: 30)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Image(systemName: context.isStale ? "clock.badge.exclamationmark" : appearance(context.state.phase).symbol)
            .foregroundStyle(appearance(context.state.phase).color)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(label(context)).font(.headline).lineLimit(2)
            .foregroundStyle(appearance(context.state.phase).color)
        }
      } compactLeading: {
        PetSprite(packId: context.state.packId, phase: context.state.phase,
          petState: context.state.petState, label: label(context), height: 20)
      } compactTrailing: {
        Image(systemName: context.isStale ? "clock.badge.exclamationmark" : appearance(context.state.phase).symbol)
          .foregroundStyle(appearance(context.state.phase).color)
          .accessibilityLabel(label(context))
      } minimal: {
        PetSprite(packId: context.state.packId, phase: context.state.phase,
          petState: context.state.petState, label: label(context), height: 14)
      }
      .widgetURL(context.attributes.url)
      .keylineTint(appearance(context.state.phase).color)
    }
  }

  private func label(_ context: ActivityViewContext<PetActivityAttributes>) -> String {
    context.isStale ? context.state.staleLabel : context.state.label
  }
}

/// The colour and status symbol a phase gets; the pet itself comes from the
/// art the app staged (below), and only falls back to emoji while a pack's
/// files are not there yet.
private func appearance(_ phase: String) -> (symbol: String, color: Color) {
  switch phase {
  case "thinking": return ("ellipsis", .cyan)
  case "continuedProcessing": return ("arrow.triangle.2.circlepath", .orange)
  case "authorizationEnded": return ("pause.circle.fill", .yellow)
  case "waitingRecovery": return ("clock.badge.exclamationmark", .yellow)
  case "working": return ("gearshape.fill", .orange)
  case "waitingApproval": return ("hand.raised.fill", .yellow)
  case "completed": return ("checkmark.circle.fill", .green)
  case "error": return ("exclamationmark.triangle.fill", .red)
  default: return ("moon.fill", .mint)
  }
}

/// The chosen pet, drawn from its own sheet: the same cell the app plays for
/// the state this phase maps to. A Live Activity is a still (WidgetKit owns
/// rendering; it has no frame timer), so one frame of that animation stands
/// for it, scaled by the pack's own body box.
private struct PetSprite: View {
  let packId: String?
  let phase: String
  let petState: String?
  let label: String
  let height: CGFloat

  var body: some View {
    if let art = PetArt.sprite(packId: packId, phase: phase, petState: petState, height: height) {
      art.image
        .resizable()
        .interpolation(.none)
        .frame(width: art.draw.width, height: art.draw.height)
        .offset(x: art.offset.width, y: art.offset.height)
        .frame(width: art.frame.width, height: art.frame.height, alignment: .topLeading)
        .clipped()
        .accessibilityLabel(label)
    } else {
      Text(Emoji.face(packId: packId, phase: phase))
        .font(.system(size: height))
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .accessibilityLabel(label)
    }
  }
}

/// The pet's own still, in points: [draw] is the cropped cell after the pack's
/// animation box is applied, placed at [offset] inside a window of [frame], so
/// every phase keeps the pet's size.
struct PetArtwork {
  let image: Image
  let draw: CGSize
  let offset: CGSize
  let frame: CGSize
}

/// Reads what the app staged in the App Group (`PetArtStore`): the pack's
/// `pack.json` plus the sheets it names, exactly as the app draws them.
enum PetArt {
  private struct Animation {
    let sheet: String
    let frameWidth: Int
    let frameHeight: Int
    let cols: Int
    /// Where a cell sits on the canvas, art pixels.
    let box: CGRect
    /// Cell indices in play order.
    let cells: [Int]
  }

  private struct Pack {
    let anchorX: CGFloat
    let baseline: CGFloat
    /// The idle body, art pixels.
    let body: CGRect
    /// State name → its animations, first one main.
    let states: [String: [String]]
    let animations: [String: Animation]
  }

  private static var packs: [String: (stamp: String, pack: Pack)] = [:]
  private static var sheets: [String: CGImage] = [:]

  static func sprite(packId: String?, phase: String, petState: String?, height: CGFloat) -> PetArtwork? {
    guard let packId, height > 0, let directory = PetArtStore.directory(packId),
          let pack = read(packId, directory),
          let animation = pack.animations[animationName(pack, phase: phase, petState: petState)],
          let sheet = image(packId, animation.sheet, directory) else { return nil }
    guard animation.frameWidth > 0, animation.frameHeight > 0, animation.cols > 0,
          !animation.cells.isEmpty else { return nil }
    let index = animation.cells[animation.cells.count / 3]
    let cell = CGRect(x: CGFloat(index % animation.cols * animation.frameWidth),
                      y: CGFloat(index / animation.cols * animation.frameHeight),
                      width: CGFloat(animation.frameWidth), height: CGFloat(animation.frameHeight))
      .intersection(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
    guard cell.width >= 1, cell.height >= 1, let cropped = sheet.cropping(to: cell) else { return nil }
    // One window per pack, so the pet keeps its size across phases. Cover every
    // box the mapped states use, not just the idle body: a thinking bubble or
    // typing keyboard is part of the frame and must not be cropped away.
    let stage = stage(pack, sheet: sheet)
    let windowHeight = stage.height * 1.08
    let windowWidth = max(stage.width * 1.08, windowHeight * 1.05)
    let bottom = max(stage.maxY, pack.baseline) + 2
    let windowX = pack.anchorX - windowWidth / 2
    let windowY = bottom - windowHeight
    let scale = height / windowHeight
    // PetSpritePainter draws the sheet cell into the animation's box on the
    // pack canvas. Use the same box here instead of drawing sheet pixels at 1:1.
    let draw = CGSize(width: animation.box.width * scale, height: animation.box.height * scale)
    return PetArtwork(
      image: Image(decorative: cropped, scale: 1),
      draw: draw,
      offset: CGSize(width: (animation.box.minX - windowX) * scale,
        height: (animation.box.minY - windowY) * scale),
      frame: CGSize(width: windowWidth * scale, height: windowHeight * scale))
  }

  /// The union of the boxes the Live Activity's phases can draw.
  private static func stage(_ pack: Pack, sheet: CGImage) -> CGRect {
    let states = ["idle", "thinking", "working", "notification", "attention", "error", "sleeping"]
    let boxes = states.compactMap { state in
      pack.states[state]?.first.flatMap { pack.animations[$0]?.box }
    }
    guard var area = boxes.first else {
      return pack.body.isEmpty
        ? CGRect(x: 0, y: 0, width: CGFloat(sheet.width), height: CGFloat(sheet.height))
        : pack.body
    }
    for box in boxes.dropFirst() { area = area.union(box) }
    return area
  }

  /// The pack state a Live Activity phase stands for (the app's own table).
  private static func animationName(_ pack: Pack, phase: String, petState: String?) -> String {
    if let petState, allows(petState, phase: phase), let name = pack.states[petState]?.first {
      return name
    }
    let state = switch phase {
    case "thinking": "thinking"
    case "working", "continuedProcessing": "working"
    case "waitingApproval": "notification"
    case "completed": "attention"
    case "error": "error"
    case "authorizationEnded", "waitingRecovery": "sleeping"
    default: "idle"
    }
    return pack.states[state]?.first ?? pack.states["idle"]?.first ?? "idle"
  }

  /// A state the app sends may name its exact animation; only accept it when it
  /// still belongs to the phase, so a stale background update cannot lie.
  private static func allows(_ petState: String, phase: String) -> Bool {
    switch phase {
    case "working", "continuedProcessing":
      return ["working", "juggling", "sweeping", "carrying"].contains(petState)
    case "thinking": return petState == "thinking"
    case "waitingApproval": return petState == "notification"
    case "completed": return petState == "attention"
    case "error": return petState == "error"
    case "authorizationEnded", "waitingRecovery": return petState == "sleeping"
    default: return petState == "idle"
    }
  }

  private static func read(_ packId: String, _ directory: URL) -> Pack? {
    let stamp = (try? String(contentsOf: directory.appendingPathComponent("stamp"), encoding: .utf8)) ?? ""
    if let cached = packs[packId], cached.stamp == stamp { return cached.pack }
    // A re-import can reuse a pack id with different bytes. Its stamp changes,
    // so drop that pack's images before reading the replacement sheets.
    sheets = sheets.filter { !$0.key.hasPrefix(packId + "/") }
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("pack.json")),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let pack = pack(json) else { return nil }
    packs[packId] = (stamp, pack)
    return pack
  }

  private static func pack(_ json: [String: Any]) -> Pack? {
    guard let body = rect(json["contentBox"]),
          let animations = json["animations"] as? [String: [String: Any]] else { return nil }
    var states: [String: [String]] = [:]
    for (state, names) in (json["states"] as? [String: [Any]]) ?? [:] {
      states[state] = names.compactMap { $0 as? String }
    }
    var parsed: [String: Animation] = [:]
    for (name, raw) in animations {
      guard let sheet = raw["sheet"] as? String, !sheet.isEmpty, !sheet.contains("/"),
            let frameWidth = number(raw["frameW"]), let frameHeight = number(raw["frameH"]),
            let cols = number(raw["cols"]), cols > 0, let box = rect(raw["box"]) else { continue }
      parsed[name] = Animation(sheet: sheet, frameWidth: frameWidth, frameHeight: frameHeight,
        cols: cols, box: box,
        cells: (raw["frames"] as? [[String: Any]] ?? []).compactMap { number($0["i"]) })
    }
    guard !parsed.isEmpty else { return nil }
    let anchor = json["anchor"] as? [String: Any] ?? [:]
    return Pack(
      anchorX: CGFloat((anchor["x"] as? NSNumber)?.doubleValue ?? body.midX),
      baseline: CGFloat((anchor["baseline"] as? NSNumber)?.doubleValue ?? body.maxY),
      body: body, states: states, animations: parsed)
  }

  private static func image(_ packId: String, _ sheet: String, _ directory: URL) -> CGImage? {
    let key = packId + "/" + sheet
    if let cached = sheets[key] { return cached }
    let url = directory.appendingPathComponent(sheet)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    if sheets.count >= 3 { sheets.removeAll() }
    sheets[key] = image
    return image
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

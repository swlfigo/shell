import Foundation

/// Side of a pane that a merged tab is dropped onto.
public enum PaneEdge: Sendable, CaseIterable {
  case top, bottom, left, right

  /// top/bottom stack panes vertically; left/right place them side by side.
  public var axis: SplitAxis { self == .top || self == .bottom ? .vertical : .horizontal }
  /// The new pane goes before the target (top/left) or after it (bottom/right).
  var insertsBefore: Bool { self == .top || self == .left }

  /// Edge nearest to a point in unit coordinates (x from the left, y from the top).
  /// Ties resolve in the order left, right, top, bottom.
  public static func nearest(x: Double, yFromTop y: Double) -> PaneEdge {
    let distances: [(PaneEdge, Double)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
    return distances.min { $0.1 < $1.1 }!.0
  }

  /// Whether a pane of this size can be split along `edge`'s axis into two minimum-size panes.
  public static func canSplit(width: Double, height: Double, edge: PaneEdge,
                              paneMin: PaneSize, divider: Double) -> Bool {
    switch edge.axis {
    case .horizontal: return width >= 2 * paneMin.width + divider
    case .vertical: return height >= 2 * paneMin.height + divider
    }
  }
}

/// `.horizontal` = children left→right; `.vertical` = children top→bottom.
public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }

public struct PaneSize: Equatable, Sendable {
  public var width: Double
  public var height: Double
  public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// A tab's pane tree. The operations below keep these invariants: no split has fewer than two
/// children, no split has a child split on the same axis, fractions are positive and sum to 1.
public indirect enum PaneNode: Equatable, Sendable, Codable {
  case pane(UUID)
  case split(id: UUID, axis: SplitAxis, children: [PaneNode], fractions: [Double])

  private enum CodingKeys: String, CodingKey { case kind, id, axis, children, fractions }
  public init(from decoder: Decoder) throws {
    guard decoder.codingPath.filter({ $0.stringValue == "children" }).count <= 32 else {
      throw WorkspaceStoreError.invalidSnapshot
    }
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .kind) {
    case "pane": self = .pane(try values.decode(UUID.self, forKey: .id))
    case "split":
      self = .split(id: try values.decode(UUID.self, forKey: .id),
        axis: try values.decode(SplitAxis.self, forKey: .axis),
        children: try values.decode([PaneNode].self, forKey: .children),
        fractions: try values.decode([Double].self, forKey: .fractions))
    default: throw WorkspaceStoreError.invalidSnapshot
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pane(let id):
      try values.encode("pane", forKey: .kind); try values.encode(id, forKey: .id)
    case .split(let id, let axis, let children, let fractions):
      try values.encode("split", forKey: .kind); try values.encode(id, forKey: .id)
      try values.encode(axis, forKey: .axis); try values.encode(children, forKey: .children)
      try values.encode(fractions, forKey: .fractions)
    }
  }

  /// Pane ids in pre-order (top/left first).
  public var paneIds: [UUID] {
    switch self {
    case .pane(let id): return [id]
    case .split(_, _, let children, _): return children.flatMap(\.paneIds)
    }
  }

  public func contains(_ pane: UUID) -> Bool { paneIds.contains(pane) }

  /// Smallest size that fits every pane at `pane` size: side-by-side children add widths (plus
  /// dividers) and take the max height; stacked children are the transpose.
  public func minimumSize(pane: PaneSize, divider: Double) -> PaneSize {
    guard case .split(_, let axis, let children, _) = self else { return pane }
    let sizes = children.map { $0.minimumSize(pane: pane, divider: divider) }
    let gaps = divider * Double(children.count - 1)
    switch axis {
    case .horizontal:
      return PaneSize(width: sizes.map(\.width).reduce(0, +) + gaps, height: sizes.map(\.height).max() ?? 0)
    case .vertical:
      return PaneSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(0, +) + gaps)
    }
  }

  /// Inserts `new` next to `target` on `edge`. A same-axis parent gains a sibling (the target's
  /// share is halved between them); otherwise the target becomes a new 50/50 split.
  /// Unknown target → unchanged.
  func inserting(_ new: UUID, at target: UUID, edge: PaneEdge) -> PaneNode {
    switch self {
    case .pane(let id):
      guard id == target else { return self }
      let pair: [PaneNode] = edge.insertsBefore ? [.pane(new), self] : [self, .pane(new)]
      return .split(id: UUID(), axis: edge.axis, children: pair, fractions: [0.5, 0.5])
    case .split(let sid, let axis, var children, var fractions):
      if axis == edge.axis, let i = children.firstIndex(of: .pane(target)) {
        let half = fractions[i] / 2
        fractions[i] = half
        let at = edge.insertsBefore ? i : i + 1
        children.insert(.pane(new), at: at)
        fractions.insert(half, at: at)
        return .split(id: sid, axis: axis, children: children, fractions: fractions)
      }
      return .split(id: sid, axis: axis,
                    children: children.map { $0.inserting(new, at: target, edge: edge) },
                    fractions: fractions)
    }
  }

  /// Removes `target`; nil when nothing remains. The result is normalized.
  func removing(_ target: UUID) -> PaneNode? {
    switch self {
    case .pane(let id):
      return id == target ? nil : self
    case .split(let sid, let axis, let children, let fractions):
      var kept: [PaneNode] = []
      var keptFractions: [Double] = []
      for (child, f) in zip(children, fractions) {
        if let c = child.removing(target) {
          kept.append(c)
          keptFractions.append(f)
        }
      }
      return PaneNode.split(id: sid, axis: axis, children: kept, fractions: keptFractions).normalized()
    }
  }

  /// Collapses single-child splits, flattens same-axis child splits (scaling their fractions by
  /// the parent's share) and renormalizes fractions to sum to 1. nil for an empty split.
  func normalized() -> PaneNode? {
    guard case .split(let sid, let axis, let children, let fractions) = self else { return self }
    var flat: [PaneNode] = []
    var flatFractions: [Double] = []
    for (child, f) in zip(children, fractions) {
      guard let n = child.normalized() else { continue }
      if case .split(_, let childAxis, let grand, let grandFractions) = n, childAxis == axis {
        flat += grand
        flatFractions += grandFractions.map { $0 * f }
      } else {
        flat.append(n)
        flatFractions.append(f)
      }
    }
    if flat.isEmpty { return nil }
    if flat.count == 1 { return flat[0] }
    let total = flatFractions.reduce(0, +)
    let shares = total > 0
      ? flatFractions.map { $0 / total }
      : Array(repeating: 1 / Double(flat.count), count: flat.count)
    return .split(id: sid, axis: axis, children: flat, fractions: shares)
  }

  /// Replaces the fractions of split `target` (normalized). Ignored when the count does not
  /// match or any value is not positive.
  func settingFractions(_ new: [Double], split target: UUID) -> PaneNode {
    guard case .split(let sid, let axis, let children, let fractions) = self else { return self }
    if sid == target {
      guard new.count == children.count, new.allSatisfy({ $0.isFinite && $0 > 0 }) else { return self }
      let total = new.reduce(0, +)
      guard total.isFinite else { return self }
      return .split(id: sid, axis: axis, children: children, fractions: new.map { $0 / total })
    }
    return .split(id: sid, axis: axis,
                  children: children.map { $0.settingFractions(new, split: target) },
                  fractions: fractions)
  }
}

public enum SplitMath {
  /// Splits `total` by `fractions`, raising children below their minimum and taking the deficit
  /// from the others in proportion to their slack. If `total` cannot fit all minimums, returns
  /// the plain proportional split.
  public static func distribute(total: Double, fractions: [Double], minimums: [Double]) -> [Double] {
    var lengths = fractions.map { $0 * total }
    guard total >= minimums.reduce(0, +) else { return lengths }
    var deficit = 0.0
    for i in lengths.indices where lengths[i] < minimums[i] {
      deficit += minimums[i] - lengths[i]
      lengths[i] = minimums[i]
    }
    guard deficit > 0 else { return lengths }
    let slack = lengths.indices.map { max(lengths[$0] - minimums[$0], 0) }
    let totalSlack = slack.reduce(0, +)
    guard totalSlack > 0 else { return lengths }
    for i in lengths.indices { lengths[i] -= deficit * slack[i] / totalSlack }
    return lengths
  }
}

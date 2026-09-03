/// Stable small integers for element identities. Never reuses an id: a model
/// that acts on `17` two turns later must either hit the same element or be
/// told it is gone, never silently hit a different one.
public struct IdRegistry {
  private var ids: [AnyHashable: Int] = [:]
  private var byId: [Int: AnyHashable] = [:]
  private var next = 1

  public init() {}

  public mutating func id(for identity: AnyHashable) -> Int {
    if let existing = ids[identity] { return existing }
    let id = next
    next += 1
    ids[identity] = id
    byId[id] = identity
    return id
  }

  public func identity(for id: Int) -> AnyHashable? { byId[id] }

  /// Forget everything not in `seen`. Called after each snapshot.
  public mutating func retain(only seen: Set<AnyHashable>) {
    ids = ids.filter { seen.contains($0.key) }
    byId = byId.filter { seen.contains($0.value) }
  }

  public var count: Int { ids.count }
}

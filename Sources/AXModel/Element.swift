/// Element attributes, already read. Nothing here knows how they were read.
public struct Attributes: Equatable {
  public var role: String            // normalized: "button", "text field"
  public var title: String?
  public var value: String?
  public var x: Int, y: Int, width: Int, height: Int
  public var actions: [String]       // normalized: "press", "raise"
  public var enabled: Bool
  public var focused: Bool
  public var selected: Bool
  /// False when the element reports no position/size at all — the application
  /// root, for one. "Unknown" is not "zero": only known-zero is invisible.
  public var geometryKnown: Bool = true

  public init(role: String, title: String? = nil, value: String? = nil,
              x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0,
              actions: [String] = [], enabled: Bool = true, focused: Bool = false, selected: Bool = false) {
    self.role = role; self.title = title; self.value = value
    self.x = x; self.y = y; self.width = width; self.height = height
    self.actions = actions; self.enabled = enabled; self.focused = focused; self.selected = selected
  }
}

public enum Role {
  /// "AXPopUpButton" -> "pop up button". A subrole wins when it says more
  /// ("AXCloseButton" over "AXButton"; "AXStandardWindow" over "AXWindow").
  public static func normalize(_ role: String, subrole: String? = nil) -> String {
    if let sub = subrole, !sub.isEmpty, sub != "AXUnknown" { return words(sub) }
    return words(role)
  }

  /// "AXPress" -> "press", "AXShowMenu" -> "show menu".
  ///
  /// A Catalyst app's custom actions arrive as the DESCRIPTION of the
  /// UIAccessibilityCustomAction object, three lines of it:
  /// "name: move down\n target:0x0\n selector:(null)". Measured on Maps'
  /// directions fields. The tree is one element per line, so a newline in an
  /// action name breaks every reader of it; keep the name and drop the rest.
  public static func normalizeAction(_ ax: String) -> String {
    if ax.contains("\n") {
      for line in ax.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("name:") { return t.dropFirst(5).trimmingCharacters(in: .whitespaces) }
      }
      return ax.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ax
    }
    return words(ax)
  }

  private static func words(_ ax: String) -> String {
    let s = ax.hasPrefix("AX") ? String(ax.dropFirst(2)) : ax
    if s == "StaticText" { return "text" }
    // CamelCase -> lowercase words: "PopUpButton" -> "pop up button".
    var out = ""
    for (i, ch) in s.enumerated() {
      if ch.isUppercase && i > 0 { out.append(" ") }
      out.append(ch.lowercased())
    }
    return out
  }

  public static let interactive: Set<String> = [
    "button", "checkbox", "check box", "radio button", "pop up button", "menu button",
    "menu item", "menu bar item", "text field", "text area", "search field", "secure text field",
    "combo box", "slider", "link", "tab", "row", "cell", "disclosure triangle", "incrementor",
    "scroll bar", "toolbar", "window", "standard window", "dialog", "sheet", "close button",
    "minimize button", "zoom button", "full screen button",
  ]

  public static func isInteractive(_ role: String) -> Bool { interactive.contains(role) }
}

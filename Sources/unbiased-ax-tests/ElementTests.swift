import AXModel

func runElementTests() {
  print("Element")
  test("AX role names are shortened to what a person would say") {
    try expectEqual(Role.normalize("AXButton"), "button")
    try expectEqual(Role.normalize("AXPopUpButton"), "pop up button")
    try expectEqual(Role.normalize("AXStaticText"), "text")
    try expectEqual(Role.normalize("AXTextField"), "text field")
    try expectEqual(Role.normalize("AXWebArea"), "web area")
    try expectEqual(Role.normalize("AXUnknown"), "unknown")
  }
  test("a role with a subrole shows the subrole when it is more specific") {
    try expectEqual(Role.normalize("AXWindow", subrole: "AXStandardWindow"), "standard window")
    try expectEqual(Role.normalize("AXButton", subrole: "AXCloseButton"), "close button")
    try expectEqual(Role.normalize("AXButton", subrole: nil), "button")
  }
  test("AX action names are shortened too") {
    try expectEqual(Role.normalizeAction("AXPress"), "press")
    try expectEqual(Role.normalizeAction("AXRaise"), "raise")
    try expectEqual(Role.normalizeAction("AXShowMenu"), "show menu")
  }
  test("interactive roles are the ones a user can operate") {
    for r in ["button", "text field", "menu item", "link", "tab", "checkbox", "slider", "row", "cell"] {
      try expect(Role.isInteractive(r), "\(r) should be interactive")
    }
    for r in ["group", "text", "image", "unknown", "web area", "scroll area"] {
      try expect(!Role.isInteractive(r), "\(r) should be structural")
    }
  }
}

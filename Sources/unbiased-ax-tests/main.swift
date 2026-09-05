import AXModel

print("AXModel")
test("protocol version is declared") { try expectEqual(protocolVersion, 1) }

runElementTests()
runIdRegistryTests()
runSnapshotTests()
runFormatterTests()
runDifferTests()
runDispatcherTests()
runDesktopReachTests()
runCrossSpaceTests()
runSettleTests()
runScreenshotTests()
runRefusedActionTests()
runUnresponsiveHintTests()
runServerTests()

finish()

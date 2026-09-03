import Foundation
import AXModel

func runServerTests() {
  print("Server (spawns the built binary)")
  let bin = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("unbiased-ax").path
  test("answers hello and survives a garbage line, one response per line, clean exit on EOF") {
    try expect(FileManager.default.isExecutableFile(atPath: bin), "server binary not built at \(bin) — run swift build first")
    let p = Process(); p.executableURL = URL(fileURLWithPath: bin)
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
    try p.run()
    inPipe.fileHandleForWriting.write("{\"id\":1,\"method\":\"hello\"}\nnot json\n{\"id\":2,\"method\":\"apps\"}\n".data(using: .utf8)!)
    inPipe.fileHandleForWriting.closeFile()
    let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    let lines = out.split(separator: "\n")
    try expectEqual(lines.count, 3, out)
    try expect(lines[0].contains("\"protocolVersion\":1"), String(lines[0]))
    try expect(lines[1].contains("bad_request"), String(lines[1]))
    try expect(lines[2].contains("\"apps\""), String(lines[2]))
    try expectEqual(p.terminationStatus, 0, "clean exit on EOF")
  }
}

import Foundation
import AXModel
import AXBridge

// Newline-delimited JSON over stdio. One request per line, one response per
// line, in order. EOF on stdin is a clean shutdown. Nothing else is ever
// written to stdout; diagnostics go to stderr.
// The same binary is also the window-capture helper: see WindowCapture.
if WindowCapture.isHelperInvocation(CommandLine.arguments) { WindowCapture.helperMain(CommandLine.arguments) }

let dispatcher = Dispatcher(backend: LiveBackend())
while let line = readLine(strippingNewline: true) {
  if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
  print(dispatcher.handle(line: line))
  fflush(stdout)
}

import Foundation
import AXModel
import AXBridge

// Newline-delimited JSON over stdio. One request per line, one response per
// line, in order. EOF on stdin is a clean shutdown. Nothing else is ever
// written to stdout; diagnostics go to stderr.
let dispatcher = Dispatcher(backend: LiveBackend())
while let line = readLine(strippingNewline: true) {
  if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
  print(dispatcher.handle(line: line))
  fflush(stdout)
}

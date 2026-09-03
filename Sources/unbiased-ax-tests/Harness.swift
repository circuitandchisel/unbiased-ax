import Foundation

/// A test framework in 40 lines, because CommandLineTools has neither XCTest
/// nor Swift Testing. Each test file exposes `run<Name>Tests()`; main.swift
/// calls them in order and exits non-zero if anything failed.
struct Failure: Error, CustomStringConvertible { let description: String }

var passed = 0
var failed = 0

func test(_ name: String, _ body: () throws -> Void) {
  do {
    try body()
    passed += 1
    print("  ✔ \(name)")
  } catch {
    failed += 1
    print("  ✖ \(name)\n      \(error)")
  }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: String = #fileID, line: Int = #line) throws {
  if !condition { throw Failure(description: "\(message()) [\(file):\(line)]") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                               file: String = #fileID, line: Int = #line) throws {
  try expect(actual == expected, "got \(String(reflecting: actual)), expected \(String(reflecting: expected))",
             file: file, line: line)
}

func finish() -> Never {
  print("\n\(passed) passed, \(failed) failed")
  exit(failed == 0 ? 0 : 1)
}

# unbiased-ax

The accessibility bridge for unbiased-app's computer use: apps, windows, and
element trees as compact text with stable ids and diffs, plus actions on those
elements. One long-running process, newline-delimited JSON over stdio.

    swift build
    swift run unbiased-ax-tests     # the only test runner; exits non-zero on failure
    make bundle                     # dist/unbiased-ax + dist/manifest.json

Protocol: docs/PROTOCOL.md. Plan: docs/plans/.

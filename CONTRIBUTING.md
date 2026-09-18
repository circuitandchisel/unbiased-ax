# Contributing

Issues and pull requests are welcome. Maintainers decide what enters the
release and retain control of labels, merges, signing, and publishing.

## Development setup

The bridge requires macOS 13 or newer and Swift 5.9 or newer:

```bash
make test
make bundle
```

Changes to live Accessibility or ScreenCaptureKit behavior should include a
focused test in `Sources/unbiased-ax-tests/`. Tests must remain deterministic
and must not depend on a contributor's installed applications or private
desktop data.

Do not include credentials, user data, local absolute paths, screenshots of
private applications, or information copied from private systems.

Maintainers may apply the `ai-review` label after an initial review. Outside
contributors do not need to add or request that label.

By submitting a contribution, you agree that it may be distributed under
the repository's Apache-2.0 license. Report vulnerabilities through
[SECURITY.md](SECURITY.md), not a public issue.

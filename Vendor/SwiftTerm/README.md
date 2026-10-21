# SwiftTerm build slice

Upstream: [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), v1.99.0, revision [`2dad6a1`](https://github.com/migueldeicaza/SwiftTerm/commit/2dad6a1). License: [MIT](LICENSE), with original copyright notices retained.

This directory contains the library sources, build-info generator, SwiftPM plugin and terminfo needed by One Cli. Upstream examples, test fixtures, developer records and remote package dependencies are omitted. The upstream package manifest is replaced with a local library manifest.

Local modifications relative to that revision:

- `Sources/SwiftTerm/Terminal.swift`
- `Sources/SwiftTerm/CharData.swift`
- `Sources/SwiftTerm/TerminalWebInput.swift`
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`
- `Sources/SwiftTerm/Mac/MacTerminalView.swift`
- `Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift`
- `Sources/SwiftTerm/LiveScreenExport.swift` (added)

These changes support One Cli’s terminal behavior, live-screen export and remote input. The package is a modified vendored copy, not an unmodified upstream release. Any updated copy must retain upstream notices and account for these local changes.

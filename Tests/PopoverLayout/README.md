# Popover layout regression

Run from the repository root:

```bash
scripts/test_popover_layout.sh
```

To use an explicitly installed SDK, for example when the current CLT lacks the
macOS 27 SwiftUI macro plugin:

```bash
DEEPSEEKBAR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/test_popover_layout.sh
```

The harness compiles the production `MenuPopoverView` and `ToolUsageView` with a
test-only `AppState`. It never accesses the Keychain, starts the production app,
or sends network requests. Generated binaries and module caches stay in `.build`.

The first assertions check a **width-only** `NSHostingView` and an
`NSHostingController` compressed-height proposal before assigning any window
height. The compressed proposal reproduces the former footer-only popover at
320×74 points: `ViewThatFits` could choose a zero-height `ScrollView`. An ordinary
`fittingSize` or fixed-height screenshot alone does not catch this failure.
Further assertions cover long tool lists, scrolling to the bottom, empty/error
states, and data returning after a refresh, in light and dark appearances.

An optional source-file argument can reproduce a historical regression:

```bash
scripts/test_popover_layout.sh /path/to/old/MenuPopoverView.swift
```

These checks cover native hosting layout; the installed application's actual
menu-bar opening and reopening should also be checked after a layout change.

# macOS 27 switching and indicator validation

## Architecture and invariants

- `DockSwipeTransport` retains separate serialized (macOS 27+) and legacy
  backends. Successfully posting events does not confirm a Space change.
- `SpaceSwitchCoordinator` owns the requested destination, posted projection,
  and confirmation deadline. The indicator reads that same transaction; it has
  no independent prediction or expiration task.
- Confirmation, external movement, failure, cancellation, topology invalidation,
  and expiration release optimistic presentation. A no-op request does not
  restart the deadline. Already-posted gestures are not retried or undone.
- `MenuBarController` owns a native `NSStatusItem` and `NSMenu`. Menu checkmarks
  and accessibility descriptions describe observed state. The icon may show the
  pending destination while a transaction is unresolved.
- Settings previews and the status item use the same immutable render model
  and image renderer. Image creation is driven by changed rendering inputs.
- On every supported macOS version, rendering consists solely of assigning an
  image to `NSStatusItem.button.image`. AppKit handles layout, appearance,
  display replication and menu-bar visibility. There are no replacement panels,
  transparent placeholders, AX queries or geometry timers.

## Release choice

Ship the normal native menu-bar image on all supported macOS versions, with the
original macOS 27 instant-switch parameters: progress `0.000016`, velocity
ceiling `2,000`, and back-to-back gesture phases. Retain the macOS 27 serialized
event support and coordinator correctness fixes. No overlay or experimental
animation tuning is included in the release build.

**Known issue:** on macOS 27, the native menu-bar icon may visibly trail a Space
change (the user observed about one second). The experiments below did not find
an acceptable combination of immediate icon updates and instant switching.
This release accepts the native presentation limitation rather than slowing
switches or replacing the menu-bar image with a floating panel. The underlying
cause of the delayed visible presentation is not conclusively established.

## Preserved overlay workaround

The user reported that overlay rendering solved the visible update problem.
The owned-geometry overlay, its tests, and integration patch are preserved in
the **local Git stash** named:

`macOS 27 live indicator overlay (archived, not for release)`

Stash object: `036b74b2be83221eb71eeee8ba5ad98a2d914dcc` (initially `stash@{0}`).
This is a local backup, not part of the release or a pushed branch.

To recover the archive without enabling it:

```sh
git stash apply 036b74b2be83221eb71eeee8ba5ad98a2d914dcc
```

That recreates only `Experiments/macOS27-overlay/`, outside the app and test
source roots. Read its `README.md` for the explicit re-integration steps.
The integration patch was checked against the current native-only files.
Use `apply`, not `pop`, to retain the stash. The earlier SwiftUI/AX-polling
implementation also remains recoverable from commit `c58843f`.

## Local evidence

### Completed tuning experiments (not shipping)

| Candidate | Progress magnitude | Velocity ceiling | User-observed result |
| --- | --- | --- | --- |
| Native-only baseline | `0.000016` | `2,000` | Icon sometimes updates about a second after switching |
| Progress experiment | `0.05` | `2,000` | Menu-bar appearance improved, but swipe animation noticeably slower/degraded |
| Higher-velocity experiment | `0.05` | `8,000` | Faster animation, but menu bar no longer updates; rejected |
| Intermediate-velocity experiment | `0.05` | `4,000` | Animation still too slow; icon reliability not separately confirmed |
| Final velocity experiment | `0.05` | `6,000` | Still too slow, and menu-bar items did not track fast enough; rejected |

These experiments held phase ordering/timing, coordinator behavior and native
status-image rendering constant. The default Instant preset requests `999,999`,
so the velocity ceiling determined the actual ending velocity. Both directions
and both serialized gesture modes used the experimental parameters. All tuning
changes have now been reverted to the native-only baseline.

Motivation: [noswoosh #9](https://github.com/mmathys/noswoosh/issues/9#issuecomment-5671162376)
reports fewer menu-bar compositing failures with increased gesture progress on
the same OS build, but also visible animation. This is a hypothesis to evaluate,
not a confirmed fix for Blink's delayed icon updates.

Future rendering investigations should start from a known-good desktop, since
a previously stuck compositor could contaminate comparisons. Timestamp state
changes and image assignment separately from measuring the visible screen.

### Evidence from the baseline before this experiment

Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5209h), one display, three
Spaces. Results were obtained on the working-tree fixes based on PR revision
`c58843f`.

- The baseline suite passed 39 cases before changes.
- The native-only revision passed all 58 cases on this macOS 27 build. The three
  overlay-coverage cases were removed with the overlay implementation. Earlier
  Fastfile Ruby syntax and workflow YAML parsing checks also passed.
- A production `SpaceSwitcher` request from index 1 (Space ID 4) to index 2
  synchronously presented index 2. A fresh system observation reported index 2
  at the first 200 ms sample. Switching back restored observed index 1.
- After confirming a Blink switch to index 2, an independent transport submitted
  the opposite gesture (outside that coordinator's transaction). At the first
  100 ms sample, both observed state and the indicator reported index 1. There
  was no three-second prediction hold, and the original Space was restored.
- Native status-button geometry and AX-reported geometry were compared in a
  standalone probe. Their centers matched. The status button reported
  `NSAppearanceNameVibrantDark` on the current menu-bar background.
- AX inspection exposed the status item's observed Space description, both
  direction actions, the indexed/Last Space submenu, Settings, Disable and Quit.
  AXPress returned a cannot-complete error on this OS build, so this is evidence
  of accessible structure, not a completed end-to-end menu interaction check.
- The local process has no screen-capture permission. Visible update latency
  has **not** been measured, and native AppKit updates have **not** been proven
  to eliminate macOS 27's deferred rendering. The overlay workaround has been
  removed from production and preserved separately for future investigation.

Legacy event readback on macOS 27 is not a substitute for pre-27 validation:
private progress/scroll fields alias differently, and integer flags may read
back zero-extended. Automated compatibility checks retain the legacy write
sequence and validate event ordering, phases, velocity, and flag bit patterns.

## Automated checks

Run the `Blink` scheme's test plan in Xcode, or:

```sh
nix develop . --command fastlane ci_tests
CI_CLEAN_BUILD=1 nix develop . --command fastlane ci_tests
```

The normal lane reuses compatible DerivedData. The second command explicitly
performs a clean build. Test reports/result bundles are in `build/TestResults`
and build logs in `build/Logs`.

PR CI checks out the proposed merge revision, tests it, and packages that same
revision. The artifact's `REVISION.txt` records both the built revision and the
PR head. Test results and logs are uploaded even when testing fails. CI on
macOS 26 does not establish Dock acceptance on macOS 27.

## Runtime release checklist

Quit other Space-switching utilities, launch the candidate Blink Dev, and grant
its required permissions. Record the revision, Mac model and `sw_vers` output.
Observe the desktop itself as well as the menu-bar image. Keep this log running:

```sh
/usr/bin/log stream --level debug --style compact --predicate 'process == "Blink Dev" AND (category == "SpaceSwitchCoordinator" OR category == "DockSwipeTransport")'
```

- Keyboard-only switching with all gesture bindings and suppression disabled:
  both directions, one Space per request; restore settings afterward.
- Three-/four-finger gestures, both suppression settings, repeated directions,
  and immediate reversals; no extra switch on finger release.
- Rapid input, long jumps, wrapping, and switching between fullscreen Spaces.
- Immediately after a confirmed Blink switch, choose another Space in Mission
  Control or activate an app on another Space. The presentation model must
  follow without a three-second stale prediction. Record visible native redraw
  delay separately from the model; that delay remains a known macOS 27 issue.
- While Mission Control is open: switch both directions and across several
  Spaces. Verify App Exposé bypass separately.
- Open the menu with the mouse and keyboard; exercise its actions, shortcuts,
  checkmarks, highlighting, and VoiceOver description.
- Add/remove/reorder Spaces during a pending jump. Change the pointer's display
  during a jump. Only real observed destinations may enter Last Space history.
- Two displays: check both menu bars simultaneously, then different scaling,
  vertically arranged displays, and disconnect/reconnect. Native icons must
  remain visible and update correctly on each display.
- Auto-hide, fullscreen menu-bar reveal, appearance/background changes,
  Command-drag rearrangement, sleep/wake, and menu-bar management utilities.
- Record native rendering during rapid switching. Measure visible
  latency separately from state/image assignment; check idle CPU/wakeups with
  Instruments. Confirm the image updates without needing a click or menu open.
- Repeat the core switching/menu checks on macOS 26 (and the oldest supported
  release available to the tester).

Physical trackpad, multi-display, fullscreen/Mission Control, pre-27 behavior,
visual latency, and energy measurements require the above runtime checks; unit
tests do not establish those outcomes.

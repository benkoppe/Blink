# Blink 0.0.10

## What's New
- App Exposé detection.
  - Blink now lets unmodified gestures through in App Exposé, restoring system functionality.
- Opening the app while its already open now launches settings.

# Blink 0.0.9

## What's New
- Tahoe menu bar icon adjustments.

# Blink 0.0.8

## What's New
- New toggle to consume system space-switching gestures (default is on).
- New toggle to flip left/right gesture directions.
- Gesture and hotkey detection is more resilient

# Blink 0.0.7

## What's New
- Faster & more reliable "jump to index" actions.

## Bug Fixes
- Holding a keyboard shortcut no longer also triggers the system action after a delay.
- Properly detect when Mission Control is active in all cases.

# Blink 0.0.6

## What's New
- Blink can now override system hotkeys like ctrl + left / right
  - Default keybinds have been adjusted to simpler variants

## Bug Fixes
- Instant space switches once again works in fullscreen apps.
- Jumping to a nonexistent space index now does nothing.

# Blink 0.0.5

## What's New
- Instant space switches now work properly in Mission Control.
- New "Wrap spaces" option wraps around the space edges (from 1 to n and n to 1).
- Gesture settings are now on their own settings pane.
  - New "Multiswipe" option allows swiping the same direction multiple times with a configured sensitivity. (experimental)
- Menu Bar now uses native macOS menu appearance.

# Blink 0.0.4

## What's New
- Added app icon.

# Blink 0.0.3

## What's New
- General settings pane now has options.
- Added "Launch at login" toggle.

## Bug Fixes
- Menu Bar button targets are now easier to press.
- Auto-updates and auto-update-checks are now automatically enabled.

# Blink 0.0.2

## What's New
- Prettified menu bar in a new custom, non-menu window that mirrors the Control Center UI.
- Add gesture binding options between 3/4-finger options.

## Bug Fixes
* Fixed a fatal crash when certain unexpected events were caught by the SpaceSwitcher.
* Added more event observers to ensure space details are accurate more often.

# Blink 0.0.1

Initial release of Blink.

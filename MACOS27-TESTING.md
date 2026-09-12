# macOS 27 candidate fix validation

This build uses the synthetic gesture sequence reported working in
[iss commit 09beeb68](https://github.com/joshuarli/iss/commit/09beeb68b1c2c2e6bb02ce88bde345d48f3490a1):
progress magnitude 1, ending velocity magnitude 9,999, and three consecutive
Dock/companion event pairs. Blink retains its own direction model and synthetic
marker bypass. The marker now uses documented source user data and is restored
after deserialization, which otherwise clears it. Actual Dock acceptance must
be checked on macOS 27.

## Capture

Quit other copies of Blink and other Space-switching utilities. Launch the new
Blink Dev artifact and grant it Accessibility access. Record the artifact commit,
Mac model, and the output of `sw_vers`.

Before testing, run this in Terminal and leave it running:

```sh
/usr/bin/log stream --level info --style compact --predicate 'process == "Blink Dev" AND (category == "SpaceSwitcher" OR category == "SpaceSwitchCoordinator")'
```

Copy the relevant output into the issue with your results. It records gesture
posting and requested/observed Space IDs. Posting is not proof of a desktop move.

## Checks

Use at least three Spaces. Allow about four seconds between isolated checks;
test rapid input separately. Observe the desktop itself as well as the indicator.

- From the middle Space: Ctrl+Arrow left and right, exactly one Space each.
- Three-finger swipes both ways: exactly one Space, including after finger release.
- At either edge: no false persistent indicator when requesting an impossible move.
- Several rapid commands: correct final destination, no overshoot.
- Switch using Mission Control, then Blink: no stale prediction blocking input.
- Enter and leave fullscreen Spaces, then switch both ways.
- Switch while Mission Control is open.
- If using multiple displays, move the pointer between displays and repeat.

If no desktop movement occurs, the indicator should return to the observed Space
after approximately three seconds of inactivity. Report the OS build, direction,
starting position, input method, and whether the log says confirmed or expired.
No automatic retry is performed, to avoid overshooting a delayed transition.

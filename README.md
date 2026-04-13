<div align="center">
  <img src="Resources/Icon.png" width=200 height=200>
  <h1>Blink</h1>
</div>

Blink does a simple job: enabling **instant space switches** on macOS.

1. [Install](#install)
2. [Why?](#why)
3. [Thanks](#thanks)

## Install

### Manual Installation

Download the "Blink.dmg" file from the [latest release](https://github.com/benkoppe/Blink/releases/latest) and drag the app into your `Applications` folder.

### Homebrew

Install Blink using following command:

```bash
brew install --cask benkoppe/tap/blink
```

## Why?

Every time you change spaces on macOS, ~0.5 seconds are lost from your day. On Macbook Pro 120hz screens, it's a full 1 second.

There's no real solution to this:

1. "Reduce motion" in System Settings replaces the swipe animation with a fade that's exactly as slow.
2. [yabai](https://github.com/asmvik/yabai) requires disabling System Integrity Protection.
3. [AeroSpace](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces) and [FlashSpace](https://github.com/wojciech-kulik/FlashSpace) abandon native spaces completely, which can be overkill for some.
4. [BetterTouchTool](https://folivora.ai/) is great, and comes with "Move Left/Right Space (Without Animation)" options, but costs money.

Blink is a simple application built to solve this problem with zero drawbacks.

Here's what makes Blink different:

| Feature | Details |
|------|--------|
| **Overrides system default hotkeys and gestures** | Out of the box, Blink takes over all the system inputs you'd expect. This makes Blink a seamless setup often with zero configuration. |
| **Works everywhere** | Blink is currently the only app that gives you instant switches in both regular spaces *and* in Mission Control. |
| **Highly customizable** | Blink gives full flexibility over its menu bar appearance, behavior, and more. |
| **Simple & lightweight** | Blink is <10 MB and has next to zero footprint. It easily slots into your system and works its sole job. | 

## Thanks

Without these people & app inspirations, Blink wouldn't be possible:

| Name | Reason |
|------|--------|
| [BetterTouchTool](https://folivora.ai/) | As far as I can tell, BetterTouchTool (BTT) is the first app to use this trick. Everyone else I've seen has followed BTT. Thanks @fifafu! |
| RGBCube's [darwin-fast-workspace-switch](https://github.com/RGBCube/ncc/blob/dentride/modules/darwin-fast-workspace-switch.mod.nix) | Decompiled from BTT; original base of Blink's space-switching logic. I had also decompiled BTT to reverse engineer this feature, but I never got it working myself before seeing this.  |
| jurplel's [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) | Around the same time I started working on Blink, I saw this posted to Hacker News. It takes a slightly different approach to Blink in some ways, but it definitely became inspiration behind some features like the Menu Bar UI. |
| jordanbaird's [Ice](https://github.com/jordanbaird/Ice) | Inspiration for much of Blink's settings UI. |

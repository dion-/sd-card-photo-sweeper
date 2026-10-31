# SD Card Photo Sweeper

<img src="docs/screenshot.png" width="386" alt="Importing 150 photos from an SD card, with progress and time remaining">

Imports photos from SD cards into Apple Photos automatically.

- Starts as soon as you insert a card
- Imports RAW files only
- Shows progress and time remaining
- Checks each copy, then deletes it from the card
- Ejects the card when done

## Install

Needs macOS 14 or later.

```sh
xcode-select --install   # Apple's Command Line Tools, if you don't have them
git clone https://github.com/dion-/sd-card-photo-sweeper.git ~/sd-card-photo-sweeper
~/sd-card-photo-sweeper/build.sh install
```

The first time you insert a card, allow Photos access (both prompts) and notifications. After that it runs on its own, and opens at login.

To update: `git -C ~/sd-card-photo-sweeper pull && ~/sd-card-photo-sweeper/build.sh install`

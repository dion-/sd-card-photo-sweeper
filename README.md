# SD Import

Insert an SD card into the Mac. A menu-bar app imports every RAW into Photos, checks each copy byte for byte, removes the verified photos from the card, ejects it, and posts a notification.

## Install on a Mac

Needs macOS 14 or later and Apple's Command Line Tools (free; full Xcode isn't needed).

```sh
xcode-select --install                     # once per Mac, if the tools aren't installed yet
gh auth login -p https -w                  # once per Mac (GitHub CLI: `brew install gh`); the repo is private
gh repo clone dion-/sd-import ~/sd-import
~/sd-import/build.sh install
```

`build.sh install` builds the app, copies it to `/Applications`, and opens it. Then:

1. Allow notifications when asked.
2. Insert a card. Allow both Photos prompts: "add" to import, and full access, which is needed to check each copy before removing it from the card.

The app opens at login from then on. To update later: `git -C ~/sd-import pull && ~/sd-import/build.sh install`.

**Signing.** `build.sh` signs with the first "Apple Development" certificate in the keychain (override with `SIGN_ID=…`). On a Mac without one it signs ad hoc, which works the same, but macOS may ask for Photos access again after each rebuild.

**Ledger.** Each Mac keeps its own ledger of imported files (`~/Library/Application Support/SDImport/ledger.jsonl`). Verified photos are removed from the card, so a new Mac with an empty ledger won't import them twice.

Tools:

```sh
SDImport --scan /Volumes/CARD   # what an insert would import; writes nothing
SDImport --demo [MB/s] [saved MB/s]      # real UI and timing on a simulated card; touches neither Photos nor the ledger
```

(`SDImport` is `"/Applications/SD Import.app/Contents/MacOS/SDImport"`.)

## Code

| File | Contents |
|---|---|
| `Sources/App.swift` | Entry point (`--scan`, `--demo`), menu-bar item and menu |
| `Sources/ProgressUI.swift` | Progress layout and the floating progress window |
| `Sources/Importer.swift` | Mount watching, queue, batches, verify and remove, eject, time estimate |
| `Sources/Verifier.swift` | SHA-256 of card files and of the originals in Photos |
| `Sources/Scanner.swift` | Card detection (removable/ejectable + `DCIM/`), DCIM walk, RAW+JPEG pairing |
| `Sources/Ledger.swift` | `~/Library/Application Support/SDImport/ledger.jsonl` |

## What you see

- **Progress window.** Opens on its own at the top centre of the screen when a card goes in, and doesn't take focus. It's laid out like Finder's copy window: a title ("Importing 150 photos from CARD"), a progress bar, "2.83 GB of 6.75 GB · 63 of 150 photos", and "About 50 seconds remaining". It closes 8 s after a success. A failure stays until you close it.
- **Menu-bar icon.** Shows the percentage and time left while busy, e.g. `42% · 2:40`. Clicking it shows the same progress plus the settings.
- **Notification.** Posted at the end, with the count, size, time taken, speed, and what happened on the card.

## Time estimate

- The estimate is based on bytes left divided by speed. The speed is measured end to end: card read, Photos import, and the verify-and-remove step.
- Batches are sized to about 3 s of work, so the speed is measured every 3 s. The first batch has only 2 photos, so the first measurement comes quickly. That batch includes Photos warming up, so it's left out of the speed once there's a second batch.
- The speed is saved per card (by volume UUID). A card seen before gets an accurate estimate right away, and the saved speed gives way to live measurements within seconds. A card never seen before shows "Estimating time remaining…" until the second batch finishes.
- The displayed time counts down each second and eases toward each new estimate, so it doesn't jump. The bar moves between batches at the measured speed, but never past 95% of the batch in progress.
- Demo results at 90 MB/s with ±15% noise per batch, for a card never seen before: off by 1% at 5% of the way through, and within 3% from then on.

## Removing photos from the card (on by default)

A file leaves the card only after its copy in Photos is proven byte-identical to it:

1. Hash every file of the batch on the card (SHA-256), just before importing it. The batch was just read, so Photos' own read will likely come from memory, and the card is read about once.
2. Import the batch into Photos.
3. Write the ledger (with the hashes) and `fsync` it. If this fails, nothing in the batch is removed.
4. For each photo, read the original from the Photos library (local only, no iCloud download) and hash it.
5. Delete the photo's card files only if every one of them matched. Anything that doesn't match, can't be read, or has no asset stays on the card and is counted in "Kept N".
6. Eject. Unmounting writes the deletions to the card. If ejecting fails, the app tells you to eject in Finder before pulling the card.

Also:

- Photos imported earlier and still on the card (in the ledger) get the same check-then-delete on the next insert. If one was deleted from Photos in the meantime, its card file stays.
- If the card is locked (write-protect switch), or full Photos access isn't granted, the import still runs but nothing is removed. The window says why.
- Only RAWs are imported. JPEGs (from RAW+JPEG shooting) stay on the card.
- Turn removal off in the menu: "Remove photos from card once verified in Photos".

**Risks to know about:**
- Once a photo is removed from the card, the Photos library on this Mac holds the only copy until iCloud uploads it (or a backup runs).
- Some cameras (notably Sony) keep an image database on the card and may ask to "recover" it after files are deleted on a computer. Fujifilm cameras just re-read the folder.

## Failures

A failed batch counts its photos as failed, and the import moves on to the next batch. If the card is gone, the import stops. With any failures, the card stays mounted, and the next insert retries only the missing photos.

## First real test

1. `./build.sh install`. Allow notifications.
2. Insert a card with a few photos you also have elsewhere. Allow both Photos prompts.
3. Check: the progress window appears, Photos shows the photos, the card ejects, and the window says "Checked each copy in Photos, then removed N from the card."
4. Reinsert the card. Its `DCIM` should no longer have those RAWs, and the window should say "No new photos".
5. Check that the server's archive receives the RAWs after iCloud uploads them.
6. Record the speed from the notification here. First card (31 Oct 2026): **59 MB/s** end to end, 374 RAFs (Fujifilm, ~50 MB each).

If Photos or Image Capture opens by itself when a card goes in, turn that off: in Photos' Import view, untick "Open Photos" for the card, or in Image Capture set "Connecting this device opens: No application".

## Later

- Report iCloud upload completion per card (needs a public API for upload state).
- Add an album per import date.

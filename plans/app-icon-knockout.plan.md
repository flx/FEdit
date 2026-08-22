# (app-icon-knockout) Replace the app icon with the red knockout-F artwork

**Risk tier: `trivial`.** Assets and one generator script; no Swift changes, no
behaviour, no SPEC. A plan file exists only because three things were decided
that a reader would otherwise have to re-derive from the PNGs.

## What shipped

- `art/fedit-4-knockout-1024.png` — the source, moved into the repo from the
  main checkout's root where it was untracked.
- `art/generate-appicon.py` — regenerates the seven PNGs from that source.
- The seven `FEdit/Assets.xcassets/AppIcon.appiconset/icon_*.png`, regenerated.
- `Contents.json` **unchanged**: its ten entries already map onto those seven
  filenames, and the filenames are the contract.

## Acceptance criteria

1. All seven sizes regenerate from the one source with a single command.
2. `Contents.json` is untouched and the ten mappings still resolve.
3. `xcodebuild` green — an asset catalog with a missing or mis-sized image is a
   build failure, so this is a real check, not a formality.
4. 16 and 32 pt are *looked at* and judged legible; that was the item's stated
   acceptance check and it cannot be automated.

## Decisions taken

**2026-08-22 — the F is a genuine KNOCKOUT and is shipped that way.**
Verified, not assumed: the source pixel at (330,500), inside the F's vertical
stem, is `(0, 0, 0, 0)` — fully transparent — against `(240, 80, 62, 255)` for
the red field and `(35, 38, 43, 255)` for the caret bar. The letterform is a
hole punched through the red square, not white paint. So the F takes the colour
of whatever the icon is composited over: white in Finder on a light background,
near-black in a dark Dock, teal over a teal wallpaper. Rendered over white,
`#ECECEC`, `#3A3A3C`, black and a saturated teal, the mark stays legible in all
five — dark-on-red has ample contrast. This matches the source's own filename,
so it is the artwork's intent rather than an export accident, and it is shipped
faithfully. *Recorded because it is a real behavioural difference from the icon
it replaces*, which was effectively opaque (opaque area 0.617 of the canvas
against a 0.647 full-square maximum, versus 0.529 for this one): the previous
icon looked identical everywhere, this one adapts. If that is ever unwanted, the
fix is to flatten the F to white in the source, and nothing else changes.

**2026-08-22 — no hand-tuned small sizes.**
The item allowed hand-tuning 16 and 32 if the thin caret bar or the F's counter
turned to mush. 32 pt is clean: the F's counter is open and the caret is a
distinct 2 px dark bar. 16 pt is softer — the caret survives as a 2 px column
that blends toward dark red rather than reading as a crisp bar — but the mark as
a whole is still legible, and 16 pt only appears in Finder list views. Rejected
hand-tuning because a hand-edited `icon_16.png` would become a second source of
truth that `art/generate-appicon.py` silently overwrites on the next run — a
trap worse than a slightly soft caret. If 16 pt ever needs its own artwork, it
needs its own *source* file and an explicit branch in the generator.

**2026-08-22 — Lanczos, and the source needs no re-inset.**
The source's opaque bounding box is (100,100)-(924,924) = **824×824** in a 1024
canvas, which is exactly Apple's macOS large-icon grid, so every size is a
straight proportional downscale. Lanczos rather than a box filter because the
artwork is hard-edged and the F's counter visibly softens at 32 pt and below
under bilinear.

**2026-08-22 — `art/` as the home, beside `scripts/`.**
The item left the location open. `art/` keeps the generator next to its input
and keeps non-shipping source art out of the app target's synchronized group.

## Out of scope

- Icon Composer / a layered `.icon` bundle. macOS 26 supports them, this app
  uses a flat `.appiconset`, that keeps working, and the artwork carries its own
  rounded square so the OS applies no squircle mask — which the previous icon
  already assumed.
- Document-type icons, and any in-app imagery.

## Verification note

After `scripts/install.sh`, the Dock and Finder can serve a cached old icon;
that is a caching artefact, not a failed install. Check the built bundle or
relaunch after `killall Dock`.

# Brand assets

| File | Use |
|---|---|
| `granola-logo-horizontal.png` | README header, docs, anywhere the wordmark is wanted |
| `granola-app-logo.png` | The mark on a transparent background — master artwork |
| `granola-app-icon.png` | What `Scripts/build.sh` turns into `Granola.icns` |

`granola-app-icon.png` is `granola-app-logo.png` composited onto a **full-bleed
opaque square** of `#0F0F12`, the app's own background colour. No rounded
corners, no transparency — deliberately.

Two reasons, both checked by asking macOS itself for the rendered icon
(`NSWorkspace.icon(forFile:)`) rather than guessing:

- **The dark ground is not decoration.** On a transparent background the mark's
  grey fader lanes and the pale end of the grain cloud have nothing to sit on,
  so on a light desktop the icon washes out to a few yellow specks — and macOS
  shows icons against whatever wallpaper the user chose.
- **The corners are the system's job now.** macOS 26 masks app icons into its
  own continuous-corner shape and adds the shadow. Supplying artwork that is
  already rounded gets it inset inside a light system bezel — an icon in a box.
  Full-bleed artwork fills the system shape edge to edge and looks native.

The trade-off: on macOS 14 and 15, which do not reshape icons, this renders as a
square. That is the right way round — the shaped result is correct on current
macOS, and a square is merely plain rather than broken.

To use different artwork, point `ICON_SRC` in `Scripts/build.sh` at it.

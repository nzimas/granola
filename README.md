<p align="center">
  <img src="Assets/Brand/granola-logo-horizontal.png" alt="Granola" width="620">
</p>

<p align="center">
  <strong>An 8-track granular synthesizer for macOS, built for the M-VAVE SMC-Mixer and M-VAVE SMC-Pad Pocket controllers.</strong>
</p>

Eight samples, eight grain clouds, eight faders. Push a fader and the playhead
walks through the sample; turn the encoder above it and the cloud opens up.
Everything runs on SuperCollider's audio server, which is embedded in the app —
nothing to install, nothing to configure.

Granola is free software, and so is the instrument it wants to be played on.

---

## Contents

- [Why this exists](#why-this-exists)
- [The hardware](#the-hardware)
- [Quick start](#quick-start)
- [The surface](#the-surface)
- [The one-knob filter](#the-one-knob-filter)
- [Projects](#projects)
- [Performance FX: 154 Airwindows effects](#performance-fx-154-airwindows-effects)
- [Reverb and delay](#reverb-and-delay)
- [Stereo, seriously](#stereo-seriously)
- [Watching the grains](#watching-the-grains)
- [Parameters](#parameters)
- [Loading samples](#loading-samples)
- [Audio device](#audio-device)
- [Building from source](#building-from-source)
- [How it is put together](#how-it-is-put-together)
- [Self-test](#self-test)
- [Status](#status)
- [Licence](#licence)

---

## Why this exists

This project started with a control surface, not with a synth.

The M-Vave SMC-Mixer arrived on my desk as a cheap Bluetooth fader box, and the
first thing I noticed was what the faders *wanted* to do. A fader is not a
volume control by nature. It is a position — an absolute, visible, two-handed
position that your fingers can find without looking. Point at a place in a
sample and the fader is already the right shape for the job: **the fader is the
playhead**.

Once you see that, the rest follows quickly. Eight faders means eight playheads,
which means eight samples being granulated at once, which is a multitrack
granular instrument. The encoders above the faders open and close the clouds.
The buttons under them decide which part of the cloud each encoder is holding.
Nothing here is a metaphor for a DAW; the surface *is* the instrument, and the
screen is a readout.

That is the whole philosophy:

- **Hands before menus.** Anything you reach for mid-performance lives on the
  hardware. Configuration — fade times, wet blends, envelope shapes — lives in
  the app, where it belongs, because you set it once and then play.
- **The controller is the source of truth.** When the hardware and the app
  disagree, the hardware wins. It owns its own LEDs and latches in the modes
  Granola uses, so the app follows it rather than fighting it.
- **Stereo is not negotiable.** Granular synthesis has a long tradition of
  quietly summing your beautiful stereo recording to mono and handing you a pan
  knob as an apology. Granola never does this. See
  [Stereo, seriously](#stereo-seriously).
- **Gestures, not switches.** Effects swell in over seconds. Routing crossfades
  instead of jumping. Nothing in a performance should click.

It runs standalone. You can drive every parameter with a mouse. But that is a
different, worse instrument, and I would not recommend meeting it that way.

---

## The hardware

Two controllers, both from M-Vave, both Bluetooth LE, both battery powered, and
both absurdly cheap. I bought mine on AliExpress; they turn up on the usual
retail sites too.

| | **SMC-Mixer** | **SMC-PAD Pocket** |
|---|---|---|
| What I paid | **~€40** | **~€20** |
| Controls | 8 faders, 8 **endless** encoders, 4 buttons per strip, global row | 4×4 pad grid |
| Power | Internal rechargeable battery | Internal rechargeable battery |
| Connection | Bluetooth LE | Bluetooth LE |
| Mode Granola needs | **DAW mode** | **CC mode**, channel 4, CC 1–16 |

These things punch enormously above their weight. Two details in particular:

**The encoders are endless.** At forty euros, that is a genuine luxury. Endless
rotaries mean the controller never has to "catch up" to a value it does not
know: turn the knob and the parameter moves from wherever it already is. It is
what makes Granola's macro system possible at all — one encoder can move four
parameters at once, in normalised space, without any of them jumping.

**Both run on internal batteries, over Bluetooth.** No hub, no power brick, no
cable to the laptop. The whole instrument is a laptop, two small boxes and
nothing else — which matters more than it sounds like it should, because it
changes where you are willing to play it.

They are not perfect, and Granola does not pretend otherwise. The faders are
7-bit. In CC mode the device owns its LEDs and the host cannot address them.
Shift transmits nothing at all, so Granola borrows a button to stand in for it.
Every one of these limits is documented in [The surface](#the-surface) rather
than papered over, because knowing where the edges are is part of playing an
instrument.

### Do I need them?

No — and yes. Granola launches without either controller and says so in its
header rather than failing silently. Every parameter is on screen.

But the mapping *is* the instrument. Eight faders under your fingers is not a
convenience layer over a granular engine; it is the reason the engine is shaped
the way it is. For sixty euros total, I would rather you played it properly.

---

## Quick start

### 1. Get the app

Download the latest `Granola.app` from the
[**Releases**](https://github.com/nzimas/granola/releases) page. It is fully
self-contained — SuperCollider, its plugins and every Airwindows effect are
already inside. Nothing else to install.

The app is unsigned, so the first launch needs one extra step:

```bash
xattr -dr com.apple.quarantine /Applications/Granola.app
```

Then open it normally. (Or build from source — see [Building from source](#building-from-source).)

### 2. Connect the controllers

Pair the SMC-Mixer over Bluetooth, then put it in **DAW mode**: hold `Shift` and
press `Left`/`Right` on the device itself. There is no MIDI command for this.
The header shows `SMC-Mixer · DAW mode` in green once it is talking.

Pair the SMC-PAD Pocket and load a preset that sends **CC 1–16 on channel 4** as
toggles (`smc-pad-pocket-preset1.spp.spp` in this repo is the one used during
development).

Granola works without either; the header will just say so.

### 3. Make a sound

1. Click a track's waveform area — a **file dialogue** opens. Load any WAV or
   AIFF. Stereo files stay stereo.
2. Press **Play** on the controller (or `Space`). The track starts granulating
   immediately.
3. **Push that track's fader** to move the scrub head through the sample.
4. **Turn its encoder** to change grain size — the lit yellow button on that
   strip says that is what the encoder holds. Light **DENS**, **JIT** or
   **PITCH** as well and the encoder moves all of them together.
5. **Hold Shift + turn any encoder** for that track's one-knob DJ filter:
   left for low-pass, right for high-pass, centre is neutral.
6. Raise **RVB** or **DLY** (global buttons 4 and 5 take the encoders over) to
   feed the reverb and delay.
7. Tap the pad grid's bottom row to throw a random **Airwindows chain** at the
   tracks you select on its top two rows.

To keep what you made: **hold Shift and press Play** to open the project layer,
then **hold** one of the nine slot buttons to save. Tap to recall.

---

## The surface

How the **SMC-Mixer** maps onto the instrument: eight strips, a global row, and
the rules that make the hardware and the app agree. (The **SMC-PAD Pocket**'s
4×4 grid is covered under
[Performance FX](#performance-fx-154-airwindows-effects), since that is mostly
what it drives.)

The mixer must be in **DAW mode** — hold `Shift` and press `Left`/`Right` on
the hardware. There is no MIDI command for this; the app detects CC mode and
says so in the header rather than silently failing to light anything.

### Channel strips

| Hardware | Granola |
|---|---|
| Fader 1–8 | **Scrub head** — position in the sample (0…1) |
| Encoder 1–8 | Adjusts whichever macro parameters that strip has lit |
| Button 1 (top, "Mute") | Toggle **Grain Size** |
| Button 2 ("Solo") | Toggle **Density** |
| Button 3 ("Rec") | Toggle **Scatter** |
| Button 4 (bottom, "Select") | Toggle **Pitch** |

Light more than one button on a strip and its encoder becomes a **macro**,
moving every lit parameter together in normalised space. Light **none** and the
encoder falls through to **Drift** rather than going dead — Drift is the one
cloud control with no button of its own, so an unlit strip still has something
useful under the knob.

**Hold Shift and turn an encoder** for that track's one-knob filter (below),
whatever the strip buttons or the global selectors are set to.

The app's accent colours match the hardware's physical LED colours, top to
bottom — **yellow** (grain size), **blue** (density), **red** (scatter),
**white** (pitch) — so the screen reads as a picture of the surface in front of
you.

### Encoder selectors

Global buttons 2–5 take the encoders over for mixing. They are the latching
buttons, so their LEDs hold:

| Button | Encoders become |
|---|---|
| 2 — Stop | **Volume** — per-track level |
| 3 — Record | **Pan** — per-track stereo placement, centred by default |
| 4 — Rewind | **Delay send** — per-track, starts at zero |
| 5 — Fast Forward | **Reverb send** — per-track, starts at zero |

They are selectors, not transport: engaging one leaves the other, and pressing
the lit one hands the encoders back to the strip macro buttons. The header shows
`ENCODERS → VOLUME` / `→ PAN` whenever a selector is active, the encoder arcs
recolour, and pan draws outward from centre. Pan reads as `L64 … C … R64`.

The centre detent catches pan only when a turn passes **through** centre. A
detent defined as "within X of centre" is wider than one encoder tick, so it
swallows every tick and the knob appears dead — which is exactly how it first
shipped.

**Pan and Spread are different things**, and the engine treats them that way:

- **Pan** is an equal-power stereo balance (`Balance2`) applied to the whole
  cloud. At -1 the track sits fully in the left speaker, at +1 fully in the
  right, at 0 the source's own image passes through untouched.
- **Spread** scatters individual grains around the stereo field (`Rotate2`),
  each keeping its own stereo content.

`Rotate2` is deliberately *not* used for pan: it rotates the field rather than
moving it, which makes hard-left and hard-right sound nearly identical.

Pan is excluded from **Randomise** — placement is a deliberate choice, so a dice
roll should not move it.

The four strip buttons are entirely repurposed as macro toggles, so mute and
solo live in the app UI (the `M` and `S` buttons at the bottom of each strip).

> The physical button order is **not** the classic Mackie layout — M-Vave
> inverted the top three. Granola maps by physical position, top to bottom.

### Global row

| Hardware | Granola |
|---|---|
| Play | **Play / Stop** — one latching toggle, lit means playing |
| Stop | **Encoders → Volume** (selector) |
| Record | **Encoders → Pan** (selector) |
| Rewind | **Encoders → Delay send** (selector) |
| Fast Forward | **Encoders → Reverb send** (selector) |
| Bank Left | Scatter scrub heads randomly |
| Bank Right | Select next track |
| Cursor Up / Down | Randomise / reset the selected track |
| Cursor Left | Select previous track |
| **Cursor Right (rightmost)** | **SHIFT** — a modifier, never an action |
| **Shift + Play** | Toggle the **project layer** |

**Only Play does what its legend says.** Every other button on this row has been
repurposed, and more will change. The mapping lives in one table —
`GranolaModel.globalRow` — which the press handler, the LED refresh and the
app's on-screen row all read, so reassigning a button is a single row and the
window cannot drift from the surface.

**Only the first five buttons latch in the device's firmware**; buttons 6–11 are
momentary and their LEDs cannot be held on. That is why all four encoder
selectors sit on buttons 2–5, and why transport collapsed into a single latching
Play/Stop toggle on button 1 — a selector stranded on a momentary button can
only flash, which is exactly how the reverb selector behaved before this
arrangement.

While the project layer is active, the eight buttons from Rewind to Cursor Right
are project slots instead of the above.
| Cursor Left / Right | Select previous / next track |
| Cursor Up / Down | Randomise / reset the selected track |

Output recording, rewind-all and grain-shape cycling lost their hardware buttons
to the encoder selectors. All live in the app's global bar (**REC OUT**,
**REWIND**, **SHAPE ±**) and recording is in the Transport menu (`⌘R`). Scatter
kept a place on the surface because it is a performance gesture, where
grain-shape cycling is a setup action.

`Shift` transmits no MIDI and is unavailable to the app — it selects the
device's mode locally, and flashes to indicate low battery. It also suppresses
any button pressed with it, so Shift-combinations cannot be detected at all.
`Scripts/midimon` is a standalone monitor for checking this sort of thing:

```bash
swiftc -O Scripts/midimon/main.swift -o build/midimon && ./build/midimon
```

### LED feedback

The device is stateless in DAW mode: the host owns every LED. Granola asserts
LED state, diffs writes, and batches them (~40 messages per burst, 20 ms apart)
because BLE MIDI is narrow enough that flooding it drops the link. Full state is
re-sent on reconnect, since the device retains nothing.

The LED row above the faders is a **null / soft-takeover indicator** and is not
directly addressable. Granola drives it by reporting the app's scrub position as
track volume, so those LEDs flash when the physical fader disagrees with the
app's scrub head — which is exactly when you want to know.

---

## The one-knob filter

Every track has a **DJ filter** in the style of the Novation Circuit machines:
one control, centre-neutral, covering cutoff, resonance and filter *mode* at
once. Hold **Shift** and turn that track's encoder.

- Turn **down** and a low-pass sweeps from 20 kHz to 120 Hz.
- Turn **up** and a high-pass sweeps from 20 Hz to 7 kHz.
- Resonance rises as you leave centre, so the further it goes the more it sings.
- Centre has a detent and is genuinely neutral — measured at ±0.0 dB and no
  change in spectral centroid.

From the first shift-held tick, that strip's readout switches to the filter
(`LP 62` / `FLT C` / `HP 34`) and its encoder ring goes bipolar, and stays there
until Shift is released — not until the encoder stops. Only the strips you
actually touched change; the rest keep showing their selector.

> Resonance peaks around three quarters of the travel rather than at the stop.
> At the extreme the resonant peak sits on top of whatever little is left in the
> band, which reads as a level jump rather than as character: the first version
> was **+7 dB louder** at the low stop. It now falls away toward both ends, as a
> filter sweep should.

---

## Projects

Eight slots hold the whole state of the machine: every track's sample and
parameters, macro button states, mute/solo, grain shapes, master level, and all
delay and reverb settings.

**Scrub position is deliberately not saved.** Every head reloads at zero, so the
performer knows the faders belong at the bottom and the hardware and the app
start in agreement. Restoring positions would leave eight physical faders
wherever they happened to be, silently disagreeing with the app until each was
touched. On load, Granola also reports position zero to the controller, which
makes the fader null LEDs flash until the faders are actually pulled down.

### On the controller

**Shift + Play** toggles the project layer. Buttons **2–10** then become slots
**1–9**:

- **Tap** a slot — load that project
- **Hold** a slot (0.6 s) — save the current state into it

**Button 11 is never a slot.** It is the shift modifier and nothing else, in
every layer and in both directions. It briefly doubled as slot 10, which made
that slot impossible to *save* into: holding it to save was indistinguishable
from holding it to shift. Nine reliable slots beat ten where one is read-only.

Saved projects are migrated automatically when this mapping changes — each one
keeps the button it was saved under wherever possible, and each migration runs
once and leaves a marker behind.

In the layer every other LED goes dark, so there is no ambiguity about what a
press will do. Lit slots hold a project; unlit ones are empty. Play and Stop
keep showing transport state and keep working.

> **The device's real Shift cannot be used.** It transmits nothing, and it
> suppresses whatever is pressed with it — verified on the hardware with
> `Scripts/midimon`, where a Shift-held press produced no MIDI at all. It only
> switches DAW/User mode locally.
>
> So the **rightmost button on the bottom row (Cursor Right)** stands in for it.
> It is momentary, which is what a held modifier needs, and it performs no
> action of its own in either direction. **Shift + Play** opens the project
> layer.
>
> An earlier design used a Play + Stop chord, which died when Stop became the
> volume selector. The stand-in is better regardless: it costs no transport
> latency, where the chord needed a 140 ms window to disambiguate.

### In the app

The **PROJECTS** panel (first in the inspector) mirrors the slots, with a
Load/Save selector because a mouse click has no tap-versus-hold equivalent. The
slot the current state came from is drawn in **red with a glow** — deliberately
not the panel's yellow, so "occupied" and "this is the one you loaded" never
read as the same thing — and saving **blinks** that slot white twice, because
writing a project is otherwise too fast to see.
Right-click a slot to save, load or clear it. The **PROJ** button in the global
bar toggles the same layer as the chord.

Projects are JSON in `~/Library/Application Support/Granola/Projects/`, written
atomically. A missing sample is reported on the track rather than failing the
whole load, and samples are resolved by bookmark first so a project survives its
files being moved.

---

## Performance FX: 154 Airwindows effects

154 Airwindows effects, compiled into the app as SuperCollider UGens.

### Why not VST

Airwindows ships as VST/AU, and scsynth cannot host either. Rather than bundle a
plugin host, `Scripts/airwindows/vstshim/audioeffectx.h` provides a ~100-line
stand-in for the parts of the VST2 SDK these plugins actually touch — a base
class with no-op setup calls, `getSampleRate`, and string helpers. The upstream
`.cpp` and `.h` files then compile **completely unmodified**, so the DSP, and
therefore the sound, is exactly as published. MIT licensed.

```bash
./Scripts/fetch-airwindows.sh     # once
./Scripts/build-airwindows.sh     # -> vendor/airwindows/GranolaAirwindows.scx
```

`generate.py` emits one UGen wrapper per plugin, the sclang UGen classes, a
SynthDef per effect, and a JSON manifest of parameter names and defaults — 154
effects' worth, without a single line of Airwindows source being edited.

### Loudness

An effect should change the sound, not the volume. Distortion in particular
tends to arrive as a gain stage, and some effects do the opposite and smother
the source. Granola holds level in three places:

- **Per link** — each link tracks its dry and wet envelopes and scales the wet
  to match. The correction is deliberately **asymmetric**: a loud wet signal is
  pulled down as far as needed, but a quiet one is only lifted 4×. An effect
  that removes energy is supposed to, and dragging a notch or gate back to full
  level just amplifies what it took out — which compounds badly down a chain.
- **Across the whole chain** — a node at the head publishes the incoming level
  and the terminator matches it. Per-link correction alone is not enough: with
  eight links stacked it still drifted **+7.5 dB**, because small errors
  multiply. Only an end-to-end measurement holds a chain of arbitrary length.

  This one tracks **loudness, not events**: long time constants (0.5s / 1.0s
  followers, 1.5s lag) and a gentle ±6 dB bound. Fast followers made it dive
  ~20 dB whenever a track was routed in or out — the chain input changes at
  once while effect tails and the reverb/delay feeding the same bus keep the
  output up, so the ratio collapses for a moment. Routing a track is a
  performance gesture and must not duck the mix.
- **A zero-latency soft clip** at the chain output, for transients no envelope
  follower catches. It must be zero-latency: `Limiter.ar` delays by *twice* its
  lookahead — measured at 959 samples (19.98 ms) with an NRT impulse probe —
  which left the performance path 20 ms behind the direct one. Crossfading a
  track between them then blended the same audio 20 ms apart, and that comb
  filter was audible as a brief smothering every time a track was selected.
  The master limiter still protects the output, and it delays the whole mix
  equally so nothing is left misaligned.

Measured across randomly assembled chains of 8–10 links:

```
dry                RMS 0.03501   0.0 dB
chain (8 links)    RMS 0.03513  +0.0 dB
chain (10 links)   RMS 0.03880  +0.9 dB
chain (8 links)    RMS 0.03378  -0.3 dB
worst deviation: 0.9 dB
```

Auto gain matching can be switched off in the Effects tab if you want an effect
to hit as hard as it wants to.

### Chains

The bottom pad row holds **four chain slots**. Toggling one on assembles a
**random chain of 1–4 effects** with randomised parameters; roughly one link in
three also gets an LFO on one of its parameters. Dry/wet is biased upward so a
random link is always audible.

Chains **swell in over 5 seconds** by default and fade out over the same time
when a slot is released, so engaging one is a gesture rather than a switch. The
fade time and the wet blend are configurable in the Effects tab — app-only,
since the controllers are performance instruments rather than config surfaces.

New links are given a **40% wet blend**: enough to transform clearly, not
enough to bury the source. Where a plugin has its own Dry/Wet it is run fully
wet, so the link's `mix` is the single blend control rather than two in series.

Slots run **in series, in the order they were pressed**. This falls out of the
graph rather than being managed: every link reads the performance bus and
`ReplaceOut`s to it, and links are inserted immediately before a permanent
terminator node. Series order *is* node order, so adding a slot extends the
chain and removing one lets it close up — no re-patching, no clicks, because
each link fades its own wet/dry blend.

The top two pad rows select **which tracks** feed the chain. Routing is a
**crossfade, not a switch**: each strip writes permanently to both the mix and
the performance bus, and selecting a track fades between them over 80ms.
Reassigning the output bus instead changes the signal in a single sample, which
is audible as a click every time a track is selected. Both paths reach the mix,
so a track is never louder or quieter part-way through the move.

The **Effects tab** mirrors the 4×4 surface and lists every link in signal
order with live parameter controls. It is a mirror, not a master: the pads are
CC toggles that latch in hardware, so the device owns the state and the app
follows.

| Pads | CC (channel 4) | Role |
|---|---|---|
| bottom row | 1–4 | chain slots 1–4 |
| second row | 5–8 | grain envelope: Gaussian, Percussive, Plateau, Reverse |
| third row | 9–12 | tracks 1–4 through FX |
| top row | 13–16 | tracks 5–8 through FX |

The envelope row is a **global** switch — one row of four pads serving eight
tracks, so it applies to all of them. Per-track shapes are still available in
the app's track panel. The four shapes are mutually exclusive but the pads latch
independently in hardware and cannot be told otherwise, so a pad turning *on*
selects that shape and a pad turning off is ignored: the last one pressed wins,
which is what the gesture means even when several pads are lit.

Verified end to end — a 3-slot press producing a 9-link chain:

```
chain: uLawEncode -> Compresaturator -> AutoPan -> StereoDoubler -> ZAcidLowpass
       -> AutoPan -> TapeFat -> Isolator3 -> PitchNasty
dry  RMS 0.03335   brightness  569 Hz
fx   RMS 0.09260   brightness 1325 Hz
difference 289% of dry
```

---

## Reverb and delay

Both are send effects fed from every track. **All track sends start at zero** —
the effects are set up to be immediately usable, and you dial them in per track.

### Reverb — JPverb

Julian Parker's Dattorro-style modulated plate, from sc3-plugins. Chosen over
the stock options deliberately: `FreeVerb2` is a small fixed comb/allpass bank
that thins out on long tails, and `GVerb` is mono-in and prone to booming.

Wrapped with a pre-delay (JPverb has none), an input high-pass to keep rumble
out of the tank, and a mid/side width control. Exposed: decay (0.1–30 s), size,
damping, pre-delay, modulation depth, high-frequency decay, width, level.

Defaults: 3.5 s decay, size 1.6, moderate damping, 25 ms pre-delay — long and
lush without swamping everything the moment a send comes up.

### Delay — stereo, up to 10 seconds

Built from `DelayC` rather than `Greyhole`, because the goal is precise control
rather than diffusion: independent left/right times, and a continuously variable
feedback cross-blend.

| Control | Effect |
|---|---|
| Time L / Time R | Independent, 1 ms – **10 s** per side |
| Feedback | Up to 0.98 |
| Cross | 0 = parallel stereo delays, 1 = **ping-pong**, and everything between |
| Damp / Blur | Low-pass in the loop; allpass diffusion that smears repeats into a wash |
| Mod | Modulates the delay time — `DelayC` interpolation turns that into tape-style pitch drift |
| Width | Mid/side on the output |
| Freeze | Holds the loop at unity feedback and stops new material entering |

Defaults: 375 ms / 500 ms, feedback 0.45, cross 0.35 — a musical stereo bounce.
The `stereo` / `ping-pong` button is a shortcut for cross 0 and 1.

Changing the 10 s ceiling means changing `DelayC`'s `maxdelaytime` in
`Scripts/synthdefs.scd` **and** `GranolaModel.maxDelayTime` together.

---

## Stereo, seriously

`GrainBuf` reads **mono** buffers only. The path of least resistance is to sum
L+R to mono and fake stereo with a pan control; Granola does not do that.

Each track loads into a **buffer pair** (`/b_allocReadChannel` into `bufL` and
`bufR`). Two `GrainBuf`s share **one** trigger, and `trig`, `dur`, `rate` and
`pos` are computed once and fed to both — so the channels stay sample-aligned
and the source's stereo image and phase relationships survive granulation.
Grains are then placed with `Rotate2`, which rotates the stereo grain in the
field rather than replacing its content. Mono files point both buffers at the
same data, so they need no special case.

This is verified, not assumed:

```bash
./Scripts/verify-stereo.sh
```

It renders a file with 300 Hz on the left and 900 Hz on the right, granulates it
through the real app code path, and checks the recording. A pass requires the
output channels to remain decorrelated:

```
dominant L      301 Hz
dominant R      900 Hz
correlation     -0.0000
PASS: output is genuinely stereo (channels carry distinct content)
```

Files with more than two channels currently load their first stereo pair; the
UI says so on the track rather than dropping the content silently.

---

## Watching the grains

Each track's waveform window draws its grain cloud live: every grain is a
horizontal bar starting where it scattered to and running as long as it reads,
fading through that track's actual envelope shape as it ages. Density shows up
as how crowded the picture is, grain size as how long the bars are, and the
scatter window as a tinted region around the scrub head.

The server does not report individual grains — at 200 grains a second it should
not — so the picture is reconstructed from the same parameters the voice is
running on. Grain *n* is the one that fired at `n / density`, which makes the
whole cloud a pure function of the clock: no particle list and no per-frame
state to drift out of sync. It runs at 30 fps, only on playing tracks, and sits
outside the `Equatable` waveform canvas so the expensive layer never redraws.

---

## Parameters

Per track: position, grain size, density, scatter, drift, glide, scan, pitch,
pitch spray, pitch quantise, reverse, freeze, DJ filter, low-pass, high-pass,
resonance, pan, stereo spread, level, reverb and delay sends.

**Scatter** is a *percentage of the loaded sample*, not a number of seconds, so
the same knob position scatters the same proportion of a half-second hit and a
ten-second field recording. It runs on a cubic curve: millisecond scatter stays
reachable at the bottom (knob 0.1 is 8 ms on an 8 s sample) while the rest of
the travel spreads evenly.

> It began as seconds on an exponential curve, and that was wrong twice over.
> Exponential mapping needs a non-zero floor, so four fifths of the rotation sat
> in values too small to hear and the last fifth jumped straight to the whole
> file; and being absolute, it could never cover a long sample at all. Granulating
> a 200 Hz→8 kHz sweep turns the scatter window into a frequency band you can
> read directly, which is how the new curve was checked against prediction.

**Grain envelope shape** — the amplitude contour applied to every individual
grain. Four of them: **Gaussian** (soft and round, the default), **Percussive**
(fires hard and decays), **Reverse** (swells into each grain) and **Plateau**
(a flat-topped Tukey window that keeps more of the source's own character).
Set it per track in the track panel, or globally from the pad grid.

> The shapes are uploaded as buffers at boot. The allocation and the fill must
> be separated by a `/sync`:
> `/b_alloc` is asynchronous while `/b_setn` runs immediately, so sending them
> together silently discards the data and leaves a buffer of zeros — which
> windows every grain to nothing, and every buffer-backed shape was silent.
>
> Raw values are not renumbered when shapes are added or removed: projects store
> the shape as an integer and the buffers are addressed by it.

---

## Loading samples

Click a track's waveform slot (or its name, to replace what's there) to open a
standard file dialog. Right-click a slot for Load / Clear / Reveal in Finder.
Drag-and-drop also works, but nothing depends on it.

Non-native formats (mp3, m4a) are transcoded once to a float WAV in the app
cache; WAV, AIFF, FLAC and CAF are passed to the server untouched.

---

## Audio device

Granola pins `scsynth` to the system's **default output device** with `-H`.
This is not cosmetic: left to itself, scsynth also opens the default *input*
device, which makes macOS raise a microphone permission prompt for an app that
only granulates files. An output device reports zero input streams, so nothing
is opened and no prompt appears.

The consequence is that the device is chosen at boot. If you change the system
output device, use **Restart engine** in the header to follow it.

---

## Building from source

```bash
./Scripts/build.sh
```

Produces `build/Granola.app`. That is the whole build — every dependency is
vendored in this repository, so a fresh clone builds without fetching anything.
Requires SuperCollider installed at `/Applications/SuperCollider.app` (override
with `SC_APP=...`) and a Swift 5.9+ toolchain. Full Xcode is not required — the
Command Line Tools are enough.

```bash
open build/Granola.app
```

### sc3-plugins

The reverb is JPverb, which lives in sc3-plugins. The built plugins and class
files are vendored under `vendor/sc3-plugins/`, so a normal build needs nothing
extra. To rebuild them (new SuperCollider version, or a different
architecture):

```bash
./Scripts/fetch-sc3-plugins.sh
```

It clones SuperCollider at the tag matching your installed `scsynth` — the
plugin ABI has to match — then clones and compiles sc3-plugins against it.
There are no official prebuilt binaries for current SuperCollider on Apple
Silicon, and compiling from source beats running downloaded binaries.

Two things to know:

- `NCAnalysisUGens` does not compile with modern clang (a chained comparison in
  `SMS.cpp`). It is an analysis suite Granola does not use, so the build skips
  it and carries on. All 171 other plugins build.
- The vendored binaries are **arm64 only**. For an Intel or universal build,
  run `ARCHS="arm64;x86_64" ./Scripts/fetch-sc3-plugins.sh`.

`sclang` is pointed at an explicit class-library config listing SuperCollider's
own library plus `vendor/sc3-plugins/classes`, so builds are reproducible and
your `~/Library/Application Support/SuperCollider/Extensions` is never touched.

---

## How it is put together

> Everything from here on is implementation detail — worth reading if you are
> building, extending or debugging Granola, and safely skippable if you just
> want to play it.

```
Sources/Granola/
  Engine/
    OSC.swift            OSC 1.0 encode/decode
    SCServer.swift       embedded scsynth process + UDP link
    GranolaEngine.swift  buses, groups, buffers, nodes
    SampleLoader.swift   decoding, transcoding, waveform overview
  Model/
    Parameters.swift     every parameter, its range and curve, in one table
    TrackModel.swift     per-track state
    ProjectStore.swift   eight save slots on disk
    GranolaModel.swift   single source of truth
  MIDI/
    SMCMixer.swift       CoreMIDI driver for the control surface
  UI/                    SwiftUI control surface
Scripts/
  synthdefs.scd          SynthDef sources (compiled at build time)
  build.sh               builds and signs Granola.app
  verify-stereo.sh       end-to-end stereo regression test
```

`sclang` is never run at runtime. SynthDefs are compiled to `.scsyndef` at build
time and loaded by `scsynth` with `/d_loadDir`.

Every mutation funnels through `GranolaModel`. One path to change a value means
one place that pushes it to the audio server and one place that reflects it back
to the hardware LEDs, so the surface and the UI cannot drift apart.

Node, bus and buffer numbers are fixed rather than allocated, which makes the
graph reproducible and lets any part of the app address a track's synth without
holding a reference to it.

### Signal flow

```
granolaVoice   -> trackBus[n]        grain cloud, one per track
granolaStrip   -> mixBus | perfBus   level / mute / metering
                  + per-track sends  reverb and delay, independent per track
granolaReverb  -> perfBus            JPverb        \  master effects run
granolaDelay   -> perfBus            stereo delay  /  BEFORE the chain
awfx_*         -> perfBus in place   Airwindows chain (series = node order)
granolaPerfOut -> mixBus
granolaMaster  -> hardware out       gain, limiter, metering, recorder tap
```

The **master reverb and delay run before the Airwindows chain**, and their
output feeds it — so the chain mangles the tails as well as the routed dry
tracks. Per-track sends stay fully independent, since the send is taken at the
strip, upstream of everything.

Sends are post-fader, so muting a track also mutes what it feeds the effects.



---

## Self-test

```bash
Granola.app/Contents/MacOS/Granola --self-test <input.wav> [output.wav] [--pan <-1…1>]
```

Boots the engine, loads the file into track 1, exercises the encoder selectors,
granulates and records — through the shipping code path, not a test
reimplementation.

The encoder checks drive **one tick at a time**, because that is what the
hardware sends. Verifying with a single large jump hides bugs that only appear
at real encoder resolution.

`--pan` forces a pan value before recording, so the balance of the result proves
the control reaches the audio rather than just the model:

```
pan -1.0 -> RMS left 0.06838   RMS right 0.00000
pan  0.0 -> RMS left 0.04799   RMS right 0.03021
pan  1.0 -> RMS left 0.00000   RMS right 0.04103
```

`--delay-send` / `--reverb-send` do the same for the effects, so their
contribution can be measured against a dry pass.

Run the whole thing against real material with:

```bash
./Scripts/verify-stereo.sh /path/to/sample.wav
```

With real material the check changes: instead of demanding decorrelated output,
it compares source and result and requires that **granulation did not narrow the
image**. Real recordings range from wide to dual mono, so an absolute
correlation threshold is the wrong test for them — but "whatever width went in
comes out" holds for any source. The self-test sweeps the read head across the
whole buffer during the recording so the two measurements cover the same audio.

---

## Status

Working: engine embedding and boot, stereo granulation, sample loading via file
dialog / drag-and-drop with transcoding, waveform display with scrub, all
parameters, per-track and master metering, JPverb reverb and a 10-second stereo
delay with per-track sends, master limiter, output recording, the full
SMC-Mixer surface with LED feedback, and the self-test.

Also working: nine project slots with save/load from both the controller and
the app, the performance FX section, the pad grid, per-track DJ filters and the
live grain animation.

Not yet built: live audio input granulation, per-track modulation sources,
tempo-synced delay times, project naming, and multichannel (>2) sources.

---

## Licence

Granola's own source code is released under the **MIT Licence** — see
[`LICENSE`](LICENSE) for the full text.

```
Copyright (c) 2026 nzimas
```

### Third-party components

Granola stands on other people's work. The app bundle ships the following, and
each keeps its own licence:

| Component | What it does here | Licence |
|---|---|---|
| [SuperCollider](https://github.com/supercollider/supercollider) (`scsynth` 3.14.1 + UGen plugins) | The entire audio engine. Runs as a child process, driven over OSC/UDP. | **GPL-3.0-or-later** |
| [sc3-plugins](https://github.com/supercollider/sc3-plugins) | `JPverb`, the master reverb. | **GPL** (varies by plugin: GPL-2.0-or-later / GPL-3.0 — see upstream) |
| [Airwindows](https://github.com/airwindows/airwindows) by Chris Johnson | ~100 effects in the performance FX chains, compiled unmodified into SC UGens. | **MIT** |
| [libsndfile](https://github.com/libsndfile/libsndfile) | Audio file reading inside `scsynth`. Dynamically linked. | **LGPL-2.1-or-later** |
| Swift standard library / SwiftUI / CoreMIDI / AVFoundation | The app itself. | Apache-2.0 with Runtime Library Exception; Apple system frameworks |

Full licence texts and per-component detail (versions, modifications, source
locations) are in [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md) and
[`licenses/`](licenses/), and ship alongside the app in every release.

**On the GPL components:** Granola is self-contained by design — the
dependencies are vendored in this repository and bundled inside the app, and
that is the point. The MIT licence covers Granola's own code; the vendored and
bundled GPL components stay under the GPL, unmodified, exactly as their authors
intended. Granola drives `scsynth` as a separate process over a UDP socket
rather than linking against it.

Complete corresponding source for every GPL component is the upstream project
linked above at the version named in
[`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md); nothing is patched, and
`Scripts/fetch-sc3-plugins.sh` reproduces the vendored build exactly. Keep that
notice and `licenses/` with the app if you pass it on.

### Hardware

The **M-Vave SMC-Mixer** and **SMC-PAD Pocket** are products of
[Cubeternet / M-Vave](https://www.cube-tec.net/). Granola is not affiliated with
or endorsed by them; the mappings here were worked out by observation, and the
hardware's limits (7-bit faders, momentary versus latching buttons, LEDs the
host cannot address in CC mode) are documented above rather than papered over.

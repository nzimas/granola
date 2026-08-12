# Third-party licences

Granola's own source code is MIT (see [`LICENSE`](LICENSE)). The **distributed
application bundle** additionally contains the following third-party software,
each under its own licence. Full licence texts are in [`licenses/`](licenses/).

---

## SuperCollider — `scsynth` and UGen plugins

- **Licence:** GNU General Public License, version 3 or later
  ([`licenses/GPL-3.0.txt`](licenses/GPL-3.0.txt))
- **Version bundled:** 3.14.1 (tag `Version-3.14.1`)
- **Upstream:** https://github.com/supercollider/supercollider
- **Modifications:** none. The binaries are built unmodified from the tagged
  upstream source.

`Granola.app/Contents/Resources/SuperCollider/scsynth` runs as a **separate
process**, driven by Granola over a UDP socket using Open Sound Control.
Granola does not link against it.

Complete corresponding source is available from the upstream repository at the
tag named above.

## sc3-plugins — `JPverb` and the rest of the UGen set

- **Licence:** GNU General Public License (version varies by plugin: GPL-2.0-or-later
  or GPL-3.0 — see the individual plugin directories upstream)
- **Upstream:** https://github.com/supercollider/sc3-plugins
- **Modifications:** none. `Scripts/fetch-sc3-plugins.sh` clones upstream and
  compiles it against the matching SuperCollider version. `NCAnalysisUGens` is
  skipped because it does not compile with modern clang; Granola does not use it.

## libsndfile

- **Licence:** GNU Lesser General Public License, version 2.1 or later
  ([`licenses/LGPL-2.1.txt`](licenses/LGPL-2.1.txt))
- **Upstream:** https://github.com/libsndfile/libsndfile
- **Modifications:** none. Bundled as a **dynamically linked** shared library
  (`Contents/Resources/Frameworks/libsndfile.dylib`), so it may be replaced
  with a compatible build.

## Airwindows

- **Licence:** MIT
- **Author:** Chris Johnson
- **Upstream:** https://github.com/airwindows/airwindows
- **Modifications:** the DSP sources are compiled **unmodified**. Granola adds
  its own wrapper (`Scripts/airwindows/`) that presents each effect as a
  SuperCollider UGen, including a shim standing in for the VST SDK headers so
  no proprietary SDK is needed.

## Swift standard library, SwiftUI, CoreMIDI, AVFoundation, CoreAudio

- **Licence:** Apache-2.0 with Runtime Library Exception (Swift); Apple system
  frameworks under Apple's own terms.

---

## If you redistribute the bundle

The GPL and LGPL obligations travel with the binaries. In practice that means
keeping this notice and the texts in `licenses/` alongside the app, and being
able to point recipients at the corresponding source — the upstream URLs and
versions above are sufficient, since nothing is modified.

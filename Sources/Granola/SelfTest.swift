import Foundation
import AppKit

/// Headless smoke test: `Granola --self-test <sample> [output.wav]`.
///
/// It drives the real `GranolaModel` — the same boot, load, granulate and
/// record path the UI uses — so a pass means the shipping code works, not that
/// a parallel test reimplementation does. Used to verify stereo handling.
@MainActor
enum SelfTest {

    static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }

    private static func argument(after flag: String, offset: Int = 1) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.count > index + offset else { return nil }
        let value = CommandLine.arguments[index + offset]
        return value.hasPrefix("--") ? nil : value
    }

    static func run(model: GranolaModel) {
        guard let samplePath = argument(after: "--self-test") else {
            finish("error: --self-test needs a path to an audio file", code: 2)
            return
        }
        let sampleURL = URL(fileURLWithPath: samplePath)
        let outputURL = URL(fileURLWithPath: argument(after: "--self-test", offset: 2)
                            ?? "build/self-test-output.wav")

        note("sample: \(sampleURL.path)")
        note("output: \(outputURL.path)")

        model.start()

        // CoreAudio device enumeration dominates boot time and varies a lot by
        // machine, so this is deliberately patient.
        wait(for: "audio engine", until: { model.isRunning }, timeout: 90) { ok in
            guard ok else { finish("FAIL: audio engine did not start — \(model.statusText)", code: 1); return }
            note("engine running")

            model.loadSample(sampleURL, into: 0)
            wait(for: "sample load", until: { model.tracks[0].playing }, timeout: 20) { loaded in
                guard loaded else {
                    finish("FAIL: sample did not load — \(model.tracks[0].loadError ?? "unknown")", code: 1)
                    return
                }
                note("loaded \(model.tracks[0].channels)ch, \(String(format: "%.2f", model.tracks[0].duration))s")

                // Settings chosen so the result is unambiguous: a dense cloud of
                // long grains, no pitch shift, and no stereo rotation — so any
                // channel difference in the output came from the source file.
                model.setParameter(0, .grainSize, value: 0.25)
                model.setParameter(0, .density, value: 40)
                model.setParameter(0, .jitter, value: 3)
                model.setParameter(0, .spread, value: 0)
                model.setParameter(0, .pan, value: 0)
                model.setParameter(0, .position, value: 0.0)
                // Sweep the read head across the whole buffer while recording.
                // Granulating one narrow window would compare a small region of
                // the source against the whole-file measurement, which is not a
                // like-for-like stereo comparison.
                model.setParameter(0, .scan, value: 2.0)
                model.setParameter(0, .reverbSend, value: 0)
                model.setParameter(0, .delaySend, value: 0)

                // The encoder check must run before any pan override: it starts
                // from centre and restores what it touched.
                guard checkEncoderModes(model: model) else {
                    finish("FAIL: encoder selectors did not drive their parameters", code: 1)
                    return
                }

                // --no-project isolates the signal path from the project test,
                // which reloads samples asynchronously.
                if !CommandLine.arguments.contains("--no-project") {
                  guard checkSurfaceShift(model: model) else {
                    finish("FAIL: shift combinations did not behave", code: 1)
                    return
                }

                guard checkProjectRoundTrip(model: model) else {
                    finish("FAIL: project save/load did not round-trip", code: 1)
                    return
                  }
                }
                waitForVoice(model: model, outputURL: outputURL)
            }
        }
    }

    /// A project load frees and rebuilds every voice asynchronously. Recording
    /// before that finishes measures silence, which is how a 48 dB drop looked
    /// like an engine regression rather than a test-harness bug.
    private static func waitForVoice(model: GranolaModel, outputURL: URL) {
        wait(for: "voices to restart", until: { model.tracks[0].playing }, timeout: 25) { ok in
            guard ok else {
                finish("FAIL: track did not resume after project load — "
                       + (model.tracks[0].loadError ?? "no error reported"), code: 1)
                return
            }
            continueToRecord(model: model, outputURL: outputURL)
        }
    }

    private static func continueToRecord(model: GranolaModel, outputURL: URL) {
                note("pre-record: playing=\(model.tracks[0].playing) "
                     + "level=\(String(format: "%.2f", model.tracks[0].value(.level))) "
                     + "master=\(String(format: "%.2f", model.masterLevel)) "
                     + "mute=\(model.tracks[0].mute)")
        note("params: size=\(fmt(model.tracks[0].value(.grainSize))) "
             + "dens=\(fmt(model.tracks[0].value(.density))) "
             + "pos=\(fmt(model.tracks[0].value(.position))) "
             + "scan=\(fmt(model.tracks[0].value(.scan))) "
             + "lpf=\(fmt(model.tracks[0].value(.lpf))) "
             + "hpf=\(fmt(model.tracks[0].value(.hpf))) "
             + "spread=\(fmt(model.tracks[0].value(.spread))) "
             + "freeze=\(fmt(model.tracks[0].value(.freeze))) "
             + "rev=\(fmt(model.tracks[0].value(.reverse)))")
        note("meter: \(fmt(model.tracks[0].meter.level))")
        note("sample: dur=\(fmt(model.tracks[0].duration)) "
             + "ch=\(model.tracks[0].channels) "
             + "peaks=\(model.tracks[0].waveform.count) "
             + "url=\(model.tracks[0].sampleURL?.lastPathComponent ?? "nil") "
             + "err=\(model.tracks[0].loadError ?? "none")")

                // --fx assembles N performance chain slots and routes track 1
                // through them, so the recording proves the Airwindows chain
                // is actually in the signal path.
                if let slots = argument(after: "--fx").flatMap(Int.init) {
                    // A 5s default fade would leave the chain half-engaged
                    // inside a 4s recording, so the harness can override it.
                    if let fade = argument(after: "--fx-fade").flatMap(Double.init) {
                        model.fxFadeTime = fade
                        note("fx fade: \(fade)s")
                    }
                    note("catalog: \(model.catalog.count) Airwindows effects")
                    guard model.catalog.count > 0 else {
                        finish("FAIL: Airwindows manifest did not load", code: 1); return
                    }
                    model.setTrackThroughFX(0, enabled: true)
                    for slot in 0..<min(slots, 8) { model.setFXSlot(slot, active: true) }
                    let chain = model.activeChain
                    note("chain (\(chain.count) links): "
                         + chain.map { $0.link.effect.name }.joined(separator: " -> "))
                    guard !chain.isEmpty else {
                        finish("FAIL: no chain was assembled", code: 1); return
                    }
                }

                // --pan <-1…1> records with the track panned, so the balance of
                // the result proves the control reaches the audio, not just the
                // model.
                if let panArgument = argument(after: "--pan"), let pan = Double(panArgument) {
                    model.setParameter(0, .pan, value: pan)
                    note("pan forced to \(pan)")
                }

                // --delay-send / --reverb-send record with an effect engaged,
                // so its contribution can be measured against a dry pass.
                if let value = argument(after: "--delay-send").flatMap(Double.init) {
                    model.setParameter(0, .delaySend, value: value)
                    note("delay send forced to \(value)")
                }
                if let value = argument(after: "--reverb-send").flatMap(Double.init) {
                    model.setParameter(0, .reverbSend, value: value)
                    note("reverb send forced to \(value)")
                }

                // An unlit strip must still have a live encoder: with no macro
                // button chosen the knob falls through to Drift.
                do {
                    let track = model.tracks[0]
                    let restore = track.activeMacros
                    for slot in MacroSlot.allCases where track.activeMacros.contains(slot) {
                        model.toggleMacro(0, slot)
                    }
                    let before = track.value(.drift)
                    model.nudgeEncoder(0, byTicks: 6)
                    let after = track.value(.drift)
                    note(String(format: "unlit strip: readout \"%@\", drift %.3f -> %.3f",
                                track.macroReadout, before, after))
                    if abs(after - before) < 1e-6 {
                        finish("FAIL: unlit strip's encoder did not reach Drift", code: 1); return
                    }
                    model.setParameter(0, .drift, value: before)
                    for slot in restore { model.toggleMacro(0, slot) }
                }

                // --scatter <0…100> parks the read head mid-file with no scan,
                // so the only thing moving the grains around is Scatter itself.
                if let value = argument(after: "--scatter").flatMap(Double.init) {
                    model.setParameter(0, .scan, value: 0)
                    model.setParameter(0, .position, value: 0.5)
                    model.setParameter(0, .jitter, value: value)
                    note("scatter forced to \(value)% (scan off, head at 0.5)")
                }

                // --filter <-1…1> records with the one-knob filter parked, so a
                // spectral comparison against a centred pass shows which way it
                // actually moves.
                if let value = argument(after: "--filter").flatMap(Double.init) {
                    model.setParameter(0, .filter, value: value)
                    note("filter forced to \(value)")
                }

                // --shift-encoder drives the filter the way the hardware does:
                // shift held, one encoder tick at a time.
                if let ticks = argument(after: "--shift-encoder").flatMap(Int.init) {
                    model.mixer.onButton?(GranolaModel.shiftButton, true)
                    let before = model.tracks[0].value(.filter)
                    for _ in 0..<abs(ticks) { model.nudgeEncoder(0, byTicks: ticks > 0 ? 1 : -1) }
                    let shownDuringHold = model.tracks[0].showingFilter
                    model.mixer.onButton?(GranolaModel.shiftButton, false)
                    let shownAfterRelease = model.tracks[0].showingFilter
                    note("filter readout: during hold \(shownDuringHold), "
                         + "after release \(shownAfterRelease)")
                    if !shownDuringHold || shownAfterRelease {
                        finish("FAIL: filter readout did not follow the shift hold", code: 1)
                        return
                    }
                    let after = model.tracks[0].value(.filter)
                    note(String(format: "shift+encoder %d ticks: filter %.3f -> %.3f",
                                ticks, before, after))
                    if abs(after - before) < 1e-6 {
                        finish("FAIL: shift+encoder did not move the filter", code: 1); return
                    }
                }

        record(model: model, to: outputURL)
    }

    /// Exercises the VOL / PAN encoder selectors the way the hardware does, and
    /// checks the values actually move. Restores everything afterwards so the
    /// recording that follows is unaffected.
    private static func checkEncoderModes(model: GranolaModel) -> Bool {
        let track = model.tracks[0]
        var ok = true

        // The hardware sends ONE tick per message. Testing with a single large
        // jump hides bugs that only bite at real encoder resolution — which is
        // exactly how the pan centre detent shipped broken.
        func turn(_ ticks: Int, _ direction: Int) {
            for _ in 0..<ticks { model.nudgeEncoder(0, byTicks: direction) }
        }

        let level = track.value(.level)

        // Every selector must move its parameter on a single tick, and keep
        // moving it. Sends start at zero, so any rise proves the wiring.
        let selectors: [(GranolaModel.EncoderMode, ParamID)] = [
            (.volume, .level), (.pan, .pan), (.delaySend, .delaySend), (.reverbSend, .reverbSend)
        ]
        for (mode, param) in selectors {
            model.setEncoderMode(mode)
            guard model.encoderMode == mode else {
                note("\(mode.label) mode did not engage"); return false
            }
            let before = track.value(param)
            model.nudgeEncoder(0, byTicks: 1)
            let afterOne = track.value(param)
            turn(9, 1)
            let afterTen = track.value(param)
            note(String(format: "%@: %.4f -> %.4f (1 tick) -> %.4f (10)",
                        mode.label, before, afterOne, afterTen))
            if afterOne <= before { note("a single tick did not move \(mode.label)"); ok = false }
            if afterTen <= afterOne { note("\(mode.label) stopped responding"); ok = false }
            model.setEncoderMode(mode)   // toggle back off
        }

        // --- pan centre detent -------------------------------------------
        model.setEncoderMode(.pan)

        // Sweeping back must land exactly on centre once, then carry on past
        // it — a detent that traps the knob at centre is the same bug again.
        var hitCentre = false
        for _ in 0..<20 {
            model.nudgeEncoder(0, byTicks: -1)
            if track.value(.pan) == 0 { hitCentre = true }
        }
        let panLeft = track.value(.pan)
        note(String(format: "pan swept left -> %.4f (detent hit: %@)",
                    panLeft, hitCentre ? "yes" : "no"))
        if !hitCentre { note("centre detent never engaged"); ok = false }
        if panLeft >= 0 { note("pan got stuck at centre instead of passing through"); ok = false }

        // Selectors are toggles: pressing the lit one returns to macro.
        model.setEncoderMode(.pan)
        if model.encoderMode != .macro { note("pan did not toggle back to macro"); ok = false }

        model.setParameter(0, .level, value: level)
        model.setParameter(0, .pan, value: 0)
        model.setParameter(0, .delaySend, value: 0)
        model.setParameter(0, .reverbSend, value: 0)
        // loadProject correctly applied the snapshot's master level; put the
        // recording level back so the measurement is comparable.
        model.masterLevel = 0.8
        return ok
    }

    /// Exercises the shift stand-in by feeding button events straight into the
    /// model's MIDI handler — the same closure the controller drives.
    private static func checkSurfaceShift(model: GranolaModel) -> Bool {
        var ok = true
        func press(_ button: SMCMixer.Button) {
            model.mixer.onButton?(button, true)
            model.mixer.onButton?(button, false)
        }
        let shift = GranolaModel.shiftButton

        if model.projectLayerActive { model.setProjectLayer(false) }
        let playingBefore = model.isPlaying

        // Shift held + Play should open the project layer, not touch transport.
        model.mixer.onButton?(shift, true)
        press(.play)
        note("shift+play -> project layer \(model.projectLayerActive)")
        if !model.projectLayerActive { note("shift+play did not open the layer"); ok = false }
        if model.isPlaying != playingBefore { note("shift+play moved transport"); ok = false }

        // Again, still held: closes it.
        press(.play)
        if model.projectLayerActive { note("shift+play did not close the layer"); ok = false }
        model.mixer.onButton?(shift, false)

        // Without shift, Play is transport again.
        press(.play)
        note("play alone -> transport \(model.isPlaying) (was \(playingBefore))")
        if model.isPlaying == playingBefore { note("play alone did not toggle transport"); ok = false }
        if model.projectLayerActive { note("play alone opened the layer"); ok = false }
        press(.play)   // restore

        // The shift key itself must never do anything on its own.
        let layer = model.projectLayerActive, playing = model.isPlaying
        press(shift)
        if model.projectLayerActive != layer || model.isPlaying != playing {
            note("the shift key performed an action of its own"); ok = false
        }
        return ok
    }

    /// Saves a distinctive state, disturbs everything, reloads, and checks what
    /// came back — including the one thing that must NOT come back: the scrub
    /// head, which always returns to zero so the app agrees with a fader
    /// resting at the bottom.
    ///
    /// Runs against a scratch directory (see ProjectStore.init), never the
    /// performer's real slots.
    private static func checkProjectRoundTrip(model: GranolaModel) -> Bool {
        let track = model.tracks[0]
        var ok = true
        let slot = 0

        // A state nothing else would produce by accident.
        model.setParameter(0, .grainSize, value: 0.42)
        model.setParameter(0, .pitch, value: -7.5)
        model.setParameter(0, .level, value: 1.13)
        model.setParameter(0, .pan, value: -0.66)
        model.setParameter(0, .delaySend, value: 0.31)
        model.setParameter(0, .reverbSend, value: 0.77)
        model.setParameter(0, .position, value: 0.73)   // must NOT survive
        // Via the model, not the track: setting `mute` directly would leave the
        // engine out of step with the flag.
        if !model.tracks[0].mute { model.toggleMute(0) }
        model.setGrainShape(0, .gaussian)
        model.delayTimeL = 1.234
        model.delayFeedback = 0.66
        model.reverbDecay = 12.5
        model.masterLevel = 0.42

        model.saveProject(to: slot)
        guard model.occupiedSlots[slot] else { note("slot did not report occupied"); return false }
        // The save has to be visible: the slot blinks and becomes the current
        // one, so the panel can highlight it.
        note("after save: blinking slot \(model.savingSlot.map(String.init) ?? "none"), "
             + "current \(model.currentProjectSlot.map(String.init) ?? "none")")
        if model.savingSlot != slot { note("  save did not blink the slot"); ok = false }
        if model.currentProjectSlot != slot { note("  save did not claim the slot"); ok = false }

        // Disturb everything the project should restore.
        model.setParameter(0, .grainSize, value: 0.01)
        model.setParameter(0, .pitch, value: 12)
        model.setParameter(0, .level, value: 0.2)
        model.setParameter(0, .pan, value: 0.9)
        model.setParameter(0, .delaySend, value: 0)
        model.setParameter(0, .reverbSend, value: 0)
        if model.tracks[0].mute { model.toggleMute(0) }
        model.setGrainShape(0, .plateau)
        model.delayTimeL = 0.1
        model.delayFeedback = 0.1
        model.reverbDecay = 1.0
        model.masterLevel = 1.0

        // A different slot in between, so "current" is proven to follow the
        // load rather than just being left over from the save.
        model.saveProject(to: slot + 1)
        model.loadProject(from: slot)
        note("after load: current \(model.currentProjectSlot.map(String.init) ?? "none")")
        if model.currentProjectSlot != slot { note("  load did not claim the slot"); ok = false }

        func check(_ label: String, _ actual: Double, _ expected: Double, tolerance: Double = 1e-6) {
            let good = abs(actual - expected) <= tolerance
            note(String(format: "  %@ %.4f (expected %.4f) %@",
                        label, actual, expected, good ? "ok" : "MISMATCH"))
            if !good { ok = false }
        }

        note("project round-trip:")
        check("grainSize ", track.value(.grainSize), 0.42)
        check("pitch     ", track.value(.pitch), -7.5)
        check("level     ", track.value(.level), 1.13)
        check("pan       ", track.value(.pan), -0.66)
        check("delaySend ", track.value(.delaySend), 0.31)
        check("reverbSend", track.value(.reverbSend), 0.77)
        check("delayTimeL", model.delayTimeL, 1.234)
        check("delayFdbk ", model.delayFeedback, 0.66)
        check("reverbDcy ", model.reverbDecay, 12.5)
        check("masterLvl ", model.masterLevel, 0.42)

        if !track.mute { note("  mute was not restored"); ok = false }
        if model.tracks[0].grainShape != .gaussian { note("  grain shape was not restored"); ok = false }

        // The whole point: position is deliberately not restored.
        check("position  ", track.value(.position), 0.0)
        if track.value(.position) != 0 {
            note("  scrub head must always reload at zero")
            ok = false
        }

        // An empty slot must be a no-op, not a crash or a wipe.
        model.loadProject(from: ProjectStore.slotCount - 1)

        model.clearProject(slot: slot)
        if model.occupiedSlots[slot] { note("  cleared slot still reports occupied"); ok = false }

        if model.tracks[0].mute { model.toggleMute(0) }
        model.setParameter(0, .delaySend, value: 0)
        model.setParameter(0, .reverbSend, value: 0)
        model.setGrainShape(0, .gaussian)
        model.setParameter(0, .pan, value: 0)
        model.setParameter(0, .level, value: 0.7)
        model.setParameter(0, .grainSize, value: 0.25)
        model.setParameter(0, .pitch, value: 0)
        // loadProject legitimately applied the snapshot's master level; put it
        // back so the recording that follows is measured at normal gain.
        model.masterLevel = 0.8
        return ok
    }

    private static func record(model: GranolaModel, to outputURL: URL) {
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        model.startRecording(to: outputURL) { started in
            guard started else { finish("FAIL: could not start recording", code: 1); return }
            note("recording 4s…")

            // --toggle-routing flips a track between the mix and the chain
            // several times mid-recording, so any discontinuity at the switch
            // shows up as a sample-to-sample jump in the result.
            if CommandLine.arguments.contains("--cycle-shapes") {
                let shapes = GranolaEngine.GrainShape.allCases
                for (step, shape) in shapes.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.6) {
                        model.setGrainShape(0, shape)
                        note("grain shape -> \(shape.label)")
                    }
                }
            }

            if CommandLine.arguments.contains("--toggle-routing") {
                for step in 1...6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.5) {
                        model.setTrackThroughFX(0, enabled: step % 2 == 1)
                    }
                }
                note("toggling routing 6x during the recording")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                model.stopRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
                    let size = (attributes?[.size] as? Int) ?? 0
                    guard size > 1024 else {
                        finish("FAIL: no audio was recorded (\(size) bytes)", code: 1)
                        return
                    }
                    note("wrote \(size) bytes")
                    finish("OK", code: 0)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func fmt(_ value: Double) -> String { String(format: "%.3f", value) }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data(("[self-test] " + message + "\n").utf8))
    }

    private static func wait(for what: String, until condition: @escaping () -> Bool,
                             timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { completion(true); return }
            if Date() > deadline { note("timed out waiting for \(what)"); completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    private static func finish(_ message: String, code: Int32) {
        note(message)
        NSApplication.shared.terminate(nil)
        // terminate() is asynchronous; exit directly so the status code is ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(code) }
    }
}

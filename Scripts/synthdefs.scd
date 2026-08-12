// Granola — SynthDef sources.
// Compiled ahead of time by Scripts/build.sh into Resources/synthdefs/*.scsyndef.
// The app never runs sclang; scsynth loads these with /d_loadDir at boot.
//
// Signal flow:
//   granolaVoice   -> trackBus[n]      grain cloud, one per track
//   granolaStrip   -> mixBus or perfBus level/mute/meter + per-track sends
//   granolaReverb  -> perfBus            master effects run BEFORE the chain,
//   granolaDelay   -> perfBus            so the Airwindows chain mangles them
//   awfx_*         -> perfBus (in place) Airwindows chain, series = node order
//   granolaPerfOut -> mixBus
//   granolaMaster  -> hardware out       gain, limiter, meter, clears mixBus

(
var outDir = thisProcess.nowExecutingPath.dirname.dirname +/+ "Resources/synthdefs";

// ---------------------------------------------------------------------------
// Track voice: one granular cloud per track.
//
// `pos` is the scrub head, 0..1 through the buffer — this is what the SMC-Mixer
// faders drive. Everything else shapes the cloud around that head.
// ---------------------------------------------------------------------------
// GrainBuf only reads mono buffers, so a stereo sample is granulated as two
// mono clouds sharing one trigger and one set of per-grain random values. The
// grains stay sample-aligned, and `pan`/`spread` rotate each grain in the
// stereo field instead of collapsing the source to mono.
SynthDef(\granolaVoice, { |out = 0, bufL = 0, bufR = 0, gate = 1,
    pos = 0.0, posLag = 0.05, scan = 0.0,
    grainSize = 0.12, density = 20.0, jitter = 0.0,
    pitch = 0.0, pitchJitter = 0.0, pitchQuant = 0.0,
    pan = 0.0, spread = 0.6,
    lpf = 18000, hpf = 20, resonance = 0.0,
    envBuf = -1, reverse = 0.0, overlapLimit = 512,
    freeze = 0.0, drift = 0.0, gain = 1.0, filter = 0.0 |

    var trig, dur, head, posSig, rate, sig, jit, semis, bufDur, gateEnv, clock, grainPan;
    var filterAmount, filterMag, filterRq;

    bufDur = max(BufDur.kr(bufL), 0.001);

    // --- trigger clock -----------------------------------------------------
    // `drift` smears the grain clock toward Dust-like irregularity without
    // ever fully losing the pulse.
    clock = density * LFNoise1.kr(density.clip(0.1, 30) * 0.5).range(1.0 - drift, 1.0 + drift);
    trig = Impulse.ar(clock.max(0.01));

    // --- scrub head --------------------------------------------------------
    // Fader position, de-zippered, plus an optional free-running scan so a
    // cloud can drift through the sample on its own. `scan` is in buffers/sec.
    head = Lag.kr(pos, posLag);
    head = head + (LFSaw.kr((scan / bufDur), 1).range(0, 1) * scan.sign);
    head = head.wrap(0, 1);

    // Scatter arrives as a percentage of the buffer, so it is already in
    // buffer-relative units and means the same thing at any sample length.
    jit = TRand.ar(-1.0, 1.0, trig) * (jitter * 0.01);
    posSig = K2A.ar(head);
    posSig = Select.ar(freeze, [posSig, Latch.ar(posSig, trig)]);
    posSig = (posSig + jit).wrap(0, 1);

    // --- pitch -------------------------------------------------------------
    semis = pitch + TRand.ar(pitchJitter.neg, pitchJitter, trig);
    semis = Select.ar(pitchQuant, [semis, semis.round(1.0)]);
    rate = semis.midiratio * BufRateScale.kr(bufL) * (1.0 - (reverse * 2.0));

    // --- grains ------------------------------------------------------------
    dur = max(grainSize, 0.001)
        * TExpRand.ar(1.0 - (drift * 0.5), 1.0 + (drift * 0.5), trig);

    // Per-grain scatter only. Track pan is NOT folded in here: Rotate2 rotates
    // the stereo field rather than moving it left or right, so using it as a
    // pan control makes hard-left and hard-right sound nearly identical.
    grainPan = TRand.ar(spread.neg, spread, trig).clip(-1, 1);

    sig = [bufL, bufR].collect { |b|
        GrainBuf.ar(
            numChannels: 1,
            trigger: trig,
            dur: dur,
            sndbuf: b,
            rate: rate,
            pos: posSig,
            interp: 4,
            pan: 0,
            envbufnum: envBuf,
            maxGrains: overlapLimit
        );
    };
    // 0.5 maps the ±1 spread control onto ±90 degrees of stereo rotation, so
    // grains scatter around the field while each keeps its own stereo content.
    sig = Rotate2.ar(sig[0], sig[1], grainPan * 0.5);

    // --- tone shaping ------------------------------------------------------
    sig = RLPF.ar(sig, lpf.clip(40, 20000), (1.0 - resonance).clip(0.05, 1.0));
    sig = HPF.ar(sig, hpf.clip(20, 18000));
    sig = LeakDC.ar(sig);

    // --- one-knob DJ filter ------------------------------------------------
    // Centre is neutral. Turning down sweeps a low-pass from 20kHz to 120Hz;
    // turning up sweeps a high-pass from 20Hz to 7kHz. Resonance rises with
    // distance from centre, so the further the knob goes the more the filter
    // sings — one control covering cutoff, resonance and mode, in the style of
    // the Novation Circuit machines.
    filterAmount = filter.clip(-1, 1);
    filterMag = filterAmount.abs;
    // Resonance peaks around three quarters of the travel rather than at the
    // stop: at the extremes the peak sits on top of whatever little is left in
    // the band, which reads as a level jump rather than as character.
    filterRq = (1.0 - (sin(filterMag * pi * 0.8) * 0.66)).clip(0.3, 1.0);
    sig = Select.ar(filterAmount > 0, [
        RLPF.ar(sig, LinExp.kr(filterMag, 0, 1, 20000, 120), filterRq),
        RHPF.ar(sig, LinExp.kr(filterMag, 0, 1, 20, 7000), filterRq)
    ]);
    // A resonant low-pass over bass-heavy material gets loud fast; trim the
    // low side so a downward sweep thins out instead of swelling.
    sig = sig * Select.kr(filterAmount > 0, [(1.0 - (filterMag * 0.55)), DC.kr(1)]);
    sig = LeakDC.ar(sig);

    // Track pan: equal-power stereo balance, the way a mixer channel behaves.
    // At -1 the cloud sits fully in the left speaker, at +1 fully in the right,
    // and at 0 the source's own stereo image passes through untouched.
    sig = Balance2.ar(sig[0], sig[1], pan.clip(-1, 1));

    // Keep perceived loudness roughly constant as grains pile up.
    sig = sig * ((density * grainSize).max(1.0).sqrt.reciprocal.max(0.15));

    gateEnv = EnvGen.kr(Env.asr(0.02, 1, 0.08), gate, doneAction: 2);
    Out.ar(out, sig * gain * gateEnv);
}).writeDefFile(outDir);

// ---------------------------------------------------------------------------
// Track strip: level / mute / reverb send / metering, and it clears the track
// bus so the voice can be rebuilt underneath without a click.
// ---------------------------------------------------------------------------
SynthDef(\granolaStrip, { |in = 0, mixOut = 16, perfOut = 40,
    reverbOut = 0, delayOut = 0, index = 0,
    amp = 0.7, mute = 0.0, reverbSend = 0.0, delaySend = 0.0,
    routing = 0.0, lag = 0.03, routeLag = 0.08|

    var sig, level, route;

    sig = In.ar(in, 2);
    level = Lag.kr(amp * (1.0 - mute), lag);
    sig = sig * level;

    SendReply.kr(Impulse.kr(15), '/trackMeter', [index, Amplitude.kr(sig.sum * 0.5)]);

    ReplaceOut.ar(in, Silent.ar(2));

    // Routing is a crossfade, not a switch. Moving a track between the mix and
    // the performance chain by reassigning its output bus changes the signal
    // in a single sample, which is audible as a click; fading between two
    // permanent outputs cannot be. Both paths reach the mix, so a track is
    // never louder or quieter part-way through the move.
    route = Lag.kr(routing.clip(0, 1), routeLag);
    Out.ar(mixOut, sig * (1.0 - route));
    Out.ar(perfOut, sig * route);

    // Post-fader sends: muting a track mutes what it feeds the effects too.
    Out.ar(reverbOut, sig * Lag.kr(reverbSend, lag));
    Out.ar(delayOut, sig * Lag.kr(delaySend, lag));
}).writeDefFile(outDir);

// ---------------------------------------------------------------------------
// Performance FX bus terminator.
//
// Effect synths live in front of this node and process the bus in place, so the
// chain order is just node order. This node sits permanently at the tail: it
// takes whatever came out of the chain, hands it to the mix, and clears the bus
// for the next block.
// ---------------------------------------------------------------------------
SynthDef(\granolaPerfIn, { |in = 40, levelBus = 8|
    // Sits permanently at the HEAD of the performance group and publishes the
    // level entering the chain, so the tail can match it. Per-link matching
    // keeps each stage sane, but only an end-to-end measurement can hold the
    // loudness of a chain of arbitrary length.
    // Same long time constants as the correction at the tail, so the two
    // measurements move together instead of diverging on transitions.
    Out.kr(levelBus, Amplitude.kr(In.ar(in, 2).sum * 0.5, 0.5, 1.0));
}).writeDefFile(outDir);

SynthDef(\granolaPerfOut, { |in = 40, out = 16, levelBus = 8,
    ceiling = 0.95, autoGain = 1|

    var sig, inLevel, outLevel, match;
    sig = In.ar(in, 2);
    ReplaceOut.ar(in, Silent.ar(2));
    sig = LeakDC.ar(sig);

    // Match the chain's output level to what went in.
    //
    // This must track LOUDNESS, not events. Fast followers made it dive by
    // ~20dB whenever a track was routed in or out: the chain input changes at
    // once while effect tails and the reverb/delay feeding the same bus keep
    // the output up, so the ratio collapses for a moment. Routing a track is a
    // performance gesture and cannot duck the mix.
    //
    // Hence long time constants and a gentle +/-6dB bound. Cumulative drift
    // across a chain is a slow, structural thing; per-link matching already
    // handles anything fast.
    inLevel = In.kr(levelBus);
    outLevel = Amplitude.kr(sig.sum * 0.5, 0.5, 1.0);
    match = Lag.kr(
        Select.kr(inLevel > 0.0005, [
            DC.kr(1),
            (inLevel / outLevel.max(0.0001)).clip(0.5, 2)
        ]), 1.5);
    sig = sig * Select.kr(autoGain, [DC.kr(1), match]);

    // Safety against a chain of ten links spiking on a transient — but it has
    // to be ZERO LATENCY.
    //
    // Limiter.ar delays by TWICE its lookahead — measured at 959 samples
    // (19.98ms) for a 0.01 lookahead, with an NRT impulse probe. That put this
    // path 20ms behind the direct one, so crossfading a track between them
    // blended the same audio 20ms apart: comb filtering, heard as a brief
    // smothering every time a track was selected.
    //
    // The master limiter still catches the output, and it delays the whole mix
    // equally, so nothing is left misaligned.
    sig = (sig * ceiling.reciprocal).softclip * ceiling;
    Out.ar(out, sig);
}).writeDefFile(outDir);

// ---------------------------------------------------------------------------
// Master reverb — JPverb (sc3-plugins), the lushest thing available to us.
//
// JPverb is Julian Parker's Dattorro-style modulated plate: a dense, modulated
// tank with per-band decay control. It beats anything in core SuperCollider —
// FreeVerb2 is a small fixed comb/allpass bank that thins out on long tails,
// and GVerb is mono-in and prone to booming.
//
// Wrapped here with a pre-delay (JPverb has none), an input high-pass to keep
// low rumble out of the tank, and a mid/side width control.
// ---------------------------------------------------------------------------
SynthDef(\granolaReverb, { |in = 0, out = 0, amp = 1.0,
    predelay = 0.025, decay = 3.5, size = 1.6, damp = 0.35,
    earlyDiff = 0.78, modDepth = 0.12, modRate = 1.7,
    lowMult = 1.0, midMult = 1.0, highMult = 0.55,
    lowBand = 380, highBand = 4200,
    inputCut = 90, width = 1.0 |

    var input, pre, wet, centre, sides;

    input = In.ar(in, 2);
    input = HPF.ar(input, inputCut.clip(20, 1000));
    pre = DelayN.ar(input, 0.5, predelay.clip(0, 0.5));

    wet = JPverb.ar(
        in: pre,
        t60: decay.clip(0.1, 60),
        damp: damp.clip(0, 1),
        size: size.clip(0.5, 5),
        earlyDiff: earlyDiff.clip(0, 1),
        modDepth: modDepth.clip(0, 1),
        modFreq: modRate.clip(0, 10),
        low: lowMult.clip(0, 1),
        mid: midMult.clip(0, 1),
        high: highMult.clip(0, 1),
        lowcut: lowBand.clip(100, 6000),
        highcut: highBand.clip(1000, 10000)
    );

    // Mid/side width: 0 collapses the tail to centre, >1 widens it.
    centre = (wet[0] + wet[1]) * 0.5;
    sides = (wet[0] - wet[1]) * 0.5 * width.clip(0, 2);
    wet = [centre + sides, centre - sides];

    ReplaceOut.ar(in, Silent.ar(2));
    Out.ar(out, LeakDC.ar(wet) * Lag.kr(amp, 0.05));
}).writeDefFile(outDir);

// ---------------------------------------------------------------------------
// Master stereo delay.
//
// Up to 10 seconds per side, independent L/R times, and a continuously
// variable feedback cross-blend: 0 keeps the two sides parallel, 1 is full
// ping-pong, and everything between is a stereo bounce that drifts across the
// image. Feedback is filtered and can be modulated for tape-style drift.
// ---------------------------------------------------------------------------
SynthDef(\granolaDelay, { |in = 0, out = 0, amp = 1.0,
    timeL = 0.375, timeR = 0.5, feedback = 0.45, crossFeed = 0.35,
    damp = 6500, lowCut = 120, modDepth = 0.15, modRate = 0.23,
    diffusion = 0.0, width = 1.0, freeze = 0.0, lag = 0.15 |

    var input, fb, injectL, injectR, tL, tR, sig, mid, side, fbAmount;

    // Freezing holds the loop and stops new material entering it.
    input = In.ar(in, 2) * (1.0 - freeze);
    fb = LocalIn.ar(2);

    // crossFeed 0 = parallel stereo delays, 1 = ping-pong.
    injectL = input[0] + (fb[0] * (1 - crossFeed) + (fb[1] * crossFeed));
    injectR = input[1] + (fb[1] * (1 - crossFeed) + (fb[0] * crossFeed));

    // Times are lagged so a moved control glides rather than clicking, and
    // DelayC's interpolation turns that glide into tape-style pitch drift.
    tL = Lag.kr(timeL.clip(0.001, 10.0), lag)
        * (1 + (LFNoise2.kr(modRate) * modDepth * 0.02));
    tR = Lag.kr(timeR.clip(0.001, 10.0), lag)
        * (1 + (LFNoise2.kr(modRate * 1.17) * modDepth * 0.02));

    sig = [
        DelayC.ar(injectL, 10.0, tL.clip(0.001, 10.0)),
        DelayC.ar(injectR, 10.0, tR.clip(0.001, 10.0))
    ];

    // Filtering inside the loop: each repeat is darker than the last.
    sig = LPF.ar(sig, damp.clip(200, 18000));
    sig = HPF.ar(sig, lowCut.clip(20, 2000));

    // Optional diffusion in the loop. At 0 the repeats stay discrete and
    // rhythmic; raised, each pass smears until the delay becomes a wash.
    sig = [0.0071, 0.0113].collect { |t, i|
        AllpassC.ar(sig[i], 0.05, [t, t * 1.09], t * (1 + (diffusion.clip(0, 1) * 30))).sum * 0.5
    };
    sig = LeakDC.ar(sig);

    fbAmount = Select.kr(freeze, [feedback.clip(0, 0.98), DC.kr(1.0)]);
    LocalOut.ar(sig * fbAmount);

    mid = (sig[0] + sig[1]) * 0.5;
    side = (sig[0] - sig[1]) * 0.5 * width;
    sig = [mid + side, mid - side];

    ReplaceOut.ar(in, Silent.ar(2));
    Out.ar(out, sig * Lag.kr(amp, 0.05));
}).writeDefFile(outDir);

// ---------------------------------------------------------------------------
// Master bus: gain, soft limiter, metering.
// ---------------------------------------------------------------------------
SynthDef(\granolaMaster, { |in = 0, out = 0, recOut = 20, amp = 0.8, ceiling = 0.95|
    var sig = In.ar(in, 2);
    sig = sig * Lag.kr(amp, 0.05);
    sig = Limiter.ar(sig, ceiling, 0.01);

    SendReply.kr(Impulse.kr(15), '/masterMeter', [
        Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
    ]);

    ReplaceOut.ar(in, Silent.ar(2));
    Out.ar(out, sig);
    // Post-limiter tap for the recorder, so what is captured is what is heard.
    ReplaceOut.ar(recOut, sig);
}).writeDefFile(outDir);

// ---------------------------------------------------------------------------
// Output recorder. Created on demand at the tail of the master group; the
// buffer is a disk-writing buffer prepared by the client with /b_write.
// ---------------------------------------------------------------------------
SynthDef(\granolaRecorder, { |in = 20, buf = 0|
    DiskOut.ar(buf, In.ar(in, 2));
}).writeDefFile(outDir);

"Granola: wrote synthdefs to %".format(outDir).postln;
0.exit;
)

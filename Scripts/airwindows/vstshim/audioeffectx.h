// Minimal stand-in for the VST2 SDK header that every Airwindows plugin
// includes.
//
// Airwindows DSP is self-contained: the only things it needs from the SDK are
// a base class with a handful of no-op setup calls, a sample-rate accessor,
// and some string helpers. Providing them here means the original .cpp and
// .h files compile **completely unmodified** — the algorithms, and therefore
// the sound, are Chris Johnson's exactly as published (MIT licensed).
//
// Nothing here implements VST. It exists so the DSP can be wrapped as a
// SuperCollider UGen instead of a plugin.

#ifndef __audioeffect__
#define __audioeffect__

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>

typedef int32_t VstInt32;
typedef intptr_t VstIntPtr;
typedef void* audioMasterCallback;

enum VstPlugCategory {
    kPlugCategUnknown = 0,
    kPlugCategEffect,
    kPlugCategSynth,
    kPlugCategAnalysis,
    kPlugCategMastering,
    kPlugCategSpacializer,
    kPlugCategRoomFx,
    kPlugSurroundFx,
    kPlugCategRestoration,
    kPlugCategOfflineProcess,
    kPlugCategShell,
    kPlugCategGenerator
};

enum {
    kVstMaxProgNameLen   = 24,
    kVstMaxParamStrLen   = 8,
    kVstMaxVendorStrLen  = 64,
    kVstMaxProductStrLen = 64,
    kVstMaxEffectNameLen = 32
};

// The host sets this immediately before constructing a plugin, so constructors
// that derive coefficients from the sample rate see the real value rather than
// a 44100 default.
double aw_pending_sample_rate();
void aw_set_pending_sample_rate(double rate);

inline void vst_strncpy(char* destination, const char* source, size_t maximum) {
    if (maximum == 0) return;
    std::strncpy(destination, source, maximum);
    destination[maximum] = '\0';
}

inline void float2string(float value, char* text, int maximum) {
    std::snprintf(text, static_cast<size_t>(maximum), "%.6f", value);
}

inline void int2string(int value, char* text, int maximum) {
    std::snprintf(text, static_cast<size_t>(maximum), "%d", value);
}

inline void dB2string(float value, char* text, int maximum) {
    if (value <= 0) {
        vst_strncpy(text, "-oo", static_cast<size_t>(maximum));
    } else {
        std::snprintf(text, static_cast<size_t>(maximum), "%.2f", 20.0 * std::log10(value));
    }
}

class AudioEffect {
public:
    virtual ~AudioEffect() {}
};

class AudioEffectX : public AudioEffect {
public:
    AudioEffectX(audioMasterCallback, VstInt32, VstInt32)
        : sampleRate_(aw_pending_sample_rate()) {}
    virtual ~AudioEffectX() {}

    // Setup calls the plugins make in their constructors. All no-ops here.
    void setNumInputs(VstInt32) {}
    void setNumOutputs(VstInt32) {}
    void setUniqueID(unsigned long) {}
    void setUniqueID(VstInt32) {}
    void canProcessReplacing(bool = true) {}
    void canDoubleReplacing(bool = true) {}
    void programsAreChunks(bool = true) {}
    void isSynth(bool = true) {}
    void noTail(bool = true) {}

    void setSampleRate(double rate) { sampleRate_ = rate; }
    double getSampleRate() const { return sampleRate_; }

    virtual VstInt32 canDo(char*) { return -1; }

private:
    double sampleRate_;
};

#endif

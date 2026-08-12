// Sample rate handed to Airwindows constructors.
//
// Several algorithms derive coefficients in their constructor from
// getSampleRate(). The UGen sets this immediately before `new`, so those
// plugins see the server's real rate rather than a 44100 default.
#include "audioeffectx.h"

static double g_pendingSampleRate = 44100.0;

double aw_pending_sample_rate() { return g_pendingSampleRate; }
void aw_set_pending_sample_rate(double rate) {
    if (rate > 0.0) g_pendingSampleRate = rate;
}

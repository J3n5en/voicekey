#include "opus_shim.h"

OpusEncoder *copus_create(int sampleRate, int application, int bitrate, int complexity) {
    int err = 0;
    OpusEncoder *enc = opus_encoder_create(sampleRate, 1, application, &err);
    if (!enc || err != OPUS_OK) return NULL;
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
    opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
    return enc;
}

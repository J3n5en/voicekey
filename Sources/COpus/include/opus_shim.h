#pragma once
#include "opus/opus.h"

OpusEncoder *copus_create(int sampleRate, int application, int bitrate, int complexity);

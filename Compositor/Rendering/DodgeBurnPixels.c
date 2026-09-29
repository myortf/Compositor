#include "DodgeBurnPixels.h"

// How far a fully weighted pixel moves toward white (dodge) or black (burn).
#define DODGE_BURN_REACH 0.8f

static inline float tone_weight(float luma, int range) {
    if (range == 0) return (1.0f - luma) * (1.0f - luma);
    if (range == 2) return luma * luma;
    float d = 2.0f * luma - 1.0f;
    return 1.0f - d * d;
}

static inline float shift(float v, float amount, int burn) {
    return burn ? v * (1.0f - amount) : v + (1.0f - v) * amount;
}

static inline uint8_t to_byte(float v) {
    int i = (int)(v * 255.0f + 0.5f);
    return i < 0 ? 0 : i > 255 ? 255 : (uint8_t)i;
}

void dodge_burn_rgba(uint8_t *rgba, size_t stride, size_t width, size_t height, int burn, int range) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            float r = p[0] / 255.0f, g = p[1] / 255.0f, b = p[2] / 255.0f;
            float amount = DODGE_BURN_REACH * tone_weight(0.299f * r + 0.587f * g + 0.114f * b, range);
            p[0] = to_byte(shift(r, amount, burn));
            p[1] = to_byte(shift(g, amount, burn));
            p[2] = to_byte(shift(b, amount, burn));
        }
    }
}

void dodge_burn_gray(uint8_t *gray, size_t stride, size_t width, size_t height, int burn, int range) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = gray + y * stride;
        for (size_t x = 0; x < width; ++x) {
            float v = p[x] / 255.0f;
            p[x] = to_byte(shift(v, DODGE_BURN_REACH * tone_weight(v, range), burn));
        }
    }
}

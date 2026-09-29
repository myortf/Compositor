#ifndef DodgeBurnPixels_h
#define DodgeBurnPixels_h
#include <stdint.h>
#include <stddef.h>
// Full-strength Dodge or Burn over straight (unpremultiplied) pixels, weighted by tone.
// burn: 0 lightens, 1 darkens. range: 0 shadows, 1 midtones, 2 highlights.
void dodge_burn_rgba(uint8_t *rgba, size_t stride, size_t width, size_t height, int burn, int range);
void dodge_burn_gray(uint8_t *gray, size_t stride, size_t width, size_t height, int burn, int range);
#endif

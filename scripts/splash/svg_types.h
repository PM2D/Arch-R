#ifndef SVG_TYPES_H
#define SVG_TYPES_H

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    float x;
    float y;
} Point;

typedef struct {
    Point *points;
    uint32_t num_points;
    uint32_t capacity;
    bool is_hole;
} Path;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
} Color;

typedef struct {
    Path *paths;
    uint32_t num_paths;
    uint32_t capacity;
    Color fill_color;
} SVGPath;

#endif

/*
 * Arch R — SVG scanline renderer with anti-aliasing
 * SVG scanline renderer for initramfs boot splash
 * Parametrized BASE_SVG dimensions (received via DisplayInfo)
 */

#include <stdlib.h>
#include <math.h>
#include <string.h>
#include "svg_renderer.h"

#define MAX_INTERSECTIONS 1000
#define SUBPIXEL_PRECISION 8

typedef struct {
    float x;
    bool is_hole_edge;
} Intersection;

static const float rotation_cos[] = { 1.0f, 0.0f, -1.0f, 0.0f };
static const float rotation_sin[] = { 0.0f, 1.0f, 0.0f, -1.0f };

static int compare_intersections(const void *a, const void *b)
{
    float diff = ((Intersection*)a)->x - ((Intersection*)b)->x;
    return (diff < 0) ? -1 : (diff > 0) ? 1 : 0;
}

static void calculate_svg_bounds(SVGPath *svg, float *min_x, float *max_x, float *min_y, float *max_y)
{
    *min_x = *min_y = 1e6f;
    *max_x = *max_y = -1e6f;

    for (uint32_t i = 0; i < svg->num_paths; i++) {
        Path *path = &svg->paths[i];
        for (uint32_t j = 0; j < path->num_points; j++) {
            if (path->points[j].x < *min_x) *min_x = path->points[j].x;
            if (path->points[j].x > *max_x) *max_x = path->points[j].x;
            if (path->points[j].y < *min_y) *min_y = path->points[j].y;
            if (path->points[j].y > *max_y) *max_y = path->points[j].y;
        }
    }
}

void rotate_svg_path(SVGPath *svg, int angle)
{
    /* Not used on R36S (no rotation), kept for future clones */
    float center_x = 640.0f;
    float center_y = 250.0f;

    int angle_index = (angle / 90) % 4;
    float cos_a = rotation_cos[angle_index];
    float sin_a = rotation_sin[angle_index];

    for (uint32_t i = 0; i < svg->num_paths; i++) {
        Path *path = &svg->paths[i];
        for (uint32_t j = 0; j < path->num_points; j++) {
            float x = path->points[j].x - center_x;
            float y = path->points[j].y - center_y;
            path->points[j].x = x * cos_a - y * sin_a + center_x;
            path->points[j].y = x * sin_a + y * cos_a + center_y;
        }
    }
}

static uint32_t blend_color_vibrant(uint32_t color, float alpha)
{
    uint8_t r = (color >> 16) & 0xFF;
    uint8_t g = (color >> 8) & 0xFF;
    uint8_t b = color & 0xFF;

    /* Non-linear alpha curve for vibrant edge AA */
    alpha = alpha < 0.5f ? 2.0f * alpha * alpha : 1.0f - 2.0f * (1.0f - alpha) * (1.0f - alpha);

    uint8_t new_r = (uint8_t)(r * alpha);
    uint8_t new_g = (uint8_t)(g * alpha);
    uint8_t new_b = (uint8_t)(b * alpha);

    return (new_r << 16) | (new_g << 8) | new_b;
}

static void render_path(Framebuffer *fb, SVGPath *svg, DisplayInfo *di)
{
    float min_x, max_x, min_y, max_y;
    calculate_svg_bounds(svg, &min_x, &max_x, &min_y, &max_y);

    float scale_x = (float)di->svg_width / di->base_svg_width;
    float scale_y = (float)di->svg_height / di->base_svg_height;
    float scale = (scale_x < scale_y) ? scale_x : scale_y;

    float offset_x = di->x_offset;
    float offset_y = di->y_offset;

    offset_x += (di->svg_width - (di->base_svg_width * scale)) / 2;
    offset_y += (di->svg_height - (di->base_svg_height * scale)) / 2;

    int screen_min_y = (int)((min_y * scale + offset_y) - 1);
    int screen_max_y = (int)((max_y * scale + offset_y) + 1);

    if (screen_min_y < 0) screen_min_y = 0;
    if (screen_max_y >= (int)fb->vinfo.yres) screen_max_y = fb->vinfo.yres - 1;

    Intersection *intersections = malloc(MAX_INTERSECTIONS * sizeof(Intersection));
    if (!intersections) return;

    uint32_t fill_color = (svg->fill_color.r << 16) |
                         (svg->fill_color.g << 8) |
                          svg->fill_color.b;

    float *coverage_buffer = calloc(fb->vinfo.xres, sizeof(float));
    if (!coverage_buffer) {
        free(intersections);
        return;
    }

    for (int y = screen_min_y; y <= screen_max_y; y++) {
        memset(coverage_buffer, 0, fb->vinfo.xres * sizeof(float));

        for (int subpixel = 0; subpixel < SUBPIXEL_PRECISION; subpixel++) {
            float subpixel_y = y + (float)subpixel / SUBPIXEL_PRECISION;
            int num_intersections = 0;

            for (uint32_t i = 0; i < svg->num_paths; i++) {
                Path *path = &svg->paths[i];
                for (uint32_t j = 0; j < path->num_points; j++) {
                    uint32_t k = (j + 1) % path->num_points;

                    float y1 = path->points[j].y * scale + offset_y;
                    float y2 = path->points[k].y * scale + offset_y;

                    if ((y1 <= subpixel_y && y2 > subpixel_y) ||
                        (y2 <= subpixel_y && y1 > subpixel_y)) {
                        float x1 = path->points[j].x * scale + offset_x;
                        float x2 = path->points[k].x * scale + offset_x;

                        if (num_intersections < MAX_INTERSECTIONS) {
                            float x;
                            if (y1 == y2) {
                                x = x1;
                            } else {
                                x = x1 + (subpixel_y - y1) * (x2 - x1) / (y2 - y1);
                            }

                            intersections[num_intersections].x = x;
                            intersections[num_intersections].is_hole_edge = path->is_hole;
                            num_intersections++;
                        }
                    }
                }
            }

            if (num_intersections > 0) {
                qsort(intersections, num_intersections, sizeof(Intersection), compare_intersections);

                bool inside_main = false;
                bool inside_hole = false;

                for (int i = 0; i < num_intersections - 1; i++) {
                    if (intersections[i].is_hole_edge)
                        inside_hole = !inside_hole;
                    else
                        inside_main = !inside_main;

                    if (inside_main && !inside_hole) {
                        float x_start = intersections[i].x;
                        float x_end = intersections[i + 1].x;

                        int ix_start = (int)floorf(x_start);
                        int ix_end = (int)ceilf(x_end);

                        if (ix_start < 0) ix_start = 0;
                        if (ix_end >= (int)fb->vinfo.xres) ix_end = fb->vinfo.xres - 1;

                        for (int x = ix_start; x <= ix_end; x++) {
                            float pixel_coverage = 1.0f;

                            if (x == ix_start && x_start > ix_start)
                                pixel_coverage *= (1.0f - (x_start - ix_start));

                            if (x == ix_end && x_end < ix_end + 1)
                                pixel_coverage *= (x_end - ix_end);

                            coverage_buffer[x] += pixel_coverage / SUBPIXEL_PRECISION;
                        }
                    }
                }
            }
        }

        for (uint32_t x = 0; x < fb->vinfo.xres; x++) {
            if (coverage_buffer[x] > 0.0f) {
                if (coverage_buffer[x] > 1.0f) coverage_buffer[x] = 1.0f;

                if (coverage_buffer[x] > 0.98f) {
                    set_pixel(fb, x, y, fill_color);
                } else {
                    uint32_t aa_color = blend_color_vibrant(fill_color, coverage_buffer[x]);
                    set_pixel(fb, x, y, aa_color);
                }
            }
        }
    }

    free(coverage_buffer);
    free(intersections);
}

void render_svg_path(Framebuffer *fb, SVGPath *svg, DisplayInfo *display_info)
{
    static bool first_path = true;

    if (first_path) {
        for (uint32_t y = 0; y < fb->vinfo.yres; y++) {
            for (uint32_t x = 0; x < fb->vinfo.xres; x++) {
                set_pixel(fb, x, y, 0x00000000);
            }
        }
        first_path = false;
    }

    render_path(fb, svg, display_info);
}

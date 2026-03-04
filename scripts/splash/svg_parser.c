/*
 * Arch R — SVG path parser
 * SVG path parser for initramfs boot splash
 * Removed stdio.h (crashes in static glibc PID 1 initramfs)
 * Replaced sscanf with manual rgb() parsing
 */

#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "svg_parser.h"

#define INITIAL_CAPACITY 100
#define MAX_SUBPATHS 10

static Point current_point = {0, 0};
static Point start_point = {0, 0};

typedef struct {
    Path paths[MAX_SUBPATHS];
    int num_paths;
} CompoundPath;

static float parse_number(const char **str)
{
    while (isspace(**str) || **str == ',')
        (*str)++;

    char *end;
    float num = strtof(*str, &end);
    *str = end;
    return num;
}

static void add_point_to_path(Path *path, float x, float y)
{
    if (path->num_points >= path->capacity) {
        path->capacity *= 2;
        Point *new_points = realloc(path->points, path->capacity * sizeof(Point));
        if (!new_points)
            return;
        path->points = new_points;
    }
    path->points[path->num_points].x = x;
    path->points[path->num_points].y = y;
    path->num_points++;
}

static void add_compound_path_to_svg(SVGPath *svg, CompoundPath *compound)
{
    for (int i = 0; i < compound->num_paths; i++) {
        if (svg->num_paths >= svg->capacity) {
            svg->capacity *= 2;
            Path *new_paths = realloc(svg->paths, svg->capacity * sizeof(Path));
            if (!new_paths)
                return;
            svg->paths = new_paths;
        }
        svg->paths[svg->num_paths] = compound->paths[i];
        svg->paths[svg->num_paths].is_hole = (i > 0);
        svg->num_paths++;
    }
}

/* Manual rgb(r,g,b) parser — replaces sscanf (stdio.h not available) */
static int parse_int(const char **p)
{
    while (**p && !isdigit(**p) && **p != '-')
        (*p)++;
    int sign = 1;
    if (**p == '-') { sign = -1; (*p)++; }
    int val = 0;
    while (isdigit(**p)) {
        val = val * 10 + (**p - '0');
        (*p)++;
    }
    return sign * val;
}

Color parse_color(const char *color_str)
{
    Color color = {0, 0, 0, 255};

    if (color_str[0] == 'r' && color_str[1] == 'g' && color_str[2] == 'b' && color_str[3] == '(') {
        const char *p = color_str + 4;
        int r = parse_int(&p);
        int g = parse_int(&p);
        int b = parse_int(&p);
        color.r = (uint8_t)(r < 0 ? 0 : (r > 255 ? 255 : r));
        color.g = (uint8_t)(g < 0 ? 0 : (g > 255 ? 255 : g));
        color.b = (uint8_t)(b < 0 ? 0 : (b > 255 ? 255 : b));
    }

    return color;
}

SVGPath* parse_svg_path(const char *path_data, const char *style)
{
    SVGPath *svg = malloc(sizeof(SVGPath));
    if (!svg) return NULL;

    svg->paths = malloc(INITIAL_CAPACITY * sizeof(Path));
    if (!svg->paths) {
        free(svg);
        return NULL;
    }

    svg->num_paths = 0;
    svg->capacity = INITIAL_CAPACITY;
    svg->fill_color = parse_color(style);

    CompoundPath compound = {0};
    compound.num_paths = 0;

    Path *current_path = &compound.paths[0];
    current_path->points = malloc(INITIAL_CAPACITY * sizeof(Point));
    if (!current_path->points) {
        free(svg->paths);
        free(svg);
        return NULL;
    }
    current_path->num_points = 0;
    current_path->capacity = INITIAL_CAPACITY;
    current_path->is_hole = 0;

    const char *p = path_data;
    char command = 'M';
    float x1, y1, x2, y2, x3, y3;
    bool new_subpath = true;

    while (*p) {
        if (isalpha(*p)) {
            if (*p == 'M' && !new_subpath) {
                if (current_path->num_points > 0) {
                    compound.num_paths++;
                    if (compound.num_paths < MAX_SUBPATHS) {
                        current_path = &compound.paths[compound.num_paths];
                        current_path->points = malloc(INITIAL_CAPACITY * sizeof(Point));
                        current_path->num_points = 0;
                        current_path->capacity = INITIAL_CAPACITY;
                        current_path->is_hole = 1;
                    }
                }
            }
            command = *p++;
            new_subpath = (command == 'M');
        }

        switch (command) {
            case 'M':
                x1 = parse_number(&p);
                y1 = parse_number(&p);
                add_point_to_path(current_path, x1, y1);
                current_point.x = start_point.x = x1;
                current_point.y = start_point.y = y1;
                command = 'L';
                break;

            case 'L':
                x1 = parse_number(&p);
                y1 = parse_number(&p);
                add_point_to_path(current_path, x1, y1);
                current_point.x = x1;
                current_point.y = y1;
                break;

            case 'H':
                x1 = parse_number(&p);
                add_point_to_path(current_path, x1, current_point.y);
                current_point.x = x1;
                break;

            case 'V':
                y1 = parse_number(&p);
                add_point_to_path(current_path, current_point.x, y1);
                current_point.y = y1;
                break;

            case 'Z':
            case 'z':
                if (current_path->num_points > 0)
                    add_point_to_path(current_path, start_point.x, start_point.y);
                break;

            case 'C':
                x1 = parse_number(&p);
                y1 = parse_number(&p);
                x2 = parse_number(&p);
                y2 = parse_number(&p);
                x3 = parse_number(&p);
                y3 = parse_number(&p);

                for (float t = 0; t <= 1; t += 0.1f) {
                    float t2 = t * t;
                    float t3 = t2 * t;
                    float mt = 1 - t;
                    float mt2 = mt * mt;
                    float mt3 = mt2 * mt;

                    float px = current_point.x * mt3 +
                              3 * x1 * mt2 * t +
                              3 * x2 * mt * t2 +
                              x3 * t3;

                    float py = current_point.y * mt3 +
                              3 * y1 * mt2 * t +
                              3 * y2 * mt * t2 +
                              y3 * t3;

                    add_point_to_path(current_path, px, py);
                }

                current_point.x = x3;
                current_point.y = y3;
                break;

            default:
                while (*p && !isalpha(*p)) p++;
                break;
        }

        while (isspace(*p)) p++;
    }

    if (current_path->num_points > 0)
        compound.num_paths++;

    add_compound_path_to_svg(svg, &compound);

    return svg;
}

void free_svg_path(SVGPath *svg)
{
    if (svg) {
        for (uint32_t i = 0; i < svg->num_paths; i++)
            free(svg->paths[i].points);
        free(svg->paths);
        free(svg);
    }
}

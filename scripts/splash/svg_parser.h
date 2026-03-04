#ifndef SVG_PARSER_H
#define SVG_PARSER_H

#include "svg_types.h"

SVGPath* parse_svg_path(const char *path_data, const char *style);
void free_svg_path(SVGPath *path);
Color parse_color(const char *color_str);

#endif

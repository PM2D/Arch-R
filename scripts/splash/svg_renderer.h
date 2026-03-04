#ifndef SVG_RENDERER_H
#define SVG_RENDERER_H

#include "fbsplash.h"
#include "svg_types.h"

void render_svg_path(Framebuffer *fb, SVGPath *svg, DisplayInfo *display_info);
void rotate_svg_path(SVGPath *svg, int angle);

#endif

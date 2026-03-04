#ifndef FBSPLASH_H
#define FBSPLASH_H

#include <stdint.h>
#include <linux/fb.h>

typedef struct {
    int fd;
    uint8_t *buffer;
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    size_t screensize;
} Framebuffer;

typedef struct {
    uint32_t screen_width;
    uint32_t screen_height;
    uint32_t svg_width;
    uint32_t svg_height;
    uint32_t x_offset;
    uint32_t y_offset;
    float base_svg_width;
    float base_svg_height;
} DisplayInfo;

Framebuffer* fb_init(const char *fb_device);
void fb_cleanup(Framebuffer *fb);
void set_pixel(Framebuffer *fb, uint32_t x, uint32_t y, uint32_t color);
void blend_pixel(Framebuffer *fb, uint32_t x, uint32_t y, uint32_t color, float alpha);
void fb_flush(Framebuffer *fb);
DisplayInfo* calculate_display_info(Framebuffer *fb, float base_width, float base_height);

#endif

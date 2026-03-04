/*
 * Arch R — Framebuffer splash abstraction
 * Framebuffer abstraction for initramfs boot splash
 * Removed stdio.h (crashes in static glibc PID 1 initramfs)
 */

#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "fbsplash.h"

Framebuffer* fb_init(const char *fb_device)
{
    Framebuffer *fb = calloc(1, sizeof(Framebuffer));
    if (!fb)
        return NULL;

    fb->fd = open(fb_device, O_RDWR);
    if (fb->fd == -1) {
        free(fb);
        return NULL;
    }

    if (ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->vinfo) == -1 ||
        ioctl(fb->fd, FBIOGET_FSCREENINFO, &fb->finfo) == -1) {
        close(fb->fd);
        free(fb);
        return NULL;
    }

    fb->screensize = fb->vinfo.yres_virtual * fb->finfo.line_length;

    fb->buffer = malloc(fb->screensize);
    if (!fb->buffer) {
        close(fb->fd);
        free(fb);
        return NULL;
    }

    /* Clear to black */
    memset(fb->buffer, 0, fb->screensize);

    return fb;
}

void set_pixel(Framebuffer *fb, uint32_t x, uint32_t y, uint32_t color)
{
    if (x >= fb->vinfo.xres || y >= fb->vinfo.yres)
        return;

    size_t location = (x + fb->vinfo.xoffset) * (fb->vinfo.bits_per_pixel / 8) +
                      (y + fb->vinfo.yoffset) * fb->finfo.line_length;

    if (location >= fb->screensize)
        return;

    if (fb->vinfo.bits_per_pixel == 32) {
        *((uint32_t*)(fb->buffer + location)) = color;
    } else if (fb->vinfo.bits_per_pixel == 16) {
        uint8_t r = (color >> 16) & 0xFF;
        uint8_t g = (color >> 8) & 0xFF;
        uint8_t b = color & 0xFF;
        uint16_t color16 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
        *((uint16_t*)(fb->buffer + location)) = color16;
    }
}

void blend_pixel(Framebuffer *fb, uint32_t x, uint32_t y, uint32_t color, float alpha)
{
    if (x >= fb->vinfo.xres || y >= fb->vinfo.yres || alpha <= 0.0f)
        return;

    if (alpha >= 1.0f) {
        set_pixel(fb, x, y, color);
        return;
    }

    size_t location = (x + fb->vinfo.xoffset) * (fb->vinfo.bits_per_pixel / 8) +
                     (y + fb->vinfo.yoffset) * fb->finfo.line_length;

    if (location >= fb->screensize)
        return;

    uint8_t fg_r = (color >> 16) & 0xFF;
    uint8_t fg_g = (color >> 8) & 0xFF;
    uint8_t fg_b = color & 0xFF;

    uint32_t bg_color = 0;
    if (fb->vinfo.bits_per_pixel == 32) {
        bg_color = *((uint32_t*)(fb->buffer + location));
    } else if (fb->vinfo.bits_per_pixel == 16) {
        uint16_t color16 = *((uint16_t*)(fb->buffer + location));
        uint8_t r = ((color16 >> 11) & 0x1F) << 3;
        uint8_t g = ((color16 >> 5) & 0x3F) << 2;
        uint8_t b = (color16 & 0x1F) << 3;
        bg_color = (r << 16) | (g << 8) | b;
    }

    uint8_t bg_r = (bg_color >> 16) & 0xFF;
    uint8_t bg_g = (bg_color >> 8) & 0xFF;
    uint8_t bg_b = bg_color & 0xFF;

    uint8_t r = (uint8_t)(fg_r * alpha + bg_r * (1.0f - alpha));
    uint8_t g = (uint8_t)(fg_g * alpha + bg_g * (1.0f - alpha));
    uint8_t b = (uint8_t)(fg_b * alpha + bg_b * (1.0f - alpha));

    uint32_t blended = (r << 16) | (g << 8) | b;
    set_pixel(fb, x, y, blended);
}

void fb_flush(Framebuffer *fb)
{
    if (fb && fb->buffer) {
        lseek(fb->fd, 0, SEEK_SET);
        (void)write(fb->fd, fb->buffer, fb->screensize);
    }
}

void fb_cleanup(Framebuffer *fb)
{
    if (fb) {
        if (fb->buffer)
            free(fb->buffer);
        if (fb->fd >= 0)
            close(fb->fd);
        free(fb);
    }
}

DisplayInfo* calculate_display_info(Framebuffer *fb, float base_width, float base_height)
{
    DisplayInfo *info = calloc(1, sizeof(DisplayInfo));
    if (!info)
        return NULL;

    info->screen_width = fb->vinfo.xres;
    info->screen_height = fb->vinfo.yres;
    info->base_svg_width = base_width;
    info->base_svg_height = base_height;

    float target_width = info->screen_width * 0.6f;
    float target_height = target_width * (base_height / base_width);

    if (target_height > info->screen_height * 0.6f) {
        target_height = info->screen_height * 0.6f;
        target_width = target_height * (base_width / base_height);
    }

    info->svg_width = (uint32_t)target_width;
    info->svg_height = (uint32_t)target_height;
    info->x_offset = (info->screen_width - info->svg_width) / 2;
    info->y_offset = (info->screen_height - info->svg_height) / 2;

    return info;
}

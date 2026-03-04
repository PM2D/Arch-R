/*
 * archr-init — initramfs /init for Arch R
 *
 * Shows SVG splash on /dev/fb0 IMMEDIATELY after kernel boot (before systemd).
 * Logo is rendered from SVG path data (anti-aliased, resolution-independent).
 * Then mounts the real root filesystem and switch_root to /sbin/init.
 *
 * Initramfs contents:
 *   /init        → this binary (static aarch64, SVG splash built-in)
 *   /dev/        → empty (devtmpfs mounted here)
 *   /proc/       → empty (proc mounted temporarily)
 *   /newroot/    → empty (real root mounted here)
 *
 * Build:
 *   aarch64-linux-gnu-gcc -static -O2 -o archr-init archr-init.c \
 *       splash/fbsplash.c splash/svg_parser.c splash/svg_renderer.c -lm
 */

#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <linux/fb.h>
#include <errno.h>
#include <time.h>

/* SVG splash rendering */
#include "fbsplash.h"
#include "svg_parser.h"
#include "svg_renderer.h"
#include "archr-logo.h"

/* ---- Logging (dmesg + in-memory buffer, flushed to file after root mount) ---- */

static int kmsg_fd = -1;
#define LOG_BUF_SIZE 4096
static char log_buf[LOG_BUF_SIZE];
static int log_pos = 0;

/* Simple snprintf — avoid pulling in full stdio */
static int fmt_int(char *buf, int val)
{
    if (val < 0) { *buf++ = '-'; val = -val; return 1 + fmt_int(buf, val); }
    if (val >= 10) { int n = fmt_int(buf, val / 10); return n + fmt_int(buf + n, val % 10); }
    *buf = '0' + val;
    return 1;
}

static void klog(const char *msg)
{
    /* Save msg pointer before we iterate */
    const char *saved_msg = msg;

    /* Write to dmesg */
    if (kmsg_fd < 0)
        kmsg_fd = open("/dev/kmsg", O_WRONLY);
    if (kmsg_fd >= 0) {
        char buf[256];
        int i = 0;
        const char *prefix = "archr-init: ";
        while (*prefix) buf[i++] = *prefix++;
        while (*msg && i < 250) buf[i++] = *msg++;
        buf[i++] = '\n';
        (void)write(kmsg_fd, buf, i);
    }

    /* Buffer for file log (using saved pointer) */
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    if (log_pos < LOG_BUF_SIZE - 200) {
        log_pos += fmt_int(log_buf + log_pos, (int)ts.tv_sec);
        log_buf[log_pos++] = '.';
        int ms = (int)(ts.tv_nsec / 1000000);
        if (ms < 100) log_buf[log_pos++] = '0';
        if (ms < 10) log_buf[log_pos++] = '0';
        log_pos += fmt_int(log_buf + log_pos, ms);
        log_buf[log_pos++] = ' ';
        while (*saved_msg && log_pos < LOG_BUF_SIZE - 2)
            log_buf[log_pos++] = *saved_msg++;
        log_buf[log_pos++] = '\n';
    }
}

static void klog_num(const char *prefix, int val)
{
    char buf[128];
    int i = 0;
    while (*prefix && i < 100) buf[i++] = *prefix++;
    i += fmt_int(buf + i, val);
    buf[i] = 0;
    klog(buf);
}

static void flush_log(const char *path)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        (void)write(fd, log_buf, log_pos);
        close(fd);
    }
}

/* ---- SVG Splash display (renders logo paths to /dev/fb0) ---- */

static void show_splash(void)
{
    /* Wait for fb0 (DRM probe might still be finishing) */
    int fb_fd = -1;
    int retries;
    for (retries = 0; retries < 30; retries++) {
        fb_fd = open("/dev/fb0", O_RDWR);
        if (fb_fd >= 0) break;
        usleep(100000); /* 100ms, max 3s */
    }
    if (fb_fd < 0) {
        klog("splash: fb0 NOT FOUND after 3s");
        return;
    }
    klog_num("splash: fb0 opened, retries=", retries);
    close(fb_fd); /* fb_init() will reopen */

    Framebuffer *fb = fb_init("/dev/fb0");
    if (!fb) {
        klog("splash: fb_init failed");
        return;
    }

    klog_num("splash: fb width=", (int)fb->vinfo.xres);
    klog_num("splash: fb height=", (int)fb->vinfo.yres);

    DisplayInfo *di = calculate_display_info(fb, ARCHR_SVG_WIDTH, ARCHR_SVG_HEIGHT);
    if (!di) {
        klog("splash: display_info failed");
        fb_cleanup(fb);
        return;
    }

    for (int i = 0; i < ARCHR_NUM_PATHS; i++) {
        SVGPath *svg = parse_svg_path(archr_svg_paths[i], archr_svg_colors[i]);
        if (!svg) continue;
        render_svg_path(fb, svg, di);
        free_svg_path(svg);
    }

    fb_flush(fb);
    klog("splash: SVG rendered");

    free(di);
    fb_cleanup(fb);
}

/* ---- Main: initramfs /init ---- */

int main(int argc, char *argv[])
{
    /* 1. Mount devtmpfs on /dev (kernel creates device nodes here) */
    mkdir("/dev", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    klog("=== INITRAMFS STARTED ===");

    /* 2. Show splash from embedded data — no file I/O needed */
    show_splash();

    /* 3. Parse rw flag from kernel cmdline */
    mkdir("/proc", 0755);
    mount("proc", "/proc", "proc", 0, NULL);

    char cmdline[4096];
    memset(cmdline, 0, sizeof(cmdline));
    int fd = open("/proc/cmdline", O_RDONLY);
    if (fd >= 0) {
        (void)read(fd, cmdline, sizeof(cmdline) - 1);
        close(fd);
    }
    umount("/proc");

    /* Check rw flag — handle both " rw" and cmdline starting with "rw" */
    unsigned long mflags = MS_NOATIME;
    if (strstr(cmdline, " rw") || strncmp(cmdline, "rw", 2) == 0)
        mflags |= 0; /* rw is default without MS_RDONLY */
    else
        mflags |= MS_RDONLY;

    /* 4. Mount real root — device-agnostic.
     * Root is always SD card partition 2. On original R36S (with eMMC)
     * it's mmcblk1p2, on clone (no eMMC) it's mmcblk0p2.
     * Try both — whichever succeeds is root. */
    static const char *root_candidates[] = {
        "/dev/mmcblk1p2",   /* original: eMMC=mmcblk0, SD=mmcblk1 */
        "/dev/mmcblk0p2",   /* clone: SD=mmcblk0 (no eMMC) */
    };

    mkdir("/newroot", 0755);
    int mounted = 0;
    int mount_retries;

    for (mount_retries = 0; mount_retries < 50; mount_retries++) {
        int c;
        for (c = 0; c < 2; c++) {
            if (mount(root_candidates[c], "/newroot", "ext4", mflags, NULL) == 0) {
                klog(root_candidates[c]);
                mounted = 1;
                break;
            }
        }
        if (mounted) break;
        usleep(100000); /* 100ms, max 5s total */
    }

    if (!mounted) {
        klog("FATAL: could not mount root!");
        for (;;) sleep(60);
    }

    klog_num("root mounted, retries=", mount_retries);

    /* 5. Write diagnostic log to root filesystem */
    klog("switch_root");
    flush_log("/newroot/var/log/archr-init.log");

    /* 6. Move /dev to new root */
    mount("/dev", "/newroot/dev", NULL, MS_MOVE, NULL);

    /* 7. switch_root: pivot to real rootfs and exec systemd */
    if (kmsg_fd >= 0) close(kmsg_fd);

    (void)chdir("/newroot");
    mount(".", "/", NULL, MS_MOVE, NULL);
    (void)chroot(".");
    (void)chdir("/");

    execl("/sbin/init", "/sbin/init", NULL);

    /* Should never reach here */
    return 1;
}

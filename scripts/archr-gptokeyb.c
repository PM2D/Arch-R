/*
 * archr-gptokeyb — Lightweight gamepad-to-keyboard/mouse mapper for Linux ports
 *
 * Compatible with ROCKNIX .gptk config format.
 * Opens the gamepad, creates a virtual keyboard+mouse via uinput,
 * and maps buttons/analog to keys/mouse based on a config file.
 *
 * Usage:
 *   archr-gptokeyb "game_binary" [-c config.gptk]
 *
 * The first argument is the process name to kill on SELECT+START combo.
 * If -c is omitted, uses /etc/archr/gptokeyb/default.gptk
 *
 * Build:
 *   aarch64-linux-gnu-gcc -static -O2 -o archr-gptokeyb archr-gptokeyb.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <dirent.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include <linux/uinput.h>

/* ── Configuration ─────────────────────────────────────────────────────── */

#define MAX_MAPS        64
#define ANALOG_DEAD     8000    /* deadzone for analog axes (of 32767) */
#define MOUSE_SPEED     12      /* pixels per event for analog-as-mouse */
#define KILL_HOLD_MS    1000    /* hold SELECT+START this long to kill */
#define CONF_DEFAULT    "/etc/archr/gptokeyb/default.gptk"
#define POLL_MS         16      /* ~60 Hz poll interval */

/* ── Mapping types ─────────────────────────────────────────────────────── */

enum map_type { MAP_KEY, MAP_MOUSE_MOVE };

struct mapping {
    int src_code;           /* source evdev code */
    int src_type;           /* EV_KEY or EV_ABS */
    int negative;           /* for ABS: 1=map negative direction */
    enum map_type dst_type;
    int dst_code;           /* KEY_xxx or direction: 0=X+, 1=X-, 2=Y-, 3=Y+ */
};

static struct mapping maps[MAX_MAPS];
static int num_maps;
static int analog_as_mouse;  /* left_analog_as_mouse = true */

/* ── Name tables ───────────────────────────────────────────────────────── */

struct name_code { const char *name; int code; };

/* Gamepad button names → evdev source codes */
static const struct name_code btn_names[] = {
    {"a",      BTN_SOUTH},   {"b",      BTN_EAST},
    {"x",      BTN_WEST},    {"y",      BTN_NORTH},
    {"back",   BTN_SELECT},  {"select", BTN_SELECT},
    {"start",  BTN_START},   {"guide",  BTN_MODE},
    {"l1",     BTN_TL},      {"r1",     BTN_TR},
    {"l2",     BTN_TL2},     {"r2",     BTN_TR2},
    {"l3",     BTN_THUMBL},  {"r3",     BTN_THUMBR},
    {"up",     BTN_DPAD_UP}, {"down",   BTN_DPAD_DOWN},
    {"left",   BTN_DPAD_LEFT}, {"right", BTN_DPAD_RIGHT},
    {NULL, 0}
};

/* Analog direction names → (ABS code, negative flag) */
static const struct {
    const char *name; int abs_code; int negative;
} analog_names[] = {
    {"left_analog_up",    ABS_Y,  1}, {"left_analog_down",  ABS_Y,  0},
    {"left_analog_left",  ABS_X,  1}, {"left_analog_right", ABS_X,  0},
    {"right_analog_up",   ABS_RY, 1}, {"right_analog_down", ABS_RY, 0},
    {"right_analog_left", ABS_RX, 1}, {"right_analog_right",ABS_RX, 0},
    {NULL, 0, 0}
};

/* Keyboard key names → evdev destination codes */
static const struct name_code key_names[] = {
    {"esc", KEY_ESC}, {"escape", KEY_ESC},
    {"enter", KEY_ENTER}, {"return", KEY_ENTER},
    {"space", KEY_SPACE}, {"tab", KEY_TAB},
    {"backspace", KEY_BACKSPACE}, {"delete", KEY_DELETE},
    {"insert", KEY_INSERT}, {"home", KEY_HOME}, {"end", KEY_END},
    {"pageup", KEY_PAGEUP}, {"pagedown", KEY_PAGEDOWN},
    {"up", KEY_UP}, {"down", KEY_DOWN},
    {"left", KEY_LEFT}, {"right", KEY_RIGHT},
    {"a", KEY_A}, {"b", KEY_B}, {"c", KEY_C}, {"d", KEY_D},
    {"e", KEY_E}, {"f", KEY_F}, {"g", KEY_G}, {"h", KEY_H},
    {"i", KEY_I}, {"j", KEY_J}, {"k", KEY_K}, {"l", KEY_L},
    {"m", KEY_M}, {"n", KEY_N}, {"o", KEY_O}, {"p", KEY_P},
    {"q", KEY_Q}, {"r", KEY_R}, {"s", KEY_S}, {"t", KEY_T},
    {"u", KEY_U}, {"v", KEY_V}, {"w", KEY_W}, {"x", KEY_X},
    {"y", KEY_Y}, {"z", KEY_Z},
    {"0", KEY_0}, {"1", KEY_1}, {"2", KEY_2}, {"3", KEY_3},
    {"4", KEY_4}, {"5", KEY_5}, {"6", KEY_6}, {"7", KEY_7},
    {"8", KEY_8}, {"9", KEY_9},
    {"f1", KEY_F1}, {"f2", KEY_F2}, {"f3", KEY_F3}, {"f4", KEY_F4},
    {"f5", KEY_F5}, {"f6", KEY_F6}, {"f7", KEY_F7}, {"f8", KEY_F8},
    {"f9", KEY_F9}, {"f10", KEY_F10}, {"f11", KEY_F11}, {"f12", KEY_F12},
    {"lshift", KEY_LEFTSHIFT}, {"rshift", KEY_RIGHTSHIFT},
    {"lctrl", KEY_LEFTCTRL}, {"rctrl", KEY_RIGHTCTRL},
    {"lalt", KEY_LEFTALT}, {"ralt", KEY_RIGHTALT},
    {"minus", KEY_MINUS}, {"equal", KEY_EQUAL},
    {"comma", KEY_COMMA}, {"dot", KEY_DOT}, {"slash", KEY_SLASH},
    {"semicolon", KEY_SEMICOLON}, {"apostrophe", KEY_APOSTROPHE},
    {"leftbrace", KEY_LEFTBRACE}, {"rightbrace", KEY_RIGHTBRACE},
    {"backslash", KEY_BACKSLASH}, {"grave", KEY_GRAVE},
    {"mouse_left", BTN_LEFT}, {"mouse_right", BTN_RIGHT},
    {"mouse_middle", BTN_MIDDLE},
    {NULL, 0}
};

/* Special destination names for mouse movement */
static const struct {
    const char *name; int dir; /* 0=X+, 1=X-, 2=Y-, 3=Y+ */
} mouse_dirs[] = {
    {"mouse_movement_right", 0}, {"mouse_movement_left", 1},
    {"mouse_movement_up", 2},    {"mouse_movement_down", 3},
    {NULL, 0}
};

/* ── Lookup helpers ────────────────────────────────────────────────────── */

static int find_key_code(const char *name)
{
    for (const struct name_code *k = key_names; k->name; k++)
        if (strcasecmp(k->name, name) == 0) return k->code;
    return -1;
}

static int find_mouse_dir(const char *name)
{
    for (int i = 0; mouse_dirs[i].name; i++)
        if (strcasecmp(mouse_dirs[i].name, name) == 0) return mouse_dirs[i].dir;
    return -1;
}

/* ── Config parsing ────────────────────────────────────────────────────── */

static void parse_config(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "gptokeyb: cannot open %s: %s\n", path, strerror(errno)); return; }

    char line[256];
    while (fgets(line, sizeof(line), f)) {
        /* Strip comment and whitespace */
        char *hash = strchr(line, '#');
        if (hash) *hash = '\0';

        char lhs[64], rhs[64];
        if (sscanf(line, " %63[^= ] = %63s", lhs, rhs) != 2) continue;

        /* Special settings */
        if (strcasecmp(lhs, "left_analog_as_mouse") == 0) {
            analog_as_mouse = (strcasecmp(rhs, "true") == 0 || strcmp(rhs, "1") == 0);
            continue;
        }
        if (strcasecmp(lhs, "deadzone_x") == 0 || strcasecmp(lhs, "deadzone_y") == 0 ||
            strcasecmp(lhs, "deadzone_triggers") == 0 || strcasecmp(lhs, "mouse_scale") == 0 ||
            strcasecmp(lhs, "mouse_delay") == 0 || strcasecmp(lhs, "mouse_slow_scale") == 0)
            continue; /* acknowledged but not used — global constants */

        if (num_maps >= MAX_MAPS) break;

        struct mapping *m = &maps[num_maps];

        /* Try button source */
        int found_src = 0;
        for (const struct name_code *b = btn_names; b->name; b++) {
            if (strcasecmp(lhs, b->name) == 0) {
                m->src_code = b->code;
                m->src_type = EV_KEY;
                m->negative = 0;
                found_src = 1;
                break;
            }
        }

        /* Try analog source */
        if (!found_src) {
            for (int i = 0; analog_names[i].name; i++) {
                if (strcasecmp(lhs, analog_names[i].name) == 0) {
                    m->src_code = analog_names[i].abs_code;
                    m->src_type = EV_ABS;
                    m->negative = analog_names[i].negative;
                    found_src = 1;
                    break;
                }
            }
        }
        if (!found_src) continue;

        /* Try mouse movement destination */
        int mdir = find_mouse_dir(rhs);
        if (mdir >= 0) {
            m->dst_type = MAP_MOUSE_MOVE;
            m->dst_code = mdir;
            num_maps++;
            continue;
        }

        /* Try keyboard/mouse-button destination */
        int kcode = find_key_code(rhs);
        if (kcode >= 0) {
            m->dst_type = MAP_KEY;
            m->dst_code = kcode;
            num_maps++;
        }
    }
    fclose(f);
    fprintf(stderr, "gptokeyb: loaded %d mappings from %s\n", num_maps, path);
}

/* ── uinput setup ──────────────────────────────────────────────────────── */

static int uinput_fd = -1;

static int setup_uinput(void)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) { perror("gptokeyb: open /dev/uinput"); return -1; }

    /* Enable key events */
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    for (int i = 0; i < KEY_MAX; i++)
        ioctl(fd, UI_SET_KEYBIT, i);
    /* Mouse buttons */
    ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT);
    ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE);

    /* Enable relative axes for mouse */
    ioctl(fd, UI_SET_EVBIT, EV_REL);
    ioctl(fd, UI_SET_RELBIT, REL_X);
    ioctl(fd, UI_SET_RELBIT, REL_Y);

    struct uinput_setup usetup;
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_VIRTUAL;
    usetup.id.vendor  = 0x1234;
    usetup.id.product = 0x5678;
    snprintf(usetup.name, UINPUT_MAX_NAME_SIZE, "Arch R Virtual Keyboard");

    ioctl(fd, UI_DEV_SETUP, &usetup);
    ioctl(fd, UI_DEV_CREATE);
    usleep(100000); /* let udev catch up */

    uinput_fd = fd;
    return 0;
}

static void emit(int type, int code, int value)
{
    struct input_event ev = {0};
    ev.type = type;
    ev.code = code;
    ev.value = value;
    write(uinput_fd, &ev, sizeof(ev));
}

static void emit_sync(void)
{
    emit(EV_SYN, SYN_REPORT, 0);
}

static void emit_key(int code, int value)
{
    emit(EV_KEY, code, value);
    emit_sync();
}

static void emit_mouse(int dx, int dy)
{
    if (dx) emit(EV_REL, REL_X, dx);
    if (dy) emit(EV_REL, REL_Y, dy);
    if (dx || dy) emit_sync();
}

/* ── Gamepad device detection ──────────────────────────────────────────── */

static int find_gamepad(void)
{
    char path[64];
    for (int i = 0; i < 32; i++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;

        unsigned long keybits[(KEY_MAX + 7) / 8 / sizeof(unsigned long) + 1];
        memset(keybits, 0, sizeof(keybits));
        ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits);

        /* Check for BTN_SOUTH (gamepad) */
        int has_south = (keybits[BTN_SOUTH / (8 * sizeof(unsigned long))] >>
                        (BTN_SOUTH % (8 * sizeof(unsigned long)))) & 1;
        if (has_south) {
            char name[256] = {0};
            ioctl(fd, EVIOCGNAME(sizeof(name)), name);
            fprintf(stderr, "gptokeyb: using gamepad '%s' (%s)\n", name, path);
            return fd;
        }
        close(fd);
    }
    return -1;
}

/* ── Globals ───────────────────────────────────────────────────────────── */

static volatile sig_atomic_t running = 1;
static const char *kill_process;  /* process name to kill on SELECT+START */

/* Analog axis state for mouse emulation */
static int axis_state[ABS_MAX + 1];
/* Track which analog-as-key directions are currently pressed */
static int analog_key_state[MAX_MAPS];

static void sig_handler(int sig) { (void)sig; running = 0; }

/* ── Main loop ─────────────────────────────────────────────────────────── */

int main(int argc, char **argv)
{
    const char *config = CONF_DEFAULT;
    kill_process = NULL;

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            config = argv[++i];
        } else if (argv[i][0] != '-') {
            kill_process = argv[i];
        }
    }

    parse_config(config);

    /* If left_analog_as_mouse and no explicit analog mappings, add defaults */
    if (analog_as_mouse) {
        int has_analog_map = 0;
        for (int i = 0; i < num_maps; i++) {
            if (maps[i].src_type == EV_ABS &&
                (maps[i].src_code == ABS_X || maps[i].src_code == ABS_Y)) {
                has_analog_map = 1;
                break;
            }
        }
        if (!has_analog_map && num_maps + 4 <= MAX_MAPS) {
            /* X+ */ maps[num_maps++] = (struct mapping){ABS_X, EV_ABS, 0, MAP_MOUSE_MOVE, 0};
            /* X- */ maps[num_maps++] = (struct mapping){ABS_X, EV_ABS, 1, MAP_MOUSE_MOVE, 1};
            /* Y- */ maps[num_maps++] = (struct mapping){ABS_Y, EV_ABS, 1, MAP_MOUSE_MOVE, 2};
            /* Y+ */ maps[num_maps++] = (struct mapping){ABS_Y, EV_ABS, 0, MAP_MOUSE_MOVE, 3};
        }
    }

    int gamepad = find_gamepad();
    if (gamepad < 0) { fprintf(stderr, "gptokeyb: no gamepad found\n"); return 1; }

    if (setup_uinput() < 0) { close(gamepad); return 1; }

    /* Grab the gamepad so the real device is hidden from applications */
    if (ioctl(gamepad, EVIOCGRAB, 1) < 0)
        fprintf(stderr, "gptokeyb: warning: could not grab device\n");

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    fprintf(stderr, "gptokeyb: running (kill_process=%s)\n",
            kill_process ? kill_process : "(none)");

    int select_held = 0, start_held = 0;
    struct timespec kill_start = {0, 0};
    memset(axis_state, 0, sizeof(axis_state));
    memset(analog_key_state, 0, sizeof(analog_key_state));

    while (running) {
        struct input_event ev;
        int n = read(gamepad, &ev, sizeof(ev));
        if (n < 0) {
            if (errno == EAGAIN) {
                usleep(POLL_MS * 1000);

                /* Emit mouse movement from analog axes */
                for (int i = 0; i < num_maps; i++) {
                    if (maps[i].src_type != EV_ABS || maps[i].dst_type != MAP_MOUSE_MOVE) continue;
                    int val = axis_state[maps[i].src_code];
                    if (maps[i].negative) val = -val;
                    if (val < ANALOG_DEAD) continue;
                    int speed = (val - ANALOG_DEAD) * MOUSE_SPEED / (32767 - ANALOG_DEAD);
                    if (speed < 1) speed = 1;
                    switch (maps[i].dst_code) {
                        case 0: emit_mouse( speed, 0); break;  /* X+ */
                        case 1: emit_mouse(-speed, 0); break;  /* X- */
                        case 2: emit_mouse(0, -speed); break;  /* Y- (up) */
                        case 3: emit_mouse(0,  speed); break;  /* Y+ (down) */
                    }
                }
                continue;
            }
            break; /* real error */
        }
        if (n != sizeof(ev)) continue;

        /* ── Button events ──────────────────────────────────── */
        if (ev.type == EV_KEY) {
            /* Kill combo: SELECT + START */
            if (ev.code == BTN_SELECT) {
                select_held = (ev.value >= 1);
                if (select_held && start_held)
                    clock_gettime(CLOCK_MONOTONIC, &kill_start);
            }
            if (ev.code == BTN_START) {
                start_held = (ev.value >= 1);
                if (select_held && start_held)
                    clock_gettime(CLOCK_MONOTONIC, &kill_start);
            }
            if (!select_held || !start_held)
                kill_start.tv_sec = 0;

            /* Check kill hold time */
            if (kill_start.tv_sec > 0 && select_held && start_held) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                long elapsed_ms = (now.tv_sec - kill_start.tv_sec) * 1000 +
                                  (now.tv_nsec - kill_start.tv_nsec) / 1000000;
                if (elapsed_ms >= KILL_HOLD_MS && kill_process) {
                    char cmd[256];
                    snprintf(cmd, sizeof(cmd), "pkill -9 -x '%s'", kill_process);
                    system(cmd);
                    fprintf(stderr, "gptokeyb: killed %s\n", kill_process);
                    kill_start.tv_sec = 0;
                }
            }

            /* Map button to key */
            for (int i = 0; i < num_maps; i++) {
                if (maps[i].src_type == EV_KEY && maps[i].src_code == ev.code) {
                    if (maps[i].dst_type == MAP_KEY) {
                        emit_key(maps[i].dst_code, ev.value);
                    }
                    break;
                }
            }
        }

        /* ── Analog axis events ─────────────────────────────── */
        if (ev.type == EV_ABS) {
            axis_state[ev.code] = ev.value;

            /* Analog-to-key mapping (for dpad emulation) */
            for (int i = 0; i < num_maps; i++) {
                if (maps[i].src_type != EV_ABS || maps[i].src_code != ev.code) continue;
                if (maps[i].dst_type != MAP_KEY) continue;

                int val = ev.value;
                if (maps[i].negative) val = -val;
                int pressed = (val > ANALOG_DEAD);

                if (pressed && !analog_key_state[i]) {
                    emit_key(maps[i].dst_code, 1);
                    analog_key_state[i] = 1;
                } else if (!pressed && analog_key_state[i]) {
                    emit_key(maps[i].dst_code, 0);
                    analog_key_state[i] = 0;
                }
            }
        }
    }

    /* Cleanup */
    ioctl(gamepad, EVIOCGRAB, 0);
    close(gamepad);
    ioctl(uinput_fd, UI_DEV_DESTROY);
    close(uinput_fd);
    fprintf(stderr, "gptokeyb: stopped\n");
    return 0;
}

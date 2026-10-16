/*
 * pzemu-bridge.c — Generic libretro frontend for PZFB game process protocol
 *
 * Loads any libretro core via dlopen, pipes RGBA frames to stdout,
 * reads button events from stdin, handles audio via SDL2.
 *
 * Usage: pzemu-bridge <core_path> <rom_path> <width> <height> [system_dir] [save_dir] [port_device]
 *
 * Protocol:
 *   stdout → raw RGBA frames (width * height * 4 bytes each), continuous
 *   stdin  ← events (2 bytes each: [value:u8, keycode:u8])
 *
 *   keycode  0–15  libretro joypad button, value 1 = pressed / 0 = released
 *   keycode  16    save state            (on value != 0)
 *   keycode  17    load state            (on value != 0)
 *   keycode  18    pause TOGGLE (legacy) (on value != 0)
 *   keycode  19    PAUSE ON   (idempotent, on value != 0)
 *   keycode  20    PAUSE OFF  (idempotent, on value != 0)
 *   keycode  21    QUIT — flush SRAM and exit cleanly (on value != 0)
 *   keycode  64–67 analog axes leftX/leftY/rightX/rightY, value 0..255 (128 = center)
 *   keycode  68    VOLUME, value 0..255 → linear gain value/255 (0 = mute); default 255
 *
 *   stdin EOF / broken pipe, frame-pipe write failure, SIGTERM/SIGINT and
 *   RETRO_ENVIRONMENT_SHUTDOWN all behave like QUIT.
 *
 * Persistence:
 *   SRAM  → <save_dir>/<rom>.srm   written on exit (exactly once) and every
 *           SRAM_FLUSH_INTERVAL_MS while running if its contents changed.
 *   state → <save_dir>/<rom>.state
 *   All writes are atomic: temp file in the same directory, then rename.
 *
 * Paths are UTF-8 everywhere internally. On Windows argv is re-derived from
 * the wide command line and every file/library API is called through the
 * wide-char variant (_wfopen, LoadLibraryW, _wmkdir, MoveFileExW), so paths
 * outside the ANSI codepage work. Cores receive UTF-8 as the libretro API
 * requires.
 */

#include "libretro.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include <errno.h>
#include <signal.h>
#include <sys/stat.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include <io.h>
#include <fcntl.h>
#include <direct.h>
#include <wchar.h>
#define load_func(h, s)  ((void*)GetProcAddress((HMODULE)(h), s))
#define close_lib(h)     FreeLibrary((HMODULE)(h))
/* MinGW lacks strndup */
static char *strndup_compat(const char *s, size_t n) {
    size_t len = strlen(s);
    if (n < len) len = n;
    char *r = (char *)malloc(len + 1);
    if (r) { memcpy(r, s, len); r[len] = '\0'; }
    return r;
}
#define strndup strndup_compat
#else
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#define load_func(h, s)  dlsym(h, s)
#define close_lib(h)     dlclose(h)
#endif

#include <SDL.h>

/* ---------- tunables ---------- */

#define SRAM_FLUSH_INTERVAL_MS 10000   /* periodic SRAM flush cadence (wall time) */
#define PATH_BUF               4096    /* max UTF-8 path length we handle */

/* ---------- helpers ---------- */

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

#define load_sym(V, S) do { \
    if (!((*(void**)&(V)) = load_func(g_core_handle, #S))) \
        die("Failed to load symbol '" #S "'"); \
} while (0)

/* ---------- UTF-8 path layer (Windows wide-char, POSIX passthrough) ---------- */

#ifdef _WIN32
/* UTF-8 → UTF-16, malloc'd; NULL on failure. */
static wchar_t *utf8_to_wide(const char *s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) { free(w); return NULL; }
    return w;
}

/* UTF-16 → UTF-8, malloc'd; NULL on failure. */
static char *wide_to_utf8(const wchar_t *w) {
    if (!w) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n);
    if (!s) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) <= 0) { free(s); return NULL; }
    return s;
}

static FILE *fopen_utf8(const char *path, const char *mode) {
    wchar_t wmode[8] = {0};
    size_t i;
    for (i = 0; i < 7 && mode[i]; i++) wmode[i] = (wchar_t)(unsigned char)mode[i];
    wchar_t *wpath = utf8_to_wide(path);
    if (!wpath) return NULL;
    FILE *f = _wfopen(wpath, wmode);
    free(wpath);
    return f;
}

static int mkdir_utf8(const char *path) {
    wchar_t *wpath = utf8_to_wide(path);
    if (!wpath) return -1;
    int r = _wmkdir(wpath);
    free(wpath);
    return r;
}

static int remove_utf8(const char *path) {
    wchar_t *wpath = utf8_to_wide(path);
    if (!wpath) return -1;
    int r = _wremove(wpath);
    free(wpath);
    return r;
}

/* Atomically replace dst with src (both UTF-8). */
static bool replace_file_utf8(const char *src, const char *dst) {
    wchar_t *wsrc = utf8_to_wide(src);
    wchar_t *wdst = utf8_to_wide(dst);
    bool ok = false;
    if (wsrc && wdst)
        ok = MoveFileExW(wsrc, wdst, MOVEFILE_REPLACE_EXISTING) != 0;
    if (!ok)
        fprintf(stderr, "[pzemu] MoveFileExW failed (error %lu)\n", (unsigned long)GetLastError());
    free(wsrc);
    free(wdst);
    return ok;
}

static bool sync_file(FILE *f) {
    return _commit(_fileno(f)) == 0;
}

static void *load_lib(const char *path) {
    wchar_t *wpath = utf8_to_wide(path);
    if (!wpath) return NULL;
    HMODULE h = LoadLibraryW(wpath);
    if (!h)
        fprintf(stderr, "[pzemu] LoadLibraryW failed (error %lu)\n", (unsigned long)GetLastError());
    free(wpath);
    return (void *)h;
}
#else
static FILE *fopen_utf8(const char *path, const char *mode) { return fopen(path, mode); }
static int   mkdir_utf8(const char *path)                   { return mkdir(path, 0755); }
static int   remove_utf8(const char *path)                  { return remove(path); }
static bool  replace_file_utf8(const char *src, const char *dst) {
    if (rename(src, dst) != 0) {
        fprintf(stderr, "[pzemu] rename failed: %s\n", strerror(errno));
        return false;
    }
    return true;
}
static bool  sync_file(FILE *f)                             { return fsync(fileno(f)) == 0; }
static void *load_lib(const char *path) {
    void *h = dlopen(path, RTLD_LAZY);
    if (!h) fprintf(stderr, "[pzemu] dlopen: %s\n", dlerror());
    return h;
}
#endif

/* ---------- global state ---------- */

static void *g_core_handle = NULL;
static FILE *g_frame_out   = NULL;

/* pixel format — default is 0RGB1555 per libretro spec */
static enum retro_pixel_format g_pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;

/* button state array indexed by RETRO_DEVICE_ID_JOYPAD_* (0–15) */
static int16_t g_buttons[16] = {0};

/* analog stick state — 4 axes (leftX, leftY, rightX, rightY) in libretro int16 range */
static int16_t g_analog[4] = {0};

/* frame dimensions (set from CLI, may be updated by SET_GEOMETRY) */
static unsigned g_frame_width  = 0;
static unsigned g_frame_height = 0;

/* RGBA conversion buffer */
static uint8_t *g_rgba_buf      = NULL;
static size_t   g_rgba_buf_size = 0;

/* SDL2 audio */
static SDL_AudioDeviceID g_audio_dev = 0;

/* master volume: 0..255 linear gain numerator (gain = g_volume / 255). 255 = unity. */
static int g_volume = 255;

/* scratch buffer for gain-scaled audio batches */
static int16_t *g_audio_scratch        = NULL;
static size_t   g_audio_scratch_frames = 0;

/* directories */
static const char *g_system_dir = ".";
static const char *g_save_dir   = ".";

/* libretro controller type for port 0 — set from CLI arg 7, default = digital JOYPAD.
 * Different cores expect different values. PSX/PSP/N64 use core-specific subclass IDs. */
static unsigned g_port_device = RETRO_DEVICE_JOYPAD;

/* shutdown flag — set by QUIT, stdin EOF, frame-pipe failure, signals, RETRO_ENVIRONMENT_SHUTDOWN.
 * volatile: written from the signal handler. */
static volatile sig_atomic_t g_shutdown = 0;

/* stdin has reached EOF / broken — stop polling it */
static bool g_stdin_closed = false;

/* core options */
#define MAX_VARS 256
static struct { char *key; char *value; } g_vars[MAX_VARS];
static int g_vars_count = 0;

/* ---------- resolved core symbols ---------- */

static void     (*p_retro_init)(void);
static void     (*p_retro_deinit)(void);
static unsigned (*p_retro_api_version)(void);
static void     (*p_retro_get_system_info)(struct retro_system_info *);
static void     (*p_retro_get_system_av_info)(struct retro_system_av_info *);
static void     (*p_retro_set_controller_port_device)(unsigned, unsigned);
static bool     (*p_retro_load_game)(const struct retro_game_info *);
static void     (*p_retro_unload_game)(void);
static void     (*p_retro_run)(void);
static void    *(*p_retro_get_memory_data)(unsigned);
static size_t   (*p_retro_get_memory_size)(unsigned);
static void     (*p_retro_set_environment)(retro_environment_t);
static void     (*p_retro_set_video_refresh)(retro_video_refresh_t);
static void     (*p_retro_set_audio_sample)(retro_audio_sample_t);
static void     (*p_retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
static void     (*p_retro_set_input_poll)(retro_input_poll_t);
static void     (*p_retro_set_input_state)(retro_input_state_t);
static size_t   (*p_retro_serialize_size)(void);
static bool     (*p_retro_serialize)(void *, size_t);
static bool     (*p_retro_unserialize)(const void *, size_t);

/* ---------- meta-command IDs (keycode >= 16, not sent to core) ---------- */
#define META_SAVE_STATE  16
#define META_LOAD_STATE  17
#define META_PAUSE       18   /* legacy toggle */
#define META_PAUSE_ON    19
#define META_PAUSE_OFF   20
#define META_QUIT        21

/* analog axis events (wire keycodes 64..67, value packed in `pressed` byte) */
#define AXIS_BASE      64
#define AXIS_LEFT_X     0
#define AXIS_LEFT_Y     1
#define AXIS_RIGHT_X    2
#define AXIS_RIGHT_Y    3

/* volume event (wire keycode 68, gain packed in `pressed` byte) */
#define META_VOLUME    68

static bool g_paused = false;

/* forward declarations */
static void do_save_state(void);
static void do_load_state(void);

/* ---------- quit / pause control ---------- */

static void request_quit(const char *why) {
    if (g_shutdown) return;
    g_shutdown = 1;
    fprintf(stderr, "[pzemu] Quit requested: %s\n", why);
}

static void set_paused(bool paused, const char *why) {
    if (g_paused == paused) return;
    g_paused = paused;
    if (g_audio_dev)
        SDL_PauseAudioDevice(g_audio_dev, paused ? 1 : 0);
    fprintf(stderr, "[pzemu] %s (%s)\n", paused ? "Paused" : "Resumed", why);
}

static void set_volume(int vol) {
    if (vol < 0) vol = 0;
    if (vol > 255) vol = 255;
    if (vol == g_volume) return;
    g_volume = vol;
    fprintf(stderr, "[pzemu] Volume %d/255\n", g_volume);
}

/* ---------- environment callback ---------- */

static void RETRO_CALLCONV core_log(enum retro_log_level level, const char *fmt, ...) {
    (void)level;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static bool RETRO_CALLCONV environment_cb(unsigned cmd, void *data) {
    unsigned base_cmd = cmd & 0xFFFF; /* strip RETRO_ENVIRONMENT_EXPERIMENTAL */

    switch (base_cmd) {

    case 3: /* RETRO_ENVIRONMENT_GET_CAN_DUPE */
        if (data) *(bool *)data = true;
        return true;

    case 7: /* RETRO_ENVIRONMENT_SHUTDOWN */
        request_quit("core requested shutdown");
        return true;

    case 8: /* RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL */
        return true;

    case 9: /* RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY */
        if (data) *(const char **)data = g_system_dir;
        return true;

    case 10: { /* RETRO_ENVIRONMENT_SET_PIXEL_FORMAT */
        if (data) g_pixel_format = *(const enum retro_pixel_format *)data;
        return true;
    }

    case 11: /* RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS */
        return true;

    case 15: { /* RETRO_ENVIRONMENT_GET_VARIABLE */
        if (!data) return true;
        struct retro_variable *var = (struct retro_variable *)data;
        var->value = NULL;
        for (int i = 0; i < g_vars_count; i++) {
            if (strcmp(g_vars[i].key, var->key) == 0) {
                var->value = g_vars[i].value;
                return true;
            }
        }
        return true; /* return true even if not found — value stays NULL */
    }

    case 16: { /* RETRO_ENVIRONMENT_SET_VARIABLES */
        if (!data) return true;
        const struct retro_variable *var = (const struct retro_variable *)data;
        /* free old vars */
        for (int i = 0; i < g_vars_count; i++) {
            free(g_vars[i].key);
            free(g_vars[i].value);
        }
        g_vars_count = 0;
        for (; var->key; var++) {
            if (g_vars_count >= MAX_VARS) break;
            g_vars[g_vars_count].key = strdup(var->key);
            /* parse default: skip "Description; ", take up to first "|" */
            const char *start = strchr(var->value, ';');
            if (start) {
                start += 2; /* skip "; " */
                const char *end = strchr(start, '|');
                if (end)
                    g_vars[g_vars_count].value = strndup(start, (size_t)(end - start));
                else
                    g_vars[g_vars_count].value = strdup(start);
            } else {
                g_vars[g_vars_count].value = strdup("");
            }
            g_vars_count++;
        }
        return true;
    }

    case 17: /* RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE */
        if (data) *(bool *)data = false;
        return true;

    case 18: /* RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME */
        return true;

    case 27: { /* RETRO_ENVIRONMENT_GET_LOG_INTERFACE */
        if (!data) return false;
        struct retro_log_callback *cb = (struct retro_log_callback *)data;
        cb->log = core_log;
        return true;
    }

    case 31: /* RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY */
        if (data) *(const char **)data = g_save_dir;
        return true;

    case 37: /* RETRO_ENVIRONMENT_SET_GEOMETRY */
        /* Acknowledge but don't change output dimensions — they must match
         * the Java ring buffer size set at launch. The video_refresh_cb
         * centers/pads smaller frames within the fixed output dimensions. */
        return true;

    case 51: /* RETRO_ENVIRONMENT_GET_INPUT_BITMASKS */
        if (data) *(bool *)data = true;
        return true;

    default:
        return false;
    }
}

/* ---------- video callback ---------- */

static void RETRO_CALLCONV video_refresh_cb(const void *data,
                                             unsigned width, unsigned height,
                                             size_t pitch)
{
    if (!data) return; /* dupe frame — GET_CAN_DUPE was true */
    if (g_shutdown) return; /* frame pipe already dead or quitting — don't block in fwrite */

    size_t needed = (size_t)g_frame_width * g_frame_height * 4;
    if (needed > g_rgba_buf_size) {
        free(g_rgba_buf);
        g_rgba_buf = (uint8_t *)malloc(needed);
        if (!g_rgba_buf) exit(1);
        g_rgba_buf_size = needed;
    }

    /* Zero-fill buffer first — handles padding when core frame is smaller
     * than output dimensions (e.g. Genesis starts 256x192, output is 320x224) */
    memset(g_rgba_buf, 0, needed);

    /* Center the core's frame within the output dimensions */
    unsigned off_x = (width < g_frame_width) ? (g_frame_width - width) / 2 : 0;
    unsigned off_y = (height < g_frame_height) ? (g_frame_height - height) / 2 : 0;
    unsigned copy_w = (width < g_frame_width) ? width : g_frame_width;
    unsigned copy_h = (height < g_frame_height) ? height : g_frame_height;

    /* convert pixel data row-by-row, respecting pitch (bytes per row, NOT width*bpp) */
    for (unsigned y = 0; y < copy_h; y++) {
        const uint8_t *src_row = (const uint8_t *)data + y * pitch;
        uint8_t *dst_row = g_rgba_buf + (y + off_y) * g_frame_width * 4 + off_x * 4;
        unsigned w = copy_w;

        switch (g_pixel_format) {
        case RETRO_PIXEL_FORMAT_XRGB8888:
            for (unsigned x = 0; x < w; x++) {
                uint32_t p = ((const uint32_t *)src_row)[x];
                dst_row[x*4+0] = (uint8_t)((p >> 16) & 0xFF); /* R */
                dst_row[x*4+1] = (uint8_t)((p >>  8) & 0xFF); /* G */
                dst_row[x*4+2] = (uint8_t)(p & 0xFF);          /* B */
                dst_row[x*4+3] = 0xFF;                         /* A */
            }
            break;

        case RETRO_PIXEL_FORMAT_RGB565:
            for (unsigned x = 0; x < w; x++) {
                uint16_t p = ((const uint16_t *)src_row)[x];
                dst_row[x*4+0] = (uint8_t)((p >> 8) & 0xF8); /* R */
                dst_row[x*4+1] = (uint8_t)((p >> 3) & 0xFC); /* G */
                dst_row[x*4+2] = (uint8_t)((p << 3) & 0xF8); /* B */
                dst_row[x*4+3] = 0xFF;                        /* A */
            }
            break;

        case RETRO_PIXEL_FORMAT_0RGB1555:
            for (unsigned x = 0; x < w; x++) {
                uint16_t p = ((const uint16_t *)src_row)[x];
                dst_row[x*4+0] = (uint8_t)((p >> 7) & 0xF8); /* R */
                dst_row[x*4+1] = (uint8_t)((p >> 2) & 0xF8); /* G */
                dst_row[x*4+2] = (uint8_t)((p << 3) & 0xF8); /* B */
                dst_row[x*4+3] = 0xFF;                        /* A */
            }
            break;

        default:
            break;
        }
    }

    size_t written = fwrite(g_rgba_buf, 1, needed, g_frame_out);
    if (written != needed || fflush(g_frame_out) != 0) {
        /* pipe closed (or write interrupted by SIGTERM) — exit cleanly so SRAM is saved */
        request_quit("frame pipe write failed");
        return;
    }
}

/* ---------- input handling ---------- */

static void handle_key_event(uint8_t pressed, uint8_t keycode) {
    if (keycode < 16) {
        g_buttons[keycode] = pressed ? 1 : 0;
        return;
    }

    /* analog axis update: keycode 64..67, value packed in `pressed` (128 = center) */
    if (keycode >= AXIS_BASE && keycode <= AXIS_BASE + 3) {
        unsigned axis = keycode - AXIS_BASE;
        int s = (int)pressed - 128;          /* -128..+127 */
        g_analog[axis] = (int16_t)(s * 256); /* -32768..+32512 */
        return;
    }

    /* volume: value byte IS the gain (0 = mute … 255 = unity), not a press flag */
    if (keycode == META_VOLUME) {
        set_volume(pressed);
        return;
    }

    /* meta-commands — trigger on press only */
    if (pressed) {
        switch (keycode) {
        case META_SAVE_STATE: do_save_state(); break;
        case META_LOAD_STATE: do_load_state(); break;
        case META_PAUSE:      set_paused(!g_paused, "toggle"); break;
        case META_PAUSE_ON:   set_paused(true,  "pause on");  break;
        case META_PAUSE_OFF:  set_paused(false, "pause off"); break;
        case META_QUIT:       request_quit("QUIT command"); break;
        default: break;
        }
    }
}

/* stdin reached EOF or the pipe broke: the parent is gone or wants us to stop. */
static void stdin_eof(const char *why) {
    if (g_stdin_closed) return;
    g_stdin_closed = true;
    request_quit(why);
}

/* first byte of a split 2-byte event, or -1 (AVOID.md #3) */
static int s_pending_byte = -1;

#ifdef _WIN32
/* Windows: a background thread blocks in ReadFile() on stdin and feeds a ring
 * buffer that the main thread drains once per frame. This works identically
 * for the anonymous pipes Java creates, named pipes, consoles and Wine, and
 * sees EOF / ERROR_BROKEN_PIPE the moment the parent closes its end.
 * (PeekNamedPipe-based polling only works on real pipe objects and silently
 * ignores input on anything else.) */
#define STDIN_RING 65536
static CRITICAL_SECTION g_stdin_cs;
static uint8_t  g_stdin_ring[STDIN_RING];
static size_t   g_stdin_head  = 0;
static size_t   g_stdin_count = 0;
static volatile LONG g_stdin_thread_eof = 0;

static DWORD WINAPI stdin_thread_main(LPVOID arg) {
    HANDLE h = (HANDLE)arg;
    uint8_t buf[256];
    for (;;) {
        DWORD got = 0;
        BOOL ok = ReadFile(h, buf, sizeof(buf), &got, NULL);
        if (!ok || got == 0) break; /* EOF or broken pipe (ERROR_BROKEN_PIPE) */
        for (DWORD i = 0; i < got; ) {
            EnterCriticalSection(&g_stdin_cs);
            while (i < got && g_stdin_count < STDIN_RING) {
                g_stdin_ring[(g_stdin_head + g_stdin_count) % STDIN_RING] = buf[i++];
                g_stdin_count++;
            }
            LeaveCriticalSection(&g_stdin_cs);
            if (i < got) Sleep(1); /* ring full — back-pressure, never drop a byte */
        }
    }
    InterlockedExchange(&g_stdin_thread_eof, 1);
    return 0;
}

static void start_stdin_thread(void) {
    InitializeCriticalSection(&g_stdin_cs);
    HANDLE h = GetStdHandle(STD_INPUT_HANDLE);
    if (h == NULL || h == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "[pzemu] No stdin handle — input and EOF detection disabled\n");
        return;
    }
    HANDLE t = CreateThread(NULL, 0, stdin_thread_main, h, 0, NULL);
    if (!t)
        fprintf(stderr, "[pzemu] Failed to start stdin reader thread (error %lu)\n",
                (unsigned long)GetLastError());
    else
        CloseHandle(t); /* detached; dies with the process */
}

static void poll_stdin_keys(void) {
    if (g_stdin_closed) return;

    static uint8_t local[STDIN_RING];
    size_t n = 0;
    EnterCriticalSection(&g_stdin_cs);
    while (g_stdin_count > 0) {
        local[n++] = g_stdin_ring[g_stdin_head];
        g_stdin_head = (g_stdin_head + 1) % STDIN_RING;
        g_stdin_count--;
    }
    LeaveCriticalSection(&g_stdin_cs);

    for (size_t i = 0; i < n; i++) {
        if (s_pending_byte >= 0) {
            handle_key_event((uint8_t)s_pending_byte, local[i]); /* [pressed, keycode] */
            s_pending_byte = -1;
        } else {
            s_pending_byte = local[i];
        }
    }

    /* the thread sets the flag only after pushing its last bytes, so everything
     * the parent sent before closing has been handled by now */
    if (g_stdin_thread_eof) stdin_eof("stdin EOF");
}
#else
static void poll_stdin_keys(void) {
    if (g_stdin_closed) return;
    uint8_t buf[2];
    for (;;) {
        if (s_pending_byte >= 0) {
            buf[0] = (uint8_t)s_pending_byte;
            ssize_t n = read(STDIN_FILENO, &buf[1], 1);
            if (n == 1) {
                s_pending_byte = -1;
                handle_key_event(buf[0], buf[1]); /* [pressed, keycode] */
                continue;
            }
            if (n == 0) { stdin_eof("stdin EOF"); return; }
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return; /* keep pending byte */
            stdin_eof("stdin read error");
            return;
        }
        ssize_t n = read(STDIN_FILENO, buf, 2);
        if (n == 2) { handle_key_event(buf[0], buf[1]); continue; }
        if (n == 1) { s_pending_byte = buf[0]; continue; } /* try for the 2nd byte */
        if (n == 0) { stdin_eof("stdin EOF"); return; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        stdin_eof("stdin read error");
        return;
    }
}
#endif

static void RETRO_CALLCONV input_poll_cb(void) {
    poll_stdin_keys();
}

static int16_t RETRO_CALLCONV input_state_cb(unsigned port, unsigned device,
                                              unsigned index, unsigned id)
{
    if (port != 0) return 0;

    unsigned dev = device & RETRO_DEVICE_MASK;

    /* digital joypad polls — used by both RETRO_DEVICE_JOYPAD and RETRO_DEVICE_ANALOG cores */
    if (dev == RETRO_DEVICE_JOYPAD && index == 0) {
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
            int16_t mask = 0;
            for (int i = 0; i < 16; i++)
                if (g_buttons[i]) mask |= (1 << i);
            return mask;
        }
        if (id < 16) return g_buttons[id];
        return 0;
    }

    /* analog axis polls */
    if (dev == RETRO_DEVICE_ANALOG) {
        if (index == RETRO_DEVICE_INDEX_ANALOG_LEFT) {
            if (id == RETRO_DEVICE_ID_ANALOG_X) return g_analog[AXIS_LEFT_X];
            if (id == RETRO_DEVICE_ID_ANALOG_Y) return g_analog[AXIS_LEFT_Y];
        } else if (index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
            if (id == RETRO_DEVICE_ID_ANALOG_X) return g_analog[AXIS_RIGHT_X];
            if (id == RETRO_DEVICE_ID_ANALOG_Y) return g_analog[AXIS_RIGHT_Y];
        } else if (index == RETRO_DEVICE_INDEX_ANALOG_BUTTON) {
            /* analog-button pressure poll (e.g. shoulder triggers as analog) —
             * we have no analog source for these, so report digital state scaled */
            if (id < 16 && g_buttons[id]) return 0x7FFF;
            return 0;
        }
    }

    return 0;
}

/* ---------- audio callbacks ---------- */

static inline int16_t scale_sample(int16_t s) {
    int32_t v = ((int32_t)s * g_volume) / 255;
    if (v >  32767) v =  32767;
    if (v < -32768) v = -32768;
    return (int16_t)v;
}

static void RETRO_CALLCONV audio_sample_cb(int16_t left, int16_t right) {
    if (!g_audio_dev) return;
    int16_t buf[2] = { scale_sample(left), scale_sample(right) };
    SDL_QueueAudio(g_audio_dev, buf, 4);
}

static size_t RETRO_CALLCONV audio_batch_cb(const int16_t *data, size_t frames) {
    if (!g_audio_dev) return frames;

    /* Just queue audio — frame pacing is handled by the main loop timer.
     * Safety valve: if queue grows beyond ~8 video frames, clear it to
     * prevent unbounded memory growth (shouldn't happen with proper timing). */
    Uint32 batch_bytes = (Uint32)(frames * 2 * sizeof(int16_t));
    if (SDL_GetQueuedAudioSize(g_audio_dev) > batch_bytes * 8)
        SDL_ClearQueuedAudio(g_audio_dev);

    if (g_volume == 255) {
        SDL_QueueAudio(g_audio_dev, data, batch_bytes);
        return frames;
    }

    /* gain != unity: scale into a scratch buffer (muted = queue silence so the
     * device keeps consuming at the same rate — never stalls or skips) */
    if (frames > g_audio_scratch_frames) {
        int16_t *nb = (int16_t *)realloc(g_audio_scratch, frames * 2 * sizeof(int16_t));
        if (!nb) return frames; /* drop this batch rather than crash */
        g_audio_scratch = nb;
        g_audio_scratch_frames = frames;
    }
    if (g_volume == 0) {
        memset(g_audio_scratch, 0, batch_bytes);
    } else {
        size_t samples = frames * 2;
        for (size_t i = 0; i < samples; i++)
            g_audio_scratch[i] = scale_sample(data[i]);
    }
    SDL_QueueAudio(g_audio_dev, g_audio_scratch, batch_bytes);
    return frames;
}

/* ---------- atomic file writes ---------- */

static void ensure_directory(const char *path) {
    /* Create directory and parents (best-effort, ignore errors) */
    char tmp[PATH_BUF];
    strncpy(tmp, path, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/' || *p == '\\') {
            char saved = *p;
            *p = '\0';
            mkdir_utf8(tmp);
            *p = saved;
        }
    }
    mkdir_utf8(tmp);
}

/* Write `size` bytes to `path` atomically: <path>.tmp in the same directory,
 * fsync, then rename over the destination. On any failure the previous file
 * is left untouched and the temp file is removed. */
static bool write_file_atomic(const char *path, const void *data, size_t size) {
    char tmp[PATH_BUF + 8];
    int n = snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    if (n < 0 || (size_t)n >= sizeof(tmp)) {
        fprintf(stderr, "[pzemu] Path too long for temp file: %s\n", path);
        return false;
    }

    FILE *f = fopen_utf8(tmp, "wb");
    if (!f) {
        fprintf(stderr, "[pzemu] Failed to open %s for writing: %s\n", tmp, strerror(errno));
        return false;
    }

    bool ok = fwrite(data, 1, size, f) == size;
    if (ok && fflush(f) != 0) ok = false;
    if (ok && !sync_file(f)) ok = false;
    if (fclose(f) != 0) ok = false;

    if (!ok) {
        fprintf(stderr, "[pzemu] Failed to write %s: %s\n", tmp, strerror(errno));
        remove_utf8(tmp);
        return false;
    }
    if (!replace_file_utf8(tmp, path)) {
        fprintf(stderr, "[pzemu] Failed to replace %s\n", path);
        remove_utf8(tmp);
        return false;
    }
    return true;
}

/* <save_dir>/<rom basename without extension><ext> */
static void build_save_path(char *out, size_t out_size,
                            const char *rom_path, const char *save_dir, const char *ext)
{
    const char *slash = strrchr(rom_path, '/');
#ifdef _WIN32
    const char *bslash = strrchr(rom_path, '\\');
    if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
    const char *basename = slash ? slash + 1 : rom_path;

    char name[1024];
    strncpy(name, basename, sizeof(name) - 1);
    name[sizeof(name) - 1] = '\0';

    char *dot = strrchr(name, '.');
    if (dot) *dot = '\0';

    snprintf(out, out_size, "%s/%s%s", save_dir, name, ext);
}

/* ---------- SRAM persistence ---------- */

static char g_srm_path[PATH_BUF] = {0};

/* copy of the SRAM contents as last written to (or loaded from) disk */
static uint8_t *g_sram_shadow      = NULL;
static size_t   g_sram_shadow_size = 0;

static void sram_shadow_sync(const void *sram, size_t size) {
    if (size != g_sram_shadow_size) {
        uint8_t *nb = (uint8_t *)realloc(g_sram_shadow, size);
        if (!nb) { free(g_sram_shadow); g_sram_shadow = NULL; g_sram_shadow_size = 0; return; }
        g_sram_shadow = nb;
        g_sram_shadow_size = size;
    }
    memcpy(g_sram_shadow, sram, size);
}

static bool sram_changed(const void *sram, size_t size) {
    if (!g_sram_shadow || g_sram_shadow_size != size) return true;
    return memcmp(g_sram_shadow, sram, size) != 0;
}

static bool sram_write(const void *sram, size_t size, const char *why) {
    ensure_directory(g_save_dir);
    if (!write_file_atomic(g_srm_path, sram, size)) {
        fprintf(stderr, "[pzemu] Failed to save SRAM to %s (%s)\n", g_srm_path, why);
        return false;
    }
    sram_shadow_sync(sram, size);
    fprintf(stderr, "[pzemu] Saved SRAM to %s (%zu bytes, %s)\n", g_srm_path, size, why);
    return true;
}

static void load_sram(void) {
    void *sram = p_retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t sram_size = p_retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!sram || sram_size == 0 || g_srm_path[0] == '\0') return;

    FILE *f = fopen_utf8(g_srm_path, "rb");
    if (f) {
        size_t n = fread(sram, 1, sram_size, f);
        fclose(f);
        fprintf(stderr, "[pzemu] Loaded SRAM from %s (%zu bytes)\n", g_srm_path, n);
    }
    /* baseline for change detection — whatever the core holds now (file or defaults) */
    sram_shadow_sync(sram, sram_size);
}

/* Periodic flush: write SRAM only if it differs from what is on disk. Called
 * from the main loop between retro_run() calls — never mid-frame. */
static void flush_sram_if_changed(void) {
    void *sram = p_retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t sram_size = p_retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!sram || sram_size == 0 || g_srm_path[0] == '\0') return;
    if (!sram_changed(sram, sram_size)) return;
    sram_write(sram, sram_size, "periodic flush");
}

/* Final save — runs exactly once on every exit path (main loop end, atexit
 * after die()/exit(), signal-driven shutdown). */
static void save_sram(void) {
    static bool sram_saved = false;
    if (sram_saved) return;
    sram_saved = true;

    void *sram = p_retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t sram_size = p_retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!sram || sram_size == 0 || g_srm_path[0] == '\0') return;

    sram_write(sram, sram_size, "exit");
}

/* ---------- save state persistence ---------- */

static char g_state_path[PATH_BUF] = {0};

static void do_save_state(void) {
    size_t sz = p_retro_serialize_size();
    if (sz == 0) {
        fprintf(stderr, "[pzemu] Core does not support save states\n");
        return;
    }

    void *buf = malloc(sz);
    if (!buf) return;

    if (p_retro_serialize(buf, sz)) {
        ensure_directory(g_save_dir);
        if (write_file_atomic(g_state_path, buf, sz))
            fprintf(stderr, "[pzemu] Saved state to %s (%zu bytes)\n", g_state_path, sz);
        else
            fprintf(stderr, "[pzemu] Failed to save state to %s\n", g_state_path);
    } else {
        fprintf(stderr, "[pzemu] retro_serialize() failed\n");
    }
    free(buf);
}

static void do_load_state(void) {
    FILE *f = fopen_utf8(g_state_path, "rb");
    if (!f) {
        fprintf(stderr, "[pzemu] No save state found: %s\n", g_state_path);
        return;
    }

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return; }

    void *buf = malloc((size_t)sz);
    if (!buf) { fclose(f); return; }

    if (fread(buf, 1, (size_t)sz, f) == (size_t)sz) {
        if (p_retro_unserialize(buf, (size_t)sz)) {
            fprintf(stderr, "[pzemu] Loaded state from %s (%ld bytes)\n", g_state_path, sz);
        } else {
            fprintf(stderr, "[pzemu] retro_unserialize() failed\n");
        }
    }
    fclose(f);
    free(buf);
}

/* ---------- signals ---------- */

static void signal_handler(int sig) {
    (void)sig;
    g_shutdown = 1; /* let main loop exit cleanly so SRAM is saved (no stdio in a handler) */
}

static void install_signal_handlers(void) {
#ifdef _WIN32
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
#else
    /* No SA_RESTART: a SIGTERM while blocked writing a frame makes fwrite fail
     * with EINTR instead of restarting, so the loop can exit promptly. */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN); /* don't die on pipe close — handle in fwrite */
#endif
}

/* ---------- time ---------- */

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---------- main ---------- */

int main(int argc, char *argv[]) {
#ifdef _WIN32
    /* #25: re-derive argv from the wide command line as UTF-8 so paths with
     * characters outside the ANSI codepage survive. (SDL2main already does
     * this; doing it ourselves keeps the guarantee independent of how the
     * binary is linked.) */
    {
        int wargc = 0;
        LPWSTR *wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
        if (wargv && wargc > 0) {
            char **u8 = (char **)calloc((size_t)wargc + 1, sizeof(char *));
            if (u8) {
                for (int i = 0; i < wargc; i++) {
                    u8[i] = wide_to_utf8(wargv[i]);
                    if (!u8[i]) u8[i] = (i < argc) ? argv[i] : (char *)"";
                }
                argc = wargc;
                argv = u8;
            }
            /* wargv intentionally not freed — argv strings don't reference it,
             * but the process is short-lived either way. */
        }
    }
#endif

    if (argc < 5) {
        fprintf(stderr, "Usage: pzemu-bridge <core> <rom> <width> <height> [sys_dir] [save_dir] [port_device]\n");
        return 1;
    }

    const char *core_path = argv[1];
    const char *rom_path  = argv[2];
    g_frame_width  = (unsigned)atoi(argv[3]);
    g_frame_height = (unsigned)atoi(argv[4]);
    if (argc > 5) g_system_dir = argv[5];
    if (argc > 6) g_save_dir   = argv[6];
    if (argc > 7) g_port_device = (unsigned)atoi(argv[7]);

    if (g_frame_width == 0 || g_frame_height == 0)
        die("Invalid frame dimensions: %ux%u", g_frame_width, g_frame_height);

    /* --- STEP 1: Binary mode on Windows (AVOID.md #6) --- */
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stdin),  _O_BINARY);
#endif

    /* --- STEP 2: Save original stdout, redirect stdout→stderr (AVOID.md #1) ---
     * MUST happen BEFORE dlopen — core .so may printf in static constructors. */
#ifdef _WIN32
    int frame_fd = _dup(_fileno(stdout));
    _setmode(frame_fd, _O_BINARY);
    _dup2(_fileno(stderr), _fileno(stdout));
    g_frame_out = _fdopen(frame_fd, "wb");
#else
    int frame_fd = dup(STDOUT_FILENO);
    dup2(STDERR_FILENO, STDOUT_FILENO);
    g_frame_out = fdopen(frame_fd, "wb");
#endif
    if (!g_frame_out)
        die("Failed to create frame output stream");

    /* --- STEP 3: stdin: non-blocking on Linux, reader thread on Windows (AVOID.md #3) --- */
#ifdef _WIN32
    start_stdin_thread();
#else
    {
        int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
        if (flags != -1)
            fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
    }
#endif

    /* --- STEP 4: Increase pipe buffer for smoother frame delivery (AVOID.md #18) --- */
#ifdef F_SETPIPE_SZ
    fcntl(fileno(g_frame_out), F_SETPIPE_SZ, 1048576); /* 1MB, ignore failure */
#endif

    /* --- STEP 5: Load libretro core --- */
    fprintf(stderr, "[pzemu] Loading core: %s\n", core_path);
    g_core_handle = load_lib(core_path);
    if (!g_core_handle)
        die("Failed to load core: %s", core_path);

    /* Resolve all retro_* symbols */
    load_sym(p_retro_init,                        retro_init);
    load_sym(p_retro_deinit,                      retro_deinit);
    load_sym(p_retro_api_version,                 retro_api_version);
    load_sym(p_retro_get_system_info,             retro_get_system_info);
    load_sym(p_retro_get_system_av_info,          retro_get_system_av_info);
    load_sym(p_retro_set_controller_port_device,  retro_set_controller_port_device);
    load_sym(p_retro_load_game,                   retro_load_game);
    load_sym(p_retro_unload_game,                 retro_unload_game);
    load_sym(p_retro_run,                         retro_run);
    load_sym(p_retro_get_memory_data,             retro_get_memory_data);
    load_sym(p_retro_get_memory_size,             retro_get_memory_size);
    load_sym(p_retro_set_environment,             retro_set_environment);
    load_sym(p_retro_set_video_refresh,           retro_set_video_refresh);
    load_sym(p_retro_set_audio_sample,            retro_set_audio_sample);
    load_sym(p_retro_set_audio_sample_batch,      retro_set_audio_sample_batch);
    load_sym(p_retro_set_input_poll,              retro_set_input_poll);
    load_sym(p_retro_set_input_state,             retro_set_input_state);
    load_sym(p_retro_serialize_size,              retro_serialize_size);
    load_sym(p_retro_serialize,                   retro_serialize);
    load_sym(p_retro_unserialize,                 retro_unserialize);

    /* Verify API version */
    unsigned api_ver = p_retro_api_version();
    if (api_ver != RETRO_API_VERSION)
        die("Core API version mismatch: got %u, expected %u", api_ver, RETRO_API_VERSION);

    /* --- STEP 6: Register callbacks — retro_set_environment BEFORE retro_init --- */
    p_retro_set_environment(environment_cb);
    p_retro_set_video_refresh(video_refresh_cb);
    p_retro_set_input_poll(input_poll_cb);
    p_retro_set_input_state(input_state_cb);
    p_retro_set_audio_sample(audio_sample_cb);
    p_retro_set_audio_sample_batch(audio_batch_cb);

    /* --- STEP 7: Initialize core --- */
    p_retro_init();

    /* --- STEP 8: Get system info and load ROM --- */
    struct retro_system_info sys_info = {0};
    p_retro_get_system_info(&sys_info);
    fprintf(stderr, "[pzemu] Core: %s %s (need_fullpath=%d)\n",
            sys_info.library_name ? sys_info.library_name : "?",
            sys_info.library_version ? sys_info.library_version : "?",
            (int)sys_info.need_fullpath);

    struct retro_game_info game_info = {0};
    game_info.path = rom_path; /* UTF-8, as the libretro API requires */
    game_info.meta = NULL;

    void *rom_data = NULL;
    if (!sys_info.need_fullpath) {
        /* read ROM into memory */
        FILE *f = fopen_utf8(rom_path, "rb");
        if (!f) die("Failed to open ROM: %s", rom_path);
        fseek(f, 0, SEEK_END);
        long size = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (size <= 0) die("Empty or unreadable ROM: %s", rom_path);
        rom_data = malloc((size_t)size);
        if (!rom_data) die("Failed to allocate %ld bytes for ROM", size);
        if (fread(rom_data, 1, (size_t)size, f) != (size_t)size)
            die("Failed to read ROM: %s", rom_path);
        fclose(f);
        game_info.data = rom_data;
        game_info.size = (size_t)size;
    }

    if (!p_retro_load_game(&game_info))
        die("retro_load_game() failed for: %s", rom_path);

    free(rom_data); /* safe to free — core copies what it needs */
    rom_data = NULL;

    /* --- STEP 9: Get AV info --- */
    struct retro_system_av_info av_info = {0};
    p_retro_get_system_av_info(&av_info);

    /* CLI width/height are the output frame size (must match Java ring buffer).
     * Core may report different base geometry (e.g. Genesis starts 256x192 but
     * switches to 320x224). We KEEP CLI dimensions and pad/center if the core's
     * frame is smaller. SET_GEOMETRY callbacks are noted but don't change output. */
    fprintf(stderr, "[pzemu] Core geometry: %ux%u (max %ux%u), Output: %ux%u, FPS: %.2f, Sample rate: %.0f\n",
            av_info.geometry.base_width, av_info.geometry.base_height,
            av_info.geometry.max_width, av_info.geometry.max_height,
            g_frame_width, g_frame_height,
            av_info.timing.fps, av_info.timing.sample_rate);

    /* --- STEP 10: Set controller --- */
    p_retro_set_controller_port_device(0, g_port_device);
    fprintf(stderr, "[pzemu] Controller port device: %u\n", g_port_device);

    /* --- STEP 11: Load SRAM + register exit/signal handlers --- */
    build_save_path(g_srm_path,   sizeof(g_srm_path),   rom_path, g_save_dir, ".srm");
    build_save_path(g_state_path, sizeof(g_state_path), rom_path, g_save_dir, ".state");
    load_sram();

    /* Save SRAM on any exit path (signal, pipe close, QUIT, die() after this point) */
    atexit(save_sram);
    install_signal_handlers();

    /* --- STEP 12: Initialize SDL2 audio (audio-only, no window) --- */
    if (SDL_Init(SDL_INIT_AUDIO) < 0) {
        fprintf(stderr, "[pzemu] SDL audio init failed: %s\n", SDL_GetError());
    } else {
        SDL_AudioSpec desired;
        SDL_zero(desired);
        desired.format   = AUDIO_S16SYS;
        desired.freq     = (int)av_info.timing.sample_rate;
        desired.channels = 2;
        desired.samples  = 2048;

        g_audio_dev = SDL_OpenAudioDevice(NULL, 0, &desired, NULL, 0);
        if (!g_audio_dev) {
            fprintf(stderr, "[pzemu] Failed to open audio: %s\n", SDL_GetError());
        } else {
            SDL_PauseAudioDevice(g_audio_dev, 0); /* start playing */
            fprintf(stderr, "[pzemu] Audio: %d Hz stereo\n", desired.freq);
        }
    }

    /* --- STEP 13: Main emulation loop with precise frame timing --- */
    fprintf(stderr, "[pzemu] Running emulation...\n");
    double frame_ns = 1000000000.0 / av_info.timing.fps; /* ~16.6ms for NTSC */
    struct timespec next_frame;
    clock_gettime(CLOCK_MONOTONIC, &next_frame);
    int64_t next_sram_flush = now_ms() + SRAM_FLUSH_INTERVAL_MS;

    while (!g_shutdown) {
        if (g_paused) {
            poll_stdin_keys(); /* QUIT / PAUSE OFF / EOF still processed while paused */
            SDL_Delay(16);
            clock_gettime(CLOCK_MONOTONIC, &next_frame); /* reset on unpause */
        } else {
            p_retro_run();
            if (g_shutdown) break;

            /* Advance target time by one frame (accumulator-style, no drift) */
            next_frame.tv_nsec += (long)frame_ns;
            while (next_frame.tv_nsec >= 1000000000L) {
                next_frame.tv_nsec -= 1000000000L;
                next_frame.tv_sec++;
            }

            /* Sleep until next frame target */
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long wait_ns = (next_frame.tv_sec - now.tv_sec) * 1000000000L
                         + (next_frame.tv_nsec - now.tv_nsec);
            if (wait_ns > 0) {
                struct timespec ts = { .tv_sec = 0, .tv_nsec = wait_ns };
                nanosleep(&ts, NULL);
            } else if (wait_ns < -(long)(frame_ns * 3)) {
                /* Fallen too far behind (>3 frames) — reset to prevent catch-up burst */
                clock_gettime(CLOCK_MONOTONIC, &next_frame);
            }
        }

        /* Periodic SRAM flush — between frames only, and only when it changed */
        if (now_ms() >= next_sram_flush) {
            flush_sram_if_changed();
            next_sram_flush = now_ms() + SRAM_FLUSH_INTERVAL_MS;
        }
    }

    /* --- STEP 14: Cleanup --- */
    fprintf(stderr, "[pzemu] Shutting down...\n");
    save_sram();

    p_retro_unload_game();
    p_retro_deinit();
    close_lib(g_core_handle);

    if (g_audio_dev) {
        SDL_CloseAudioDevice(g_audio_dev);
        g_audio_dev = 0;
    }
    SDL_Quit();

    free(g_rgba_buf);
    free(g_audio_scratch);
    free(g_sram_shadow);
    for (int i = 0; i < g_vars_count; i++) {
        free(g_vars[i].key);
        free(g_vars[i].value);
    }

    if (g_frame_out) {
#ifndef _WIN32
        /* never block on a stalled frame pipe while exiting — leftover bytes are useless now */
        int fl = fcntl(fileno(g_frame_out), F_GETFL, 0);
        if (fl != -1) fcntl(fileno(g_frame_out), F_SETFL, fl | O_NONBLOCK);
#endif
        fclose(g_frame_out);
    }

    return 0;
}

/*
 * pzemu-bridge.c — Generic libretro frontend for PZFB game process protocol
 *
 * Loads any libretro core via dlopen, pipes RGBA frames to stdout,
 * reads button events from stdin, handles audio via SDL2.
 *
 * Usage: pzemu-bridge <core_path> <rom_path> <width> <height> [system_dir] [save_dir]
 *
 * Protocol:
 *   stdout → raw RGBA frames (width * height * 4 bytes each), continuous
 *   stdin  ← key events (2 bytes each: [pressed:u8, keycode:u8])
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
#include <io.h>
#include <fcntl.h>
#define load_lib(p)      LoadLibraryA(p)
#define load_func(h, s)  ((void*)GetProcAddress((HMODULE)(h), s))
#define close_lib(h)     FreeLibrary((HMODULE)(h))
#else
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#define load_lib(p)      dlopen(p, RTLD_LAZY)
#define load_func(h, s)  dlsym(h, s)
#define close_lib(h)     dlclose(h)
#endif

#include <SDL.h>

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

/* ---------- global state ---------- */

static void *g_core_handle = NULL;
static FILE *g_frame_out   = NULL;

/* pixel format — default is 0RGB1555 per libretro spec */
static enum retro_pixel_format g_pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;

/* button state array indexed by RETRO_DEVICE_ID_JOYPAD_* (0–15) */
static int16_t g_buttons[16] = {0};

/* frame dimensions (set from CLI, may be updated by SET_GEOMETRY) */
static unsigned g_frame_width  = 0;
static unsigned g_frame_height = 0;

/* RGBA conversion buffer */
static uint8_t *g_rgba_buf      = NULL;
static size_t   g_rgba_buf_size = 0;

/* SDL2 audio */
static SDL_AudioDeviceID g_audio_dev = 0;

/* directories */
static const char *g_system_dir = ".";
static const char *g_save_dir   = ".";

/* shutdown flag — set by RETRO_ENVIRONMENT_SHUTDOWN */
static bool g_shutdown = false;

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
#define META_PAUSE       18

static bool g_paused = false;

/* forward declarations for meta-command handlers */
static void do_save_state(void);
static void do_load_state(void);

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
        g_shutdown = true;
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
    if (written != needed) {
        g_shutdown = true; /* pipe closed — exit cleanly so atexit runs */
        return;
    }
    fflush(g_frame_out);
}

/* ---------- input handling ---------- */

static void handle_key_event(uint8_t pressed, uint8_t keycode) {
    if (keycode < 16) {
        g_buttons[keycode] = pressed ? 1 : 0;
    } else if (pressed) {
        /* meta-commands — trigger on press only */
        switch (keycode) {
        case META_SAVE_STATE: do_save_state(); break;
        case META_LOAD_STATE: do_load_state(); break;
        case META_PAUSE:
            g_paused = !g_paused;
            if (g_audio_dev)
                SDL_PauseAudioDevice(g_audio_dev, g_paused ? 1 : 0);
            fprintf(stderr, "[pzemu] %s\n", g_paused ? "Paused" : "Resumed");
            break;
        default: break;
        }
    }
}

#ifdef _WIN32
static void poll_stdin_keys(void) {
    HANDLE hStdin = GetStdHandle(STD_INPUT_HANDLE);
    DWORD avail = 0;
    while (PeekNamedPipe(hStdin, NULL, 0, NULL, &avail, NULL) && avail >= 2) {
        uint8_t buf[2];
        DWORD bytesRead = 0;
        if (ReadFile(hStdin, buf, 2, &bytesRead, NULL) && bytesRead == 2) {
            handle_key_event(buf[0], buf[1]); /* [pressed, keycode] */
        } else {
            break;
        }
    }
}
#else
static int s_pending_byte = -1;

static void poll_stdin_keys(void) {
    uint8_t buf[2];
    while (1) {
        if (s_pending_byte >= 0) {
            buf[0] = (uint8_t)s_pending_byte;
            s_pending_byte = -1;
            ssize_t n = read(STDIN_FILENO, &buf[1], 1);
            if (n == 1) {
                handle_key_event(buf[0], buf[1]); /* [pressed, keycode] */
                continue;
            } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                s_pending_byte = buf[0]; /* re-buffer */
                break;
            } else {
                break; /* pipe dead */
            }
        }
        ssize_t n = read(STDIN_FILENO, buf, 2);
        if (n == 2) {
            handle_key_event(buf[0], buf[1]);
        } else if (n == 1) {
            s_pending_byte = buf[0];
            break;
        } else {
            break;
        }
    }
}
#endif

static void RETRO_CALLCONV input_poll_cb(void) {
    poll_stdin_keys();
}

static int16_t RETRO_CALLCONV input_state_cb(unsigned port, unsigned device,
                                              unsigned index, unsigned id)
{
    if (port != 0 || (device & 0xFF) != RETRO_DEVICE_JOYPAD || index != 0)
        return 0;

    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
        int16_t mask = 0;
        for (int i = 0; i < 16; i++)
            if (g_buttons[i]) mask |= (1 << i);
        return mask;
    }

    if (id < 16)
        return g_buttons[id];

    return 0;
}

/* ---------- audio callbacks ---------- */

static void RETRO_CALLCONV audio_sample_cb(int16_t left, int16_t right) {
    if (!g_audio_dev) return;
    int16_t buf[2] = { left, right };
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

    SDL_QueueAudio(g_audio_dev, data, batch_bytes);
    return frames;
}

/* ---------- SRAM persistence ---------- */

static char g_srm_path[4096] = {0};

static void build_srm_path(const char *rom_path, const char *save_dir) {
    /* extract ROM basename without extension */
    const char *slash = strrchr(rom_path, '/');
#ifdef _WIN32
    const char *bslash = strrchr(rom_path, '\\');
    if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
    const char *basename = slash ? slash + 1 : rom_path;

    char name[256];
    strncpy(name, basename, sizeof(name) - 1);
    name[sizeof(name) - 1] = '\0';

    char *dot = strrchr(name, '.');
    if (dot) *dot = '\0';

    snprintf(g_srm_path, sizeof(g_srm_path), "%s/%s.srm", save_dir, name);
}

static void load_sram(void) {
    void *sram = p_retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t sram_size = p_retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!sram || sram_size == 0 || g_srm_path[0] == '\0') return;

    FILE *f = fopen(g_srm_path, "rb");
    if (f) {
        size_t n = fread(sram, 1, sram_size, f);
        fclose(f);
        fprintf(stderr, "[pzemu] Loaded SRAM from %s (%zu bytes)\n", g_srm_path, n);
    }
}

static void ensure_directory(const char *path) {
    /* Create directory and parents (best-effort, ignore errors) */
    char tmp[4096];
    strncpy(tmp, path, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/' || *p == '\\') {
            *p = '\0';
#ifdef _WIN32
            _mkdir(tmp);
#else
            mkdir(tmp, 0755);
#endif
            *p = '/';
        }
    }
#ifdef _WIN32
    _mkdir(tmp);
#else
    mkdir(tmp, 0755);
#endif
}

static void save_sram(void) {
    static bool sram_saved = false;
    if (sram_saved) return; /* prevent double-save from signal + atexit */
    sram_saved = true;

    void *sram = p_retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t sram_size = p_retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!sram || sram_size == 0 || g_srm_path[0] == '\0') return;

    /* Ensure the save directory exists */
    ensure_directory(g_save_dir);

    FILE *f = fopen(g_srm_path, "wb");
    if (f) {
        fwrite(sram, 1, sram_size, f);
        fclose(f);
        fprintf(stderr, "[pzemu] Saved SRAM to %s (%zu bytes)\n", g_srm_path, sram_size);
    } else {
        fprintf(stderr, "[pzemu] Failed to save SRAM to %s\n", g_srm_path);
    }
}

/* ---------- save state persistence ---------- */

static char g_state_path[4096] = {0};

static void build_state_path(const char *rom_path, const char *save_dir) {
    const char *slash = strrchr(rom_path, '/');
#ifdef _WIN32
    const char *bslash = strrchr(rom_path, '\\');
    if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
    const char *basename = slash ? slash + 1 : rom_path;

    char name[256];
    strncpy(name, basename, sizeof(name) - 1);
    name[sizeof(name) - 1] = '\0';

    char *dot = strrchr(name, '.');
    if (dot) *dot = '\0';

    snprintf(g_state_path, sizeof(g_state_path), "%s/%s.state", save_dir, name);
}

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
        FILE *f = fopen(g_state_path, "wb");
        if (f) {
            fwrite(buf, 1, sz, f);
            fclose(f);
            fprintf(stderr, "[pzemu] Saved state to %s (%zu bytes)\n", g_state_path, sz);
        } else {
            fprintf(stderr, "[pzemu] Failed to save state to %s\n", g_state_path);
        }
    } else {
        fprintf(stderr, "[pzemu] retro_serialize() failed\n");
    }
    free(buf);
}

static void do_load_state(void) {
    FILE *f = fopen(g_state_path, "rb");
    if (!f) {
        fprintf(stderr, "[pzemu] No save state found: %s\n", g_state_path);
        return;
    }

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);

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

static void signal_handler(int sig) {
    (void)sig;
    g_shutdown = true; /* let main loop exit cleanly so atexit/cleanup runs */
}

/* ---------- main ---------- */

int main(int argc, char *argv[]) {
    if (argc < 5) {
        fprintf(stderr, "Usage: pzemu-bridge <core> <rom> <width> <height> [sys_dir] [save_dir]\n");
        return 1;
    }

    const char *core_path = argv[1];
    const char *rom_path  = argv[2];
    g_frame_width  = (unsigned)atoi(argv[3]);
    g_frame_height = (unsigned)atoi(argv[4]);
    if (argc > 5) g_system_dir = argv[5];
    if (argc > 6) g_save_dir   = argv[6];

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

    /* --- STEP 3: Set stdin non-blocking (Linux) (AVOID.md #3) --- */
#ifndef _WIN32
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
    fprintf(stderr, "[pzemu] Core: %s %s\n",
            sys_info.library_name ? sys_info.library_name : "?",
            sys_info.library_version ? sys_info.library_version : "?");

    struct retro_game_info game_info = {0};
    game_info.path = rom_path;
    game_info.meta = NULL;

    void *rom_data = NULL;
    if (!sys_info.need_fullpath) {
        /* read ROM into memory */
        FILE *f = fopen(rom_path, "rb");
        if (!f) die("Failed to open ROM: %s", rom_path);
        fseek(f, 0, SEEK_END);
        long size = ftell(f);
        fseek(f, 0, SEEK_SET);
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
    p_retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);

    /* --- STEP 11: Load SRAM + register signal handlers --- */
    build_srm_path(rom_path, g_save_dir);
    build_state_path(rom_path, g_save_dir);
    load_sram();

    /* Save SRAM on any exit path (signal, pipe close, clean shutdown) */
    atexit(save_sram);
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN); /* don't die on pipe close — handle in fwrite */
#endif

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

    while (!g_shutdown) {
        if (g_paused) {
            poll_stdin_keys();
            SDL_Delay(16);
            clock_gettime(CLOCK_MONOTONIC, &next_frame); /* reset on unpause */
        } else {
            p_retro_run();

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
    for (int i = 0; i < g_vars_count; i++) {
        free(g_vars[i].key);
        free(g_vars[i].value);
    }

    if (g_frame_out) fclose(g_frame_out);

    return 0;
}

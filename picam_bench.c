// picam_bench.c
// Raspberry Pi camera benchmarking orchestrator in C.
// Orchestrates rpicam-vid/libcamera-vid + ffmpeg (v4l2/native/hw/sw) pipelines,
// shows SDL preview with live overlay (FPS/bitrate/CPU/MEM), robust USB detection.
//
// Build:   gcc -O2 -Wall -pthread -o picam_bench picam_bench.c
// Runtime: requires ffmpeg, rpicam-vid or libcamera-vid, and (optionally) v4l2-ctl
// License: MIT

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/videodev2.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdnoreturn.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_METHOD "h264_sdl_preview"
#define DEFAULT_RESOLUTION_W 1280
#define DEFAULT_RESOLUTION_H 720
#define DEFAULT_FPS 30
#define DEFAULT_BITRATE 4000000
#define DEFAULT_CORNER "top-left"
#define DEFAULT_SOURCE "auto"
#define DEFAULT_ENCODE "auto"

typedef enum
{
    SRC_AUTO,
    SRC_CSI,
    SRC_USBNODE
} source_t;
typedef enum
{
    ENC_AUTO,
    ENC_SOFTWARE,
    ENC_HARDWARE
} encode_t;

typedef struct
{
    char method[64];
    int width, height;
    int fps;
    int bitrate;
    char corner[32];
    source_t source_mode;
    char source_node[128]; // e.g., /dev/video0
    encode_t encode_mode;
    int skip_menu; // not implemented for C; kept for CLI compatibility
} cfg_t;

typedef struct
{
    char tmpdir[PATH_MAX];
    char fifo_path[PATH_MAX];
    char stats_path[PATH_MAX];
    pid_t cam_pid;
    pid_t prev_pid;
    int prev_stderr_fd; // pipe read end for parsing ffmpeg -stats
    int running;
    int overlay_disabled;
    int width, height, fps, bitrate;
} ctx_t;

// ---------- utils ----------

static noreturn void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "picam_bench: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

static int command_exists(const char *cmd)
{
    char whichcmd[256];
    snprintf(whichcmd, sizeof(whichcmd), "command -v %s >/dev/null 2>&1", cmd);
    return system(whichcmd) == 0;
}

static void xasprintf(char **out, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    if (vasprintf(out, fmt, ap) < 0)
        die("OOM");
    va_end(ap);
}

static void ensure_dir_remove(const char *path)
{
    // rm -rf path
    pid_t p = fork();
    if (p == 0)
    {
        execlp("rm", "rm", "-rf", path, (char *)NULL);
        _exit(127);
    }
    int st;
    waitpid(p, &st, 0);
}

static void safe_mkfifo(const char *path)
{
    if (mkfifo(path, 0600) < 0)
        die("mkfifo(%s): %s", path, strerror(errno));
}

// signal handling / cleanup
static ctx_t *g_ctx = NULL;
static void terminate_children(int sig)
{
    (void)sig;
    if (!g_ctx)
        exit(0);
    g_ctx->running = 0;
    if (g_ctx->cam_pid > 0)
        kill(g_ctx->cam_pid, SIGTERM);
    if (g_ctx->prev_pid > 0)
        kill(g_ctx->prev_pid, SIGTERM);
}
static void install_sighandlers(void)
{
    struct sigaction sa = {0};
    sa.sa_handler = terminate_children;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

// ---------- /proc helpers for CPU/MEM ----------

typedef struct
{
    unsigned long long user, nice, sys, idle, iow, irq, sirq;
} cpu_tot_t;

static int read_proc_stat_total(cpu_tot_t *t)
{
    FILE *f = fopen("/proc/stat", "r");
    if (!f)
        return -1;
    char buf[512];
    if (!fgets(buf, sizeof(buf), f))
    {
        fclose(f);
        return -1;
    }
    fclose(f);
    // cpu  4705 0 1325 88377 ...
    //      user nice sys idle iow irq sirq
    sscanf(buf, "cpu %llu %llu %llu %llu %llu %llu %llu", &t->user, &t->nice, &t->sys, &t->idle, &t->iow, &t->irq, &t->sirq);
    return 0;
}

static int read_proc_pid_stat(pid_t pid, unsigned long long *utime, unsigned long long *stime, long *rss_kb)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    // stat has many fields; 14=utime, 15=stime
    // we need to handle comm with spaces in parentheses
    int i;
    char c;
    // skip pid and comm and state
    // read entire line
    char line[4096];
    size_t n = fread(line, 1, sizeof(line) - 1, f);
    line[n] = 0;
    fclose(f);
    // find last ')'
    char *rp = strrchr(line, ')');
    if (!rp)
        return -1;
    // continue parsing from rp+2 (skip space and state)
    char *p = rp + 2;
    // fields start from #4 now, we need fields 14 & 15 -> indexes 14-3=11 and 15-3=12 from p
    // we'll sscanf many fields
    unsigned long long _ut = 0, _st = 0;
    long rss_pages = 0; // field 24 is rss in pages
    // We'll parse up to rss
    // Format: ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime ...
    // We'll scan 11 values to reach utime (field 14)
    unsigned long long skip[10];
    int read = sscanf(p,
                      "%llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                      &skip[0], &skip[1], &skip[2], &skip[3], &skip[4],
                      &skip[5], &skip[6], &skip[7], &skip[8], &skip[9],
                      &_ut, &_st);
    if (read < 12)
        return -1;

    // find field 24 (rss, in pages). We can tokenise; simpler: reopen /proc/<pid>/status for VmRSS kB.
    char spath[64];
    snprintf(spath, sizeof(spath), "/proc/%d/status", pid);
    FILE *sf = fopen(spath, "r");
    long rsskb = 0;
    if (sf)
    {
        char sb[512];
        while (fgets(sb, sizeof(sb), sf))
        {
            if (!strncmp(sb, "VmRSS:", 6))
            {
                long kb = 0;
                sscanf(sb + 6, "%ld", &kb);
                rsskb = kb;
                break;
            }
        }
        fclose(sf);
    }
    *utime = _ut;
    *stime = _st;
    *rss_kb = rsskb;
    return 0;
}

static double cpu_percent_for_pids(pid_t *pids, int npids, int interval_ms)
{
    cpu_tot_t t0, t1;
    unsigned long long u0[16] = {0}, s0[16] = {0}, u1[16] = {0}, s1[16] = {0};
    long rss_dummy;
    if (read_proc_stat_total(&t0) < 0)
        return 0.0;
    for (int i = 0; i < npids; i++)
        if (pids[i] > 0)
            read_proc_pid_stat(pids[i], &u0[i], &s0[i], &rss_dummy);
    struct timespec ts = {interval_ms / 1000, (interval_ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
    if (read_proc_stat_total(&t1) < 0)
        return 0.0;
    for (int i = 0; i < npids; i++)
        if (pids[i] > 0)
            read_proc_pid_stat(pids[i], &u1[i], &s1[i], &rss_dummy);
    unsigned long long tot0 = t0.user + t0.nice + t0.sys + t0.idle + t0.iow + t0.irq + t0.sirq;
    unsigned long long tot1 = t1.user + t1.nice + t1.sys + t1.idle + t1.iow + t1.irq + t1.sirq;
    double tot_delta = (double)(tot1 - tot0);
    if (tot_delta <= 0)
        return 0.0;
    // convert jiffies to "percentage of one CPU"
    unsigned long long sum = 0;
    for (int i = 0; i < npids; i++)
    {
        sum += (u1[i] - u0[i]) + (s1[i] - s0[i]);
    }
    return (100.0 * (double)sum) / tot_delta;
}

static double rss_mb_for_pids(pid_t *pids, int npids)
{
    long sumkb = 0;
    for (int i = 0; i < npids; i++)
    {
        if (pids[i] <= 0)
            continue;
        unsigned long long ut, st;
        long rsskb = 0;
        if (read_proc_pid_stat(pids[i], &ut, &st, &rsskb) == 0)
            sumkb += rsskb;
    }
    return sumkb / 1024.0;
}

// ---------- V4L2 helpers ----------

static int v4l2_querycap(const char *node, struct v4l2_capability *cap)
{
    int fd = open(node, O_RDONLY | O_NONBLOCK);
    if (fd < 0)
        return -1;
    int rc = ioctl(fd, VIDIOC_QUERYCAP, cap);
    close(fd);
    return rc;
}

static int v4l2_supports_capture(const char *node)
{
    struct v4l2_capability cap;
    if (v4l2_querycap(node, &cap) < 0)
        return 0;
    // Filter out bcm2835-isp/codec
    if (strstr((char *)cap.driver, "bcm2835") || strstr((char *)cap.card, "bcm2835") || strstr((char *)cap.driver, "bcm2835-codec") || strstr((char *)cap.card, "bcm2835-codec"))
        return 0;
    // Prefer uvcvideo
    if (!strstr((char *)cap.driver, "uvcvideo"))
        return 0;
    if ((cap.capabilities & V4L2_CAP_DEVICE_CAPS) && (cap.device_caps & (V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_VIDEO_CAPTURE_MPLANE)))
        return 1;
    if (cap.capabilities & (V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_VIDEO_CAPTURE_MPLANE))
        return 1;
    return 0;
}

typedef struct
{
    int h264, mjpg, yuyv;
} fmt_support_t;

static int v4l2_enum_formats(const char *node, fmt_support_t *fs)
{
    memset(fs, 0, sizeof(*fs));
    int fd = open(node, O_RDONLY | O_NONBLOCK);
    if (fd < 0)
        return -1;
    struct v4l2_fmtdesc desc = {0};
    desc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    for (desc.index = 0;; desc.index++)
    {
        if (ioctl(fd, VIDIOC_ENUM_FMT, &desc) < 0)
            break;
        __u32 pix = desc.pixelformat;
        if (pix == V4L2_PIX_FMT_H264)
            fs->h264 = 1;
        if (pix == V4L2_PIX_FMT_MJPEG)
            fs->mjpg = 1;
        if (pix == V4L2_PIX_FMT_YUYV)
            fs->yuyv = 1;
    }
    // try CAPTURE_MPLANE too
    desc.index = 0;
    desc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    for (;; desc.index++)
    {
        if (ioctl(fd, VIDIOC_ENUM_FMT, &desc) < 0)
            break;
        __u32 pix = desc.pixelformat;
        if (pix == V4L2_PIX_FMT_H264)
            fs->h264 = 1;
        if (pix == V4L2_PIX_FMT_MJPEG)
            fs->mjpg = 1;
        if (pix == V4L2_PIX_FMT_YUYV)
            fs->yuyv = 1;
    }
    close(fd);
    return 0;
}

static int pick_usb_node(char *out, size_t outsz)
{
    glob_t g = {0};
    if (glob("/dev/video*", 0, NULL, &g) != 0)
    {
        globfree(&g);
        return -1;
    }
    for (size_t i = 0; i < g.gl_pathc; i++)
    {
        const char *n = g.gl_pathv[i];
        if (v4l2_supports_capture(n))
        {
            snprintf(out, outsz, "%s", n);
            globfree(&g);
            return 0;
        }
    }
    globfree(&g);
    return -1;
}

// ---------- camera command ----------

static const char *camera_cmd(void)
{
    if (command_exists("rpicam-vid"))
        return "rpicam-vid";
    if (command_exists("libcamera-vid"))
        return "libcamera-vid";
    return NULL;
}

// ---------- process spawn helpers ----------

typedef struct
{
    pid_t pid;
    int stderr_fd; // if capture_stderr=true
} child_t;

static child_t spawn_child(char *const argv[], int stdin_fd, int stdout_fd, int capture_stderr)
{
    int pipe_stderr[2] = {-1, -1};
    if (capture_stderr)
    {
        if (pipe(pipe_stderr) < 0)
            die("pipe: %s", strerror(errno));
    }
    pid_t p = fork();
    if (p < 0)
        die("fork: %s", strerror(errno));
    if (p == 0)
    {
        // child
        if (stdin_fd >= 0)
        {
            dup2(stdin_fd, STDIN_FILENO);
        }
        if (stdout_fd >= 0)
        {
            dup2(stdout_fd, STDOUT_FILENO);
        }
        if (capture_stderr)
        {
            dup2(pipe_stderr[1], STDERR_FILENO);
            close(pipe_stderr[0]);
            close(pipe_stderr[1]);
        }
        // setpgid to separate group for pkill -P?
        // not necessary, parent tracks pids
        execvp(argv[0], argv);
        fprintf(stderr, "execvp %s failed: %s\n", argv[0], strerror(errno));
        _exit(127);
    }
    // parent
    if (stdin_fd >= 0)
        close(stdin_fd);
    if (stdout_fd >= 0)
        close(stdout_fd);
    child_t ch = {.pid = p, .stderr_fd = -1};
    if (capture_stderr)
    {
        close(pipe_stderr[1]);
        ch.stderr_fd = pipe_stderr[0];
        // set nonblocking
        int fl = fcntl(ch.stderr_fd, F_GETFL);
        fcntl(ch.stderr_fd, F_SETFL, fl | O_NONBLOCK);
    }
    return ch;
}

// ---------- overlay / stats ----------

typedef struct
{
    ctx_t *ctx;
    double latest_fps;
    char latest_bitrate[64];
    pthread_mutex_t mu;
} overlay_state_t;

static void *ffmpeg_log_reader(void *arg)
{
    overlay_state_t *st = (overlay_state_t *)arg;
    char buf[4096];
    char line[8192];
    size_t len = 0;
    while (st->ctx->running)
    {
        ssize_t n = read(st->ctx->prev_stderr_fd, buf, sizeof(buf));
        if (n <= 0)
        {
            usleep(100000);
            continue;
        }
        for (ssize_t i = 0; i < n; i++)
        {
            char c = buf[i];
            if (c == '\r' || c == '\n')
            {
                line[len] = 0;
                // parse "fps=xx" and "bitrate=xxx"
                char *fps = strstr(line, "fps=");
                char *br = strstr(line, "bitrate=");
                if (fps)
                {
                    double f = 0;
                    sscanf(fps + 4, "%lf", &f);
                    pthread_mutex_lock(&st->mu);
                    st->latest_fps = f;
                    pthread_mutex_unlock(&st->mu);
                }
                if (br)
                {
                    char b[64] = {0};
                    sscanf(br + 8, "%63s", b);
                    pthread_mutex_lock(&st->mu);
                    snprintf(st->latest_bitrate, sizeof(st->latest_bitrate), "%s", b);
                    pthread_mutex_unlock(&st->mu);
                }
                len = 0;
            }
            else if (len < sizeof(line) - 1)
            {
                line[len++] = c;
            }
        }
    }
    return NULL;
}

static void overlay_coords(const char *corner, const char **ox, const char **oy)
{
    if (!strcmp(corner, "top-right"))
    {
        *ox = "w-tw-10";
        *oy = "10";
    }
    else if (!strcmp(corner, "bottom-left"))
    {
        *ox = "10";
        *oy = "h-th-10";
    }
    else if (!strcmp(corner, "bottom-right"))
    {
        *ox = "w-tw-10";
        *oy = "h-th-10";
    }
    else
    {
        *ox = "10";
        *oy = "10";
    } // top-left default
}

static void *stats_writer(void *arg)
{
    overlay_state_t *st = (overlay_state_t *)arg;
    ctx_t *ctx = st->ctx;
    pid_t pids[2] = {ctx->cam_pid, ctx->prev_pid};

    while (ctx->running)
    {
        // compute CPU% over 250ms
        double cpu = cpu_percent_for_pids(pids, 2, 250);
        double mem = rss_mb_for_pids(pids, 2);

        double fps;
        char br[64];
        pthread_mutex_lock(&st->mu);
        fps = st->latest_fps;
        snprintf(br, sizeof(br), "%s", st->latest_bitrate[0] ? st->latest_bitrate : "N/A");
        pthread_mutex_unlock(&st->mu);

        FILE *f = fopen(ctx->stats_path, "w");
        if (f)
        {
            fprintf(f, "FPS: %.1f\n", fps);
            fprintf(f, "RES: %dx%d\n", ctx->width, ctx->height);
            fprintf(f, "BitRate: %s\n", br);
            fprintf(f, "CPU: %.1f%%\n", cpu);
            fprintf(f, "MEM: %.1f%%\n", 0.0); // leave percent for parity; below line prints MB too
            fprintf(f, "MEM_MB: %.1f\n", mem);
            fclose(f);
        }
        sleep(1);
    }
    return NULL;
}

// ---------- pipeline builders ----------

static void start_preview(ctx_t *ctx, const char *title)
{
    // Build ffmpeg drawtext
    const char *ox, *oy;
    overlay_coords(DEFAULT_CORNER, &ox, &oy); // we'll override corner via cfg later if needed
    // We can't easily probe fonts in C; rely on DejaVu
    char *draw = NULL;
    xasprintf(&draw,
              "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:"
              "textfile=%s:reload=1:x=%s:y=%s:fontcolor=white:fontsize=28:"
              "box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6",
              ctx->stats_path, ox, oy);

    // ffmpeg preview (read from FIFO -> SDL)
    // NOTE: no '-framedrop' (ffplay-only). Add low-latency flags.
    char fps_arg[16];
    snprintf(fps_arg, sizeof(fps_arg), "%d", ctx->fps);
    char *const argv[] = {
        "ffmpeg",
        "-hide_banner", "-loglevel", "info", "-stats",
        "-fflags", "+nobuffer", "-flags", "+low_delay", "-reorder_queue_size", "0", "-thread_queue_size", "512",
        "-f", "h264", "-i", (char *)ctx->fifo_path,
        "-vf", draw,
        "-an", "-f", "sdl", (char *)title,
        NULL};
    child_t ch = spawn_child(argv, -1, -1, /*capture_stderr*/ 1);
    ctx->prev_pid = ch.pid;
    ctx->prev_stderr_fd = ch.stderr_fd;
    free(draw);
}

static void start_csi_camera(ctx_t *ctx, int width, int height, int fps, int bitrate)
{
    const char *cmd = camera_cmd();
    if (!cmd)
        die("libcamera-vid / rpicam-vid not found");

    // open FIFO for writing and dup to stdout for child
    int fifo_fd = open(ctx->fifo_path, O_WRONLY);
    if (fifo_fd < 0)
        die("open fifo for write: %s", strerror(errno));

    char w[16], h[16], fr[16], br[32];
    snprintf(w, sizeof(w), "%d", width);
    snprintf(h, sizeof(h), "%d", height);
    snprintf(fr, sizeof(fr), "%d", fps);
    snprintf(br, sizeof(br), "%d", bitrate);

    char *const argv[] = {
        (char *)cmd,
        "--inline", "--codec", "h264", "--timeout", "0",
        "--width", w, "--height", h, "--framerate", fr,
        "--bitrate", br,
        "-o", "-", // stdout
        NULL};
    child_t ch = spawn_child(argv, -1, fifo_fd, /*capture_stderr*/ 0);
    ctx->cam_pid = ch.pid;
}

static void start_usb_ffmpeg(ctx_t *ctx, const char *devnode, fmt_support_t fs, encode_t enc)
{
    // Decide input_format and encoder
    const char *infmt = NULL;
    if (fs.h264)
        infmt = "h264";
    else if (fs.mjpg)
        infmt = "mjpeg";
    else if (fs.yuyv)
        infmt = "yuyv422";
    else
        infmt = "mjpeg";

    char sz[32], fr[16], br[32];
    snprintf(sz, sizeof(sz), "%dx%d", ctx->width, ctx->height);
    snprintf(fr, sizeof(fr), "%d", ctx->fps);
    snprintf(br, sizeof(br), "%d", ctx->bitrate);

// Build argv dynamically
// Common head:
// ffmpeg -hide_banner -loglevel error -f v4l2 -input_format X -video_size WxH -framerate F -i DEV ...
#define MAXARGS 64
    char *argv[MAXARGS];
    int ac = 0;
    argv[ac++] = "ffmpeg";
    argv[ac++] = "-hide_banner";
    argv[ac++] = "-loglevel";
    argv[ac++] = "error";
    argv[ac++] = "-f";
    argv[ac++] = "v4l2";
    argv[ac++] = "-input_format";
    argv[ac++] = (char *)infmt;
    argv[ac++] = "-video_size";
    argv[ac++] = sz;
    argv[ac++] = "-framerate";
    argv[ac++] = fr;
    argv[ac++] = "-i";
    argv[ac++] = (char *)devnode;

    if (fs.h264)
    {
        // Native H.264 → copy (lowest CPU, lowest latency)
        argv[ac++] = "-c:v";
        argv[ac++] = "copy";
    }
    else if (enc == ENC_HARDWARE)
    {
        argv[ac++] = "-pix_fmt";
        argv[ac++] = "nv12";
        argv[ac++] = "-c:v";
        argv[ac++] = "h264_v4l2m2m";
        argv[ac++] = "-b:v";
        argv[ac++] = br;
        argv[ac++] = "-maxrate";
        argv[ac++] = br;
        argv[ac++] = "-bufsize";
        argv[ac++] = br;
    }
    else
    {
        argv[ac++] = "-c:v";
        argv[ac++] = "libx264";
        argv[ac++] = "-preset";
        argv[ac++] = "ultrafast";
        argv[ac++] = "-tune";
        argv[ac++] = "zerolatency";
        argv[ac++] = "-b:v";
        argv[ac++] = br;
        argv[ac++] = "-maxrate";
        argv[ac++] = br;
        argv[ac++] = "-bufsize";
        argv[ac++] = br;
    }

    argv[ac++] = "-f";
    argv[ac++] = "h264";
    argv[ac++] = (char *)ctx->fifo_path;
    argv[ac++] = NULL;

    child_t ch = spawn_child(argv, -1, -1, /*capture_stderr*/ 0);
    ctx->cam_pid = ch.pid;
}

// ---------- CLI ----------

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [options]\n"
            "  -m, --method <name>          (default " DEFAULT_METHOD ")\n"
            "  -r, --resolution WxH         (default %dx%d)\n"
            "  -f, --fps <num>              (default %d)\n"
            "  -b, --bitrate <bits>         (default %d)\n"
            "  -c, --corner <pos>           top-left|top-right|bottom-left|bottom-right\n"
            "  -s, --source <auto|csi|/dev/videoN> (default " DEFAULT_SOURCE ")\n"
            "  -e, --encode <auto|software|hardware> (default " DEFAULT_ENCODE ")\n"
            "      --list-cameras\n"
            "      --no-menu                (ignored; for compatibility)\n"
            "      --no-overlay             (skip drawtext + stats thread)\n"
            "  -h, --help\n",
            prog, DEFAULT_RESOLUTION_W, DEFAULT_RESOLUTION_H, DEFAULT_FPS, DEFAULT_BITRATE);
}

static void parse_res(const char *s, int *w, int *h)
{
    if (sscanf(s, "%dx%d", w, h) != 2 || *w <= 0 || *h <= 0)
        die("Invalid resolution '%s'", s);
}

static void parse_cfg(int argc, char **argv, cfg_t *cfg, int *list_only, int *no_overlay)
{
    // defaults
    snprintf(cfg->method, sizeof(cfg->method), "%s", DEFAULT_METHOD);
    cfg->width = DEFAULT_RESOLUTION_W;
    cfg->height = DEFAULT_RESOLUTION_H;
    cfg->fps = DEFAULT_FPS;
    cfg->bitrate = DEFAULT_BITRATE;
    snprintf(cfg->corner, sizeof(cfg->corner), "%s", DEFAULT_CORNER);
    cfg->source_mode = SRC_AUTO;
    cfg->source_node[0] = 0;
    cfg->encode_mode = ENC_AUTO;
    cfg->skip_menu = 1;
    *list_only = 0;
    *no_overlay = 0;

    for (int i = 1; i < argc; i++)
    {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help"))
        {
            usage(argv[0]);
            exit(0);
        }
        else if (!strcmp(a, "-m") || !strcmp(a, "--method"))
        {
            if (++i >= argc)
                die("missing value");
            snprintf(cfg->method, sizeof(cfg->method), "%s", argv[i]);
        }
        else if (!strcmp(a, "-r") || !strcmp(a, "--resolution"))
        {
            if (++i >= argc)
                die("missing value");
            parse_res(argv[i], &cfg->width, &cfg->height);
        }
        else if (!strcmp(a, "-f") || !strcmp(a, "--fps"))
        {
            if (++i >= argc)
                die("missing value");
            cfg->fps = atoi(argv[i]);
        }
        else if (!strcmp(a, "-b") || !strcmp(a, "--bitrate"))
        {
            if (++i >= argc)
                die("missing value");
            cfg->bitrate = atoi(argv[i]);
        }
        else if (!strcmp(a, "-c") || !strcmp(a, "--corner"))
        {
            if (++i >= argc)
                die("missing value");
            snprintf(cfg->corner, sizeof(cfg->corner), "%s", argv[i]);
        }
        else if (!strcmp(a, "-s") || !strcmp(a, "--source"))
        {
            if (++i >= argc)
                die("missing value");
            if (!strcmp(argv[i], "auto"))
                cfg->source_mode = SRC_AUTO;
            else if (!strcmp(argv[i], "csi"))
                cfg->source_mode = SRC_CSI;
            else if (!strncmp(argv[i], "/dev/video", 10))
            {
                cfg->source_mode = SRC_USBNODE;
                snprintf(cfg->source_node, sizeof(cfg->source_node), "%s", argv[i]);
            }
            else
                die("invalid --source '%s'", argv[i]);
        }
        else if (!strcmp(a, "-e") || !strcmp(a, "--encode"))
        {
            if (++i >= argc)
                die("missing value");
            if (!strcmp(argv[i], "auto"))
                cfg->encode_mode = ENC_AUTO;
            else if (!strcmp(argv[i], "software"))
                cfg->encode_mode = ENC_SOFTWARE;
            else if (!strcmp(argv[i], "hardware"))
                cfg->encode_mode = ENC_HARDWARE;
            else
                die("invalid --encode '%s'", argv[i]);
        }
        else if (!strcmp(a, "--list-cameras"))
        {
            *list_only = 1;
        }
        else if (!strcmp(a, "--no-menu"))
        { /* ignore */
        }
        else if (!strcmp(a, "--no-overlay"))
        {
            *no_overlay = 1;
        }
        else
            die("unknown arg: %s", a);
    }
}

// ---------- camera detection ----------

static int detect_csi_available(void)
{
    const char *cmd = camera_cmd();
    if (!cmd)
        return 0;
    // run "<cmd> --list-cameras"
    int pipefd[2];
    if (pipe(pipefd) < 0)
        return 0;
    pid_t p = fork();
    if (p == 0)
    {
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[0]);
        close(pipefd[1]);
        char *const argv[] = {(char *)cmd, "--list-cameras", (char *)NULL};
        execvp(argv[0], argv);
        _exit(127);
    }
    close(pipefd[1]);
    char buf[8192];
    ssize_t n = read(pipefd[0], buf, sizeof(buf) - 1);
    if (n < 0)
        n = 0;
    buf[n] = 0;
    close(pipefd[0]);
    int st;
    waitpid(p, &st, 0);
    if (!strstr(buf, "Available cameras"))
        return 0;
    // consider CSI present if there is any cam not labeled usb@
    if (strstr(buf, "usb@"))
    {
        // might be only usb; check any line without usb@
        char *pn = buf;
        bool has_non_usb = false;
        while ((pn = strstr(pn, "Index")))
        {
            char *line_end = strchr(pn, '\n');
            if (!line_end)
                line_end = buf + n;
            if (!strstr(pn, "usb@"))
            {
                has_non_usb = true;
                break;
            }
            pn = line_end;
        }
        return has_non_usb ? 1 : 0;
    }
    return 1;
}

static int detect_usb(char *node_out, size_t outsz, fmt_support_t *fs)
{
    if (pick_usb_node(node_out, outsz) < 0)
        return 0;
    v4l2_enum_formats(node_out, fs);
    return 1;
}

// ---------- main ----------

int main(int argc, char **argv)
{
    cfg_t cfg;
    int list_only = 0, no_overlay = 0;
    parse_cfg(argc, argv, &cfg, &list_only, &no_overlay);

    if (!command_exists("ffmpeg"))
        die("ffmpeg not found");
    int have_cam_cmd = camera_cmd() != NULL;

    if (list_only)
    {
        printf("=== Camera list ===\n");
        printf("CSI available: %s\n", detect_csi_available() ? "yes" : "no");
        char node[128];
        fmt_support_t fs;
        if (detect_usb(node, sizeof(node), &fs))
        {
            printf("USB capture: %s (formats: %s%s%s)\n", node,
                   fs.h264 ? "H264 " : "", fs.mjpg ? "MJPG " : "", fs.yuyv ? "YUYV " : "");
        }
        else
        {
            printf("USB capture: none\n");
        }
        return 0;
    }

    // Decide source
    int use_csi = 0;
    char usbnode[128] = "";
    fmt_support_t usbfmt = {0};
    if (cfg.source_mode == SRC_CSI)
    {
        if (!detect_csi_available())
            die("CSI camera not found");
        use_csi = 1;
    }
    else if (cfg.source_mode == SRC_USBNODE)
    {
        if (!v4l2_supports_capture(cfg.source_node))
            die("Invalid USB node: %s", cfg.source_node);
        snprintf(usbnode, sizeof(usbnode), "%s", cfg.source_node);
        v4l2_enum_formats(usbnode, &usbfmt);
    }
    else
    { // auto
        if (detect_csi_available())
            use_csi = 1;
        else if (detect_usb(usbnode, sizeof(usbnode), &usbfmt))
            use_csi = 0;
        else
            die("No supported camera found. Please connect a CSI module or USB camera.");
    }

    // Decide encoding
    encode_t enc = cfg.encode_mode;
    if (enc == ENC_AUTO)
    {
        enc = ENC_HARDWARE; // prefer hardware when transcoding
    }

    // Prepare ctx
    ctx_t ctx = {0};
    g_ctx = &ctx;
    ctx.running = 1;
    ctx.overlay_disabled = no_overlay;
    ctx.width = cfg.width;
    ctx.height = cfg.height;
    ctx.fps = cfg.fps;
    ctx.bitrate = cfg.bitrate;

    install_sighandlers();

    // temp dir + fifo + stats
    char templ[] = "/tmp/picamc.XXXXXX";
    char *dir = mkdtemp(templ);
    if (!dir)
        die("mkdtemp: %s", strerror(errno));
    snprintf(ctx.tmpdir, sizeof(ctx.tmpdir), "%s", dir);
    snprintf(ctx.fifo_path, sizeof(ctx.fifo_path), "%s/video.h264", dir);
    snprintf(ctx.stats_path, sizeof(ctx.stats_path), "%s/stats.txt", dir);
    safe_mkfifo(ctx.fifo_path);
    // pre-create stats
    FILE *sf = fopen(ctx.stats_path, "w");
    if (sf)
    {
        fputs("FPS: 0.0\nRES: 0x0\nBitRate: 0\nCPU: 0%\nMEM: 0%\n", sf);
        fclose(sf);
    }

    // Start preview (captures stderr for stats parsing)
    start_preview(&ctx, use_csi ? "PiCam Preview (CSI)" : "USB Camera Preview");

    // Start camera path
    if (use_csi)
    {
        if (!have_cam_cmd)
            die("rpicam-vid/libcamera-vid required for CSI");
        start_csi_camera(&ctx, cfg.width, cfg.height, cfg.fps, cfg.bitrate);
    }
    else
    {
        // usbnode prefilled by auto or user
        if (usbnode[0] == 0)
            snprintf(usbnode, sizeof(usbnode), "%s", cfg.source_node);
        start_usb_ffmpeg(&ctx, usbnode, usbfmt, enc);
    }

    // Stats threads
    overlay_state_t ost = {.ctx = &ctx, .latest_fps = 0.0};
    pthread_mutex_init(&ost.mu, NULL);

    pthread_t th_log, th_stats;
    if (!ctx.overlay_disabled && ctx.prev_stderr_fd >= 0)
    {
        pthread_create(&th_log, NULL, ffmpeg_log_reader, &ost);
        pthread_create(&th_stats, NULL, stats_writer, &ost);
    }

    // Wait children
    int st1 = 0, st2 = 0;
    if (ctx.cam_pid > 0)
        waitpid(ctx.cam_pid, &st1, 0);
    if (ctx.prev_pid > 0)
        waitpid(ctx.prev_pid, &st2, 0);
    ctx.running = 0;

    if (!ctx.overlay_disabled && ctx.prev_stderr_fd >= 0)
    {
        pthread_cancel(th_log);
        pthread_cancel(th_stats);
        pthread_join(th_log, NULL);
        pthread_join(th_stats, NULL);
    }

    // cleanup
    ensure_dir_remove(ctx.tmpdir);
    return 0;
}

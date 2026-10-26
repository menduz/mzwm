// Fixed values for the widgets of the kwm bar in the screenshots. The
// screenshot script loads this library into kwm with LD_PRELOAD.
//
//   - /proc/stat: 16 cores. On each read, the counters of each core grow
//     with its fixed use in `core_use` (busy) and the rest to 100 (idle).
//     Thus each core shows the same use at each update, at each speed of
//     the build. The "cpu" line is the sum of the cores: 25%.
//   - /proc/meminfo: 40% of 16 GiB is used.
//   - statvfs("/"): 200 GB of 500 GB are free.
//   - /sys/class/power_supply: no battery.
//   - /sys/class/hwmon: no temperature sensors.
//
// The other files and paths go to the C library.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/statvfs.h>
#include <unistd.h>

static unsigned long cpu_reads;

// The use of each core in percent: low, medium, warning (70) and critical
// (90) values. The sum is 400 of 1600: 25%.
static const unsigned core_use[] = {
    10, 25, 40, 15, 5, 30, 75, 20, 5, 45, 95, 10, 5, 0, 15, 5,
};
#define CORES (sizeof core_use / sizeof core_use[0])

// A file in memory that holds `text`, open for reading at its start.
static int memory_file(const char *text) {
    int fd = memfd_create("kwm-screenshot", MFD_CLOEXEC);
    if (fd < 0) return -1;
    size_t len = strlen(text);
    if (write(fd, text, len) != (ssize_t)len) {
        close(fd);
        return -1;
    }
    lseek(fd, 0, SEEK_SET);
    return fd;
}

// The file descriptor for a path with a fixed value, -1 with ENOENT for a path
// that does not exist in the screenshots, or -2 for the other paths.
static int fixed_file(const char *path) {
    if (strcmp(path, "/proc/stat") == 0) {
        cpu_reads++;
        unsigned long busy = 0;
        for (size_t i = 0; i < CORES; i++) busy += core_use[i];
        char text[2048];
        int len = snprintf(text, sizeof text,
                           "cpu  %lu 0 0 %lu 0 0 0 0 0 0\n",
                           cpu_reads * busy, cpu_reads * (100 * CORES - busy));
        for (size_t i = 0; i < CORES; i++) {
            len += snprintf(text + len, sizeof text - len,
                            "cpu%zu %lu 0 0 %lu 0 0 0 0 0 0\n", i,
                            cpu_reads * core_use[i],
                            cpu_reads * (100 - core_use[i]));
        }
        return memory_file(text);
    }
    if (strcmp(path, "/proc/meminfo") == 0) {
        return memory_file(
            "MemTotal:       16777216 kB\n"
            "MemFree:         8388608 kB\n"
            "MemAvailable:   10066330 kB\n");
    }
    if (strncmp(path, "/sys/class/power_supply", 23) == 0
        || strncmp(path, "/sys/class/hwmon", 16) == 0) {
        errno = ENOENT;
        return -1;
    }
    return -2;
}

#define OPEN_WRAPPER(name)                                                    \
    int name(const char *path, int flags, ...) {                              \
        mode_t mode = 0;                                                      \
        if (flags & (O_CREAT | O_TMPFILE)) {                                  \
            va_list args;                                                     \
            va_start(args, flags);                                            \
            mode = va_arg(args, mode_t);                                      \
            va_end(args);                                                     \
        }                                                                     \
        int fd = fixed_file(path);                                            \
        if (fd != -2) return fd;                                              \
        int (*next)(const char *, int, ...) = dlsym(RTLD_NEXT, #name);        \
        return next(path, flags, mode);                                       \
    }

#define OPENAT_WRAPPER(name)                                                  \
    int name(int dirfd, const char *path, int flags, ...) {                   \
        mode_t mode = 0;                                                      \
        if (flags & (O_CREAT | O_TMPFILE)) {                                  \
            va_list args;                                                     \
            va_start(args, flags);                                            \
            mode = va_arg(args, mode_t);                                      \
            va_end(args);                                                     \
        }                                                                     \
        int fd = fixed_file(path);                                            \
        if (fd != -2) return fd;                                              \
        int (*next)(int, const char *, int, ...) = dlsym(RTLD_NEXT, #name);   \
        return next(dirfd, path, flags, mode);                                \
    }

OPEN_WRAPPER(open)
OPEN_WRAPPER(open64)
OPENAT_WRAPPER(openat)
OPENAT_WRAPPER(openat64)

static void fixed_statvfs(struct statvfs *buf) {
    memset(buf, 0, sizeof *buf);
    buf->f_bsize = 4096;
    buf->f_frsize = 4096;
    buf->f_blocks = 500000000000UL / 4096;
    buf->f_bfree = 200000000000UL / 4096;
    buf->f_bavail = 200000000000UL / 4096;
}

int statvfs(const char *path, struct statvfs *buf) {
    if (strcmp(path, "/") == 0) {
        fixed_statvfs(buf);
        return 0;
    }
    int (*next)(const char *, struct statvfs *) = dlsym(RTLD_NEXT, "statvfs");
    return next(path, buf);
}

int statvfs64(const char *path, struct statvfs64 *buf) {
    if (strcmp(path, "/") == 0) {
        fixed_statvfs((struct statvfs *)buf);
        return 0;
    }
    int (*next)(const char *, struct statvfs64 *) = dlsym(RTLD_NEXT, "statvfs64");
    return next(path, buf);
}

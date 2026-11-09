#ifdef __linux__
#define _GNU_SOURCE
#include "AndesiteFS.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

/* inotify watches directories, not trees: every non-hidden directory gets a
 * watch, and directories created later are added as their events arrive.
 * Events are only a hint that something changed; the scanner decides what. */
struct andesite_inotify_watch {
    int fd;
    uint64_t generation;
    int count, capacity;
    int *wds;
    char **paths;
};

#define ANDESITE_INOTIFY_MASK (IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB | \
                               IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR | IN_DONT_FOLLOW)

static int remember(andesite_inotify_watch *w, int wd, const char *path) {
    for (int i = 0; i < w->count; i++) {
        if (w->wds[i] == wd) { free(w->paths[i]); w->paths[i] = strdup(path); return w->paths[i] ? 0 : -1; }
    }
    if (w->count == w->capacity) {
        int capacity = w->capacity ? w->capacity * 2 : 64;
        int *wds = realloc(w->wds, sizeof(int) * capacity);
        if (!wds) return -1;
        w->wds = wds;
        char **paths = realloc(w->paths, sizeof(char *) * capacity);
        if (!paths) return -1;
        w->paths = paths;
        w->capacity = capacity;
    }
    w->paths[w->count] = strdup(path);
    if (!w->paths[w->count]) return -1;
    w->wds[w->count++] = wd;
    return 0;
}

static const char *path_of(andesite_inotify_watch *w, int wd) {
    for (int i = 0; i < w->count; i++) if (w->wds[i] == wd) return w->paths[i];
    return NULL;
}

/* Watches `path` and every non-hidden directory below it. */
static int add_tree(andesite_inotify_watch *w, const char *path) {
    int wd = inotify_add_watch(w->fd, path, ANDESITE_INOTIFY_MASK);
    if (wd < 0) return errno == ENOENT || errno == ENOTDIR ? 0 : -1;
    if (remember(w, wd, path) != 0) return -1;
    DIR *dir = opendir(path);
    if (!dir) return errno == ENOENT ? 0 : -1;
    struct dirent *item;
    int result = 0;
    while ((item = readdir(dir)) != NULL) {
        if (item->d_name[0] == '.') continue;
        char child[PATH_MAX];
        if (snprintf(child, sizeof child, "%s/%s", path, item->d_name) >= (int)sizeof child) continue;
        struct stat info;
        if (lstat(child, &info) == 0 && S_ISDIR(info.st_mode) && add_tree(w, child) != 0) { result = -1; break; }
    }
    closedir(dir);
    return result;
}

andesite_inotify_watch *andesite_inotify_start(const char *root) {
    andesite_inotify_watch *w = calloc(1, sizeof *w);
    if (!w) return NULL;
    w->fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (w->fd < 0 || add_tree(w, root) != 0) {
        int saved = errno;
        andesite_inotify_stop(w);
        errno = saved;
        return NULL;
    }
    return w;
}

int andesite_inotify_drain(andesite_inotify_watch *w, uint64_t *generation, uint32_t *rescan) {
    char buffer[64 * 1024] __attribute__((aligned(__alignof__(struct inotify_event))));
    *rescan = 0;
    for (;;) {
        ssize_t n = read(w->fd, buffer, sizeof buffer);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) break;
            return -1;
        }
        if (n == 0) break;
        for (char *p = buffer; p < buffer + n;) {
            struct inotify_event *event = (struct inotify_event *)p;
            p += sizeof *event + event->len;
            if (event->mask & IN_Q_OVERFLOW) { *rescan = 1; w->generation++; continue; }
            if (event->len > 0 && event->name[0] == '.') continue; /* hidden: never indexed */
            w->generation++;
            if ((event->mask & IN_ISDIR) && (event->mask & (IN_CREATE | IN_MOVED_TO)) && event->len > 0) {
                const char *parent = path_of(w, event->wd);
                char child[PATH_MAX];
                if (parent && snprintf(child, sizeof child, "%s/%s", parent, event->name) < (int)sizeof child &&
                    add_tree(w, child) != 0) {
                    *rescan = 1; /* could not watch a new folder (watch limit): rescan instead */
                }
            }
        }
    }
    *generation = w->generation;
    return 0;
}

int andesite_birth_time(int directory, const char *name, int64_t *seconds, int64_t *nanoseconds) {
    struct statx info;
    int flags = AT_SYMLINK_NOFOLLOW | (name[0] == 0 ? AT_EMPTY_PATH : 0);
    if (statx(directory, name, flags, STATX_BTIME, &info) != 0 || !(info.stx_mask & STATX_BTIME)) return -1;
    *seconds = info.stx_btime.tv_sec;
    *nanoseconds = info.stx_btime.tv_nsec;
    return 0;
}

void andesite_inotify_stop(andesite_inotify_watch *w) {
    if (!w) return;
    if (w->fd >= 0) close(w->fd);
    for (int i = 0; i < w->count; i++) free(w->paths[i]);
    free(w->paths);
    free(w->wds);
    free(w);
}
#endif

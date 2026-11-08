#include "AndesiteFS.h"
#ifdef __APPLE__
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

struct andesite_fsevents_watch {
    pthread_mutex_t mutex;
    FSEventStreamRef stream;
    dispatch_queue_t queue;
    uint64_t generation;
    uint64_t last_event_id;
    uint32_t recovery_flags;
};

static void queue_barrier(void *unused) { (void)unused; }

static void on_events(ConstFSEventStreamRef stream, void *info, size_t count,
                      void *paths, const FSEventStreamEventFlags flags[],
                      const FSEventStreamEventId ids[]) {
    (void)stream;
    (void)paths;  /* All events are hints; the existing scanner owns paths. */
    struct andesite_fsevents_watch *watch = info;
    pthread_mutex_lock(&watch->mutex);
    if (watch->generation != UINT64_MAX) {
        watch->generation += count > UINT64_MAX - watch->generation
            ? UINT64_MAX - watch->generation : count;
    }
    const uint32_t mask =
        kFSEventStreamEventFlagMustScanSubDirs |
        kFSEventStreamEventFlagUserDropped |
        kFSEventStreamEventFlagKernelDropped |
        kFSEventStreamEventFlagEventIdsWrapped |
        kFSEventStreamEventFlagRootChanged |
        kFSEventStreamEventFlagMount |
        kFSEventStreamEventFlagUnmount;
    for (size_t i = 0; i < count; i++) {
        watch->recovery_flags |= flags[i] & mask;
        if (ids[i] > watch->last_event_id) watch->last_event_id = ids[i];
    }
    pthread_mutex_unlock(&watch->mutex);
}

andesite_fsevents_watch *andesite_fsevents_start(const char *root, double latency) {
    if (!root || !root[0] || latency <= 0) { errno = EINVAL; return NULL; }
    struct andesite_fsevents_watch *watch = calloc(1, sizeof(*watch));
    if (!watch) { errno = ENOMEM; return NULL; }
    if (pthread_mutex_init(&watch->mutex, NULL) != 0) { free(watch); errno = EIO; return NULL; }
    CFStringRef path = CFStringCreateWithCString(kCFAllocatorDefault, root, kCFStringEncodingUTF8);
    if (!path) { errno = EINVAL; goto fail; }
    const void *watched_paths[] = { path };
    CFArrayRef paths = CFArrayCreate(kCFAllocatorDefault, watched_paths, 1, &kCFTypeArrayCallBacks);
    CFRelease(path);
    if (!paths) { errno = ENOMEM; goto fail; }
    FSEventStreamContext context = {0, watch, NULL, NULL, NULL};
    watch->stream = FSEventStreamCreate(kCFAllocatorDefault, on_events, &context, paths,
        kFSEventStreamEventIdSinceNow, latency,
        kFSEventStreamCreateFlagFileEvents |
        kFSEventStreamCreateFlagWatchRoot |
        kFSEventStreamCreateFlagNoDefer);
    CFRelease(paths);
    if (!watch->stream) { errno = EIO; goto fail; }
    watch->queue = dispatch_queue_create("andesite.fsevents", DISPATCH_QUEUE_SERIAL);
    if (!watch->queue) { errno = ENOMEM; goto fail; }
    FSEventStreamSetDispatchQueue(watch->stream, watch->queue);
    if (!FSEventStreamStart(watch->stream)) { errno = EIO; goto fail; }
    return watch;
fail: {
    int saved_errno = errno;
    if (watch->stream) {
        FSEventStreamInvalidate(watch->stream);
        if (watch->queue) dispatch_sync_f(watch->queue, NULL, queue_barrier);
        FSEventStreamRelease(watch->stream);
    }
    if (watch->queue) dispatch_release(watch->queue);
    pthread_mutex_destroy(&watch->mutex);
    free(watch);
    errno = saved_errno;
    return NULL;
}
}

int andesite_fsevents_drain(andesite_fsevents_watch *watch, andesite_fsevents_events *out) {
    if (!watch || !out) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&watch->mutex);
    out->generation = watch->generation;
    out->last_event_id = watch->last_event_id;
    out->recovery_flags = watch->recovery_flags;
    watch->recovery_flags = 0;
    pthread_mutex_unlock(&watch->mutex);
    return 0;
}

void andesite_fsevents_stop(andesite_fsevents_watch *watch) {
    if (!watch) return;
    FSEventStreamStop(watch->stream);
    FSEventStreamInvalidate(watch->stream);
    /* Do not free callback context while queued callbacks might still run. */
    dispatch_sync_f(watch->queue, NULL, queue_barrier);
    FSEventStreamRelease(watch->stream);
    dispatch_release(watch->queue);
    pthread_mutex_destroy(&watch->mutex);
    free(watch);
}
#endif

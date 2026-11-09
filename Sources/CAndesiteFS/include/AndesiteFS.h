#ifndef ANDESITE_FS_H
#define ANDESITE_FS_H
int andesite_supported_filesystem(int directory);
/* Atomically swap two names (RENAME_SWAP / RENAME_EXCHANGE). */
int andesite_exchange(int directory_a, const char *a, int directory_b, const char *b);
/* Atomic rename that fails with EEXIST instead of replacing the target. */
int andesite_rename_noreplace(int from_directory, const char *from, int to_directory, const char *to);
int andesite_copy_metadata(int source, int destination);

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_OSX
#include <stdint.h>
typedef struct andesite_fsevents_watch andesite_fsevents_watch;
typedef struct {
    uint64_t generation;
    uint64_t last_event_id;
    uint32_t recovery_flags;
} andesite_fsevents_events;
/* The stream is started before any initial scan. Callbacks never touch vault data. */
andesite_fsevents_watch *andesite_fsevents_start(const char *root, double latency);
int andesite_fsevents_drain(andesite_fsevents_watch *watch, andesite_fsevents_events *out);
void andesite_fsevents_stop(andesite_fsevents_watch *watch);
#endif /* TARGET_OS_OSX */

#ifdef __linux__
#include <stdint.h>
typedef struct andesite_inotify_watch andesite_inotify_watch;
andesite_inotify_watch *andesite_inotify_start(const char *root);
/* Non-blocking. `generation` counts observed changes; `rescan` reports lost events. */
int andesite_inotify_drain(andesite_inotify_watch *watch, uint64_t *generation, uint32_t *rescan);
void andesite_inotify_stop(andesite_inotify_watch *watch);
/* Birth time via statx (name "" means `directory` is the file itself); -1 if the filesystem has none. */
int andesite_birth_time(int directory, const char *name, int64_t *seconds, int64_t *nanoseconds);
#endif /* __linux__ */
#endif /* ANDESITE_FS_H */

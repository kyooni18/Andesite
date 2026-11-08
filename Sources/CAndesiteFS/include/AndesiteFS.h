#ifndef ANDESITE_FS_H
#define ANDESITE_FS_H
int andesite_supported_filesystem(int directory);
int andesite_exchange(int directory, const char *stage, const char *target);
int andesite_copy_metadata(int source, int destination);

#ifdef __APPLE__
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
void andesite_monitor_install_stop_handlers(void);
int andesite_monitor_stop_requested(void);
#endif
#endif /* ANDESITE_FS_H */

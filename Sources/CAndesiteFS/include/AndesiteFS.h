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
/* Local HTTP/1.1 over a private AF_UNIX socket, never TCP. */
typedef struct andesite_local_http andesite_local_http;
int andesite_local_http_resolve_path(const char *state_directory, char *path, unsigned long capacity);
andesite_local_http *andesite_local_http_open(const char *state_directory);
int andesite_local_http_accept(andesite_local_http *server); /* -2: idle, -3: unauthorized, -1: error */
long andesite_local_http_read_headers(int client, char *buffer, unsigned long capacity);
void andesite_local_http_close(andesite_local_http *server);
void andesite_monitor_install_stop_handlers(void);
int andesite_monitor_stop_requested(void);
/* Bounded, local-only read-only HTTP relay; 0 on success, -1 on failure.
   The response is the entire HTTP/1.1 response, capped by capacity. */
int andesite_http_relay_get(const char *socket_path, const char *target,
                           unsigned char *out, unsigned long capacity,
                           unsigned long *length);
/* Bounded authenticated-sidecar PUT relay and bounded owner request reader. */
long andesite_local_http_read_request(int client, char *buffer, unsigned long capacity);
int andesite_http_relay_put(const char *socket_path, const char *target,
                           const char *revision, const unsigned char *body,
                           unsigned long body_length, unsigned char *out,
                           unsigned long capacity, unsigned long *length);
#endif /* __APPLE__ */
#endif /* ANDESITE_FS_H */

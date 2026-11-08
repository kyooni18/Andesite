#include "AndesiteFS.h"
#ifdef __APPLE__
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/poll.h>
#include <sys/fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <stddef.h>
#include <limits.h>
#include <CommonCrypto/CommonDigest.h>
#include <time.h>

struct andesite_local_http {
    int listener;
    char *path;
    dev_t device;
    ino_t inode;
};

/* sun_path is short on macOS. Prefer the private state directory; for long
   paths, use a per-UID 0700 directory with a cryptographically derived name.
   Even in the fallback, only same-UID peers are accepted. */
int andesite_local_http_resolve_path(const char *state_directory, char *out,
                                    unsigned long capacity) {
    if (!state_directory || !out || capacity < sizeof(((struct sockaddr_un *)0)->sun_path)) {
        errno = EINVAL; return -1;
    }
    const char *suffix = "/andesite-read.sock";
    size_t length = strlen(state_directory), tail = strlen(suffix);
    if (length == 0 || state_directory[0] != '/') { errno = EINVAL; return -1; }
    if (length + tail < sizeof(((struct sockaddr_un *)0)->sun_path)) {
        memcpy(out, state_directory, length);
        memcpy(out + length, suffix, tail + 1);
        return 0;
    }
    char directory[128];
    int size = snprintf(directory, sizeof(directory), "/private/tmp/andesite-http-%lu",
                        (unsigned long)geteuid());
    if (size < 0 || (size_t)size >= sizeof(directory)) { errno = ENAMETOOLONG; return -1; }
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) return -1;
    struct stat existing;
    if (lstat(directory, &existing) != 0 || !S_ISDIR(existing.st_mode) ||
        existing.st_uid != geteuid() || (existing.st_mode & 0077) != 0) {
        errno = EPERM; return -1;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(state_directory, (CC_LONG)length, digest);
    char name[32];
    for (int i = 0; i < 12; ++i) snprintf(&name[i * 2], 3, "%02x", digest[i]);
    name[24] = '\0';
    size = snprintf(out, capacity, "%s/%s.sock", directory, name);
    if (size < 0 || (size_t)size >= capacity ||
        (size_t)size >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        errno = ENAMETOOLONG; return -1;
    }
    return 0;
}

andesite_local_http *andesite_local_http_open(const char *state_directory) {
    if (!state_directory) { errno = EINVAL; return NULL; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (andesite_local_http_resolve_path(state_directory, addr.sun_path,
                                         sizeof(addr.sun_path)) != 0) return NULL;
    size_t length = strlen(addr.sun_path);
    socklen_t addrlen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + length + 1);
    struct stat prior;
    if (lstat(addr.sun_path, &prior) == 0) {
        // Only remove a stale Unix socket inside the operator-owned private
        // state directory. Runtime's exclusive process lock must be held.
        if (!S_ISSOCK(prior.st_mode) || prior.st_uid != geteuid() ||
            prior.st_nlink != 1 || unlink(addr.sun_path) != 0) {
            errno = EPERM; return NULL;
        }
    } else if (errno != ENOENT) { return NULL; }

    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) return NULL;
    int flags = fcntl(listener, F_GETFL);
    if (flags < 0 || fcntl(listener, F_SETFL, flags | O_NONBLOCK) != 0) {
        int err = errno; close(listener); errno = err; return NULL;
    }
    if (bind(listener, (struct sockaddr *)&addr, addrlen) != 0) {
        int err = errno; close(listener); errno = err; return NULL;
    }
    if (chmod(addr.sun_path, 0600) != 0 || listen(listener, 8) != 0) {
        int err = errno; unlink(addr.sun_path); close(listener); errno = err; return NULL;
    }
    struct stat identity;
    if (lstat(addr.sun_path, &identity) != 0 || !S_ISSOCK(identity.st_mode)) {
        int err = errno ? errno : EIO; unlink(addr.sun_path); close(listener); errno = err; return NULL;
    }
    andesite_local_http *server = calloc(1, sizeof(*server));
    if (!server) {
        unlink(addr.sun_path); close(listener); errno = ENOMEM; return NULL;
    }
    server->path = strdup(addr.sun_path);
    if (!server->path) {
        free(server); unlink(addr.sun_path); close(listener); errno = ENOMEM; return NULL;
    }
    server->listener = listener;
    server->device = identity.st_dev;
    server->inode = identity.st_ino;
    return server;
}

int andesite_local_http_accept(andesite_local_http *server) {
    if (!server) { errno = EINVAL; return -1; }
    int client = accept(server->listener, NULL, NULL);
    if (client < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -2;
        return -1;
    }
    uid_t uid = (uid_t)-1;
    gid_t gid = (gid_t)-1;
    if (getpeereid(client, &uid, &gid) != 0 || uid != geteuid()) {
        close(client);
        return -3;
    }
    int yes = 1;
    (void)setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 250000};
    (void)setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    return client;
}

/* Read only a complete bounded header. Any request body is rejected in Swift.
   A slow/incomplete client can delay the single owner thread at most ~200ms. */
static long long monotonic_millis(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (long long)now.tv_sec * 1000LL + now.tv_nsec / 1000000LL;
}

long andesite_local_http_read_headers(int client, char *buffer, unsigned long capacity) {
    if (client < 0 || !buffer || capacity < 4 || capacity > 65536) { errno = EINVAL; return -1; }
    long long started = monotonic_millis();
    if (started < 0) return -1;
    size_t used = 0;
    struct pollfd pollfd = {.fd = client, .events = POLLIN, .revents = 0};
    // Absolute deadline: dribbling one byte per poll cannot stall the scanner.
    while (used < capacity) {
        long long remaining = 200 - (monotonic_millis() - started);
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        int ready = poll(&pollfd, 1, (int)remaining);
        if (ready <= 0) { errno = ready == 0 ? ETIMEDOUT : errno; return -1; }
        ssize_t count = recv(client, buffer + used, capacity - used, MSG_DONTWAIT);
        if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (count <= 0) { errno = count == 0 ? ECONNRESET : errno; return -1; }
        used += (size_t)count;
        for (size_t i = 3; i < used; ++i) {
            if (buffer[i-3] == '\r' && buffer[i-2] == '\n' &&
                buffer[i-1] == '\r' && buffer[i] == '\n') {
                if (i + 1 != used) { errno = EINVAL; return -1; }
                return (long)used;
            }
        }
    }
    errno = EMSGSIZE;
    return -1;
}


/* GET keeps the existing header-only contract; PUT/POST carry at most
   256 KiB of Markdown or replication JSON under an absolute deadline.
   The Swift decoder independently validates every header and byte count. */
long andesite_local_http_read_request(int client, char *buffer,
                                     unsigned long capacity) {
    if (client < 0 || !buffer || capacity < 8192 + 262144 ||
        capacity > 1048576) { errno = EINVAL; return -1; }
    long long started = monotonic_millis();
    if (started < 0) return -1;
    size_t used = 0, header_end = 0, expected = 0;
    int has_body = -1;
    struct pollfd pending = {.fd = client, .events = POLLIN, .revents = 0};
    while (used < capacity) {
        long long remaining = (header_end ? 1200 : 200) -
                              (monotonic_millis() - started);
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        int ready = poll(&pending, 1, (int)remaining);
        if (ready <= 0) { errno = ready == 0 ? ETIMEDOUT : errno; return -1; }
        ssize_t n = recv(client, buffer + used, capacity - used, MSG_DONTWAIT);
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (n <= 0) { errno = n == 0 ? ECONNRESET : errno; return -1; }
        used += (size_t)n;
        if (!header_end) {
            // The first recv may contain headers AND a complete body.
            // Locate the terminator before judging the 8 KiB header cap.
            for (size_t i = 3; i < used; i++) {
                if (buffer[i-3] == '\r' && buffer[i-2] == '\n' &&
                    buffer[i-1] == '\r' && buffer[i] == '\n') {
                    header_end = i + 1;
                    break;
                }
            }
            if (!header_end) {
                if (used > 8192) { errno = EMSGSIZE; return -1; }
                continue;
            }
            if (header_end > 8192) { errno = EMSGSIZE; return -1; }
            has_body = (header_end >= 4 && memcmp(buffer, "PUT ", 4) == 0) ||
                       (header_end >= 5 && memcmp(buffer, "POST ", 5) == 0);
            if (has_body) {
                int matched = 0;
                size_t offset = 0;
                while (offset + 1 < header_end) {
                    size_t ending = offset;
                    while (ending + 1 < header_end &&
                           !(buffer[ending] == '\r' && buffer[ending+1] == '\n')) {
                        ending++;
                    }
                    if (ending + 1 >= header_end) { errno = EINVAL; return -1; }
                    size_t line_length = ending - offset;
                    const char *line = buffer + offset;
                    if (line_length >= 15 && strncasecmp(line, "Content-Length:", 15) == 0) {
                        if (matched++) { errno = EINVAL; return -1; }
                        size_t start = 15;
                        while (start < line_length && (line[start] == ' ' || line[start] == '\t')) start++;
                        if (start == line_length) { errno = EINVAL; return -1; }
                        size_t value = 0;
                        for (size_t j = start; j < line_length; j++) {
                            if (line[j] < '0' || line[j] > '9') {
                                errno = EINVAL; return -1;
                            }
                            value = value * 10 + (size_t)(line[j] - '0');
                            if (value > 262144) { errno = EMSGSIZE; return -1; }
                        }
                        expected = value;
                    }
                    offset = ending + 2;
                }
                // A POST without a body length can still receive the
                // correct 405 for a disallowed route in the Swift decoder.
                // Accepted replication POSTs require the length there.
                if (matched != 1 && memcmp(buffer, "POST ", 5) != 0) {
                    errno = EINVAL; return -1;
                }
            }
        }
        if (header_end) {
            if (used > header_end + expected) { errno = EINVAL; return -1; }
            if (used == header_end + expected) return (long)used;
        }
    }
    errno = EMSGSIZE;
    return -1;
}

void andesite_local_http_close(andesite_local_http *server) {
    if (!server) return;
    close(server->listener);
    struct stat current;
    if (lstat(server->path, &current) == 0 && S_ISSOCK(current.st_mode) &&
        current.st_uid == geteuid() && current.st_dev == server->device &&
        current.st_ino == server->inode) {
        unlink(server->path);
    }
    free(server->path);
    free(server);
}
#endif

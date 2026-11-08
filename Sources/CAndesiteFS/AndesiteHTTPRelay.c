#include "AndesiteFS.h"
#ifdef __APPLE__
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stddef.h>

/* The caller checks the HTTP route and query against an allowlist.
   This is intentionally GET-only: no upload/restore/cleanup relay exists. */
int andesite_http_relay_get(const char *socket_path, const char *target,
                           unsigned char *out, unsigned long capacity,
                           unsigned long *length) {
    if (!socket_path || !target || !out || !length || capacity < 512) {
        errno = EINVAL; return -1;
    }
    *length = 0;
    size_t target_len = strlen(target);
    if (target_len == 0 || target_len > 4096 || target[0] != '/') {
        errno = EINVAL; return -1;
    }
    for (size_t i = 0; i < target_len; i++) {
        unsigned char c = (unsigned char)target[i];
        if (c <= 32 || c >= 127 || c == '\\') {
            errno = EINVAL; return -1;
        }
    }
    struct stat info;
    if (lstat(socket_path, &info) != 0 || !S_ISSOCK(info.st_mode) ||
        info.st_uid != geteuid() || (info.st_mode & 0077)) {
        errno = EPERM; return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    size_t len = strlen(socket_path);
    if (len >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
    memcpy(addr.sun_path, socket_path, len + 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int result = -1;
    struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int ignore_sigpipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &ignore_sigpipe, sizeof(ignore_sigpipe));
    socklen_t addr_len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + len + 1);
    if (connect(fd, (struct sockaddr *)&addr, addr_len) != 0) goto finish;
    char header[4300];
    int bytes = snprintf(header, sizeof(header),
                         "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", target);
    if (bytes < 0 || bytes >= (int)sizeof(header)) { errno = EMSGSIZE; goto finish; }
    size_t sent = 0;
    while (sent < (size_t)bytes) {
        ssize_t n = send(fd, header + sent, (size_t)bytes - sent, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) goto finish;
        sent += (size_t)n;
    }
    size_t count = 0;
    while (count < capacity) {
        ssize_t n = recv(fd, out + count, capacity - count, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) goto finish;
        if (n == 0) {
            if (count == 0) { errno = EIO; goto finish; }
            *length = count;
            result = 0;
            goto finish;
        }
        count += (size_t)n;
    }
    /* Bound the entire response; no truncation is reported as successful. */
    errno = EMSGSIZE;
finish:
    close(fd);
    return result;
}
#endif

/* Only the authenticated sidecar invokes this narrow PUT operation. It
   forwards exactly one version-conditioned Markdown replacement, never an
   arbitrary header, file path, method or SQL statement. */
int andesite_http_relay_put(const char *socket_path, const char *target,
                           const char *revision, const unsigned char *body,
                           unsigned long body_length, unsigned char *out,
                           unsigned long capacity, unsigned long *length) {
    if (!socket_path || !target || !revision || !out || !length ||
        capacity < 512 || body_length > 262144 ||
        (body_length > 0 && !body)) { errno = EINVAL; return -1; }
    *length = 0;
    size_t target_len = strlen(target), revision_len = strlen(revision);
    if (target_len < 15 || target_len > 4096 || revision_len != 32 ||
        strncmp(target, "/v1/documents/", 14) != 0) {
        errno = EINVAL; return -1;
    }
    for (size_t i = 0; i < target_len; i++) {
        unsigned char c = (unsigned char)target[i];
        if (c <= 32 || c >= 127 || c == '\\') {
            errno = EINVAL; return -1;
        }
    }
    for (size_t i = 0; i < revision_len; i++) {
        unsigned char c = (unsigned char)revision[i];
        if (!((c >= '0' && c <= '9') ||
              (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
            errno = EINVAL; return -1;
        }
    }
    struct stat info;
    if (lstat(socket_path, &info) != 0 || !S_ISSOCK(info.st_mode) ||
        info.st_uid != geteuid() || (info.st_mode & 0077)) {
        errno = EPERM; return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    size_t length_path = strlen(socket_path);
    if (length_path >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
    memcpy(addr.sun_path, socket_path, length_path + 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int result = -1;
    struct timeval send_timeout = {.tv_sec = 2, .tv_usec = 0};
    struct timeval receive_timeout = {.tv_sec = 10, .tv_usec = 0};
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof(send_timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive_timeout, sizeof(receive_timeout));
    int ignore_sigpipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &ignore_sigpipe, sizeof(ignore_sigpipe));
    if (connect(fd, (struct sockaddr *)&addr,
                (socklen_t)(offsetof(struct sockaddr_un, sun_path) + length_path + 1)) != 0) goto finish;
    char header[4400];
    int size = snprintf(header, sizeof(header),
                        "PUT %s HTTP/1.1\r\nHost: localhost\r\n"
                        "If-Match: \"%s\"\r\n"
                        "Content-Type: text/markdown; charset=utf-8\r\n"
                        "Content-Length: %lu\r\nConnection: close\r\n\r\n",
                        target, revision, body_length);
    if (size < 0 || size >= (int)sizeof(header)) { errno = EMSGSIZE; goto finish; }
    size_t offset = 0;
    while (offset < (size_t)size) {
        ssize_t n = send(fd, header + offset, (size_t)size - offset, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) goto finish;
        offset += (size_t)n;
    }
    offset = 0;
    while (offset < body_length) {
        ssize_t n = send(fd, body + offset, body_length - offset, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) goto finish;
        offset += (size_t)n;
    }
    size_t count = 0;
    while (count < capacity) {
        ssize_t n = recv(fd, out + count, capacity - count, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) goto finish;
        if (n == 0) {
            if (count == 0) { errno = EIO; goto finish; }
            *length = count;
            result = 0;
            goto finish;
        }
        count += (size_t)n;
    }
    errno = EMSGSIZE;
finish:
    close(fd);
    return result;
}

int andesite_http_relay_sync_post(const char *socket_path, const char *target,
                           const unsigned char *body,
                           unsigned long body_length, unsigned char *out,
                           unsigned long capacity, unsigned long *length) {
    if (!socket_path || !target || !out || !length ||
        capacity < 512 || body_length > 262144 ||
        (body_length > 0 && !body)) { errno = EINVAL; return -1; }
    *length = 0;
    size_t target_len = strlen(target);
    if (!(strcmp(target, "/v1/sync/changes") == 0 ||
          strcmp(target, "/v1/sync/snapshots") == 0)) {
        errno = EINVAL; return -1;
    }
    for (size_t i = 0; i < target_len; i++) {
        unsigned char c = (unsigned char)target[i];
        if (c <= 32 || c >= 127 || c == '\\') {
            errno = EINVAL; return -1;
        }
    }
    struct stat info;
    if (lstat(socket_path, &info) != 0 || !S_ISSOCK(info.st_mode) ||
        info.st_uid != geteuid() || (info.st_mode & 0077)) {
        errno = EPERM; return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    size_t length_path = strlen(socket_path);
    if (length_path >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
    memcpy(addr.sun_path, socket_path, length_path + 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int result = -1;
    struct timeval send_timeout = {.tv_sec = 2, .tv_usec = 0};
    struct timeval receive_timeout = {.tv_sec = 10, .tv_usec = 0};
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof(send_timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive_timeout, sizeof(receive_timeout));
    int ignore_sigpipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &ignore_sigpipe, sizeof(ignore_sigpipe));
    if (connect(fd, (struct sockaddr *)&addr,
                (socklen_t)(offsetof(struct sockaddr_un, sun_path) + length_path + 1)) != 0) goto finish;
    char header[4400];
    int size = snprintf(header, sizeof(header),
                        "POST %s HTTP/1.1\r\nHost: localhost\r\n"
                        "Content-Type: application/json; charset=utf-8\r\n"
                        "Content-Length: %lu\r\nConnection: close\r\n\r\n",
                        target, body_length);
    if (size < 0 || size >= (int)sizeof(header)) { errno = EMSGSIZE; goto finish; }
    size_t offset = 0;
    while (offset < (size_t)size) {
        ssize_t n = send(fd, header + offset, (size_t)size - offset, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) goto finish;
        offset += (size_t)n;
    }
    offset = 0;
    while (offset < body_length) {
        ssize_t n = send(fd, body + offset, body_length - offset, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) goto finish;
        offset += (size_t)n;
    }
    size_t count = 0;
    while (count < capacity) {
        ssize_t n = recv(fd, out + count, capacity - count, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) goto finish;
        if (n == 0) {
            if (count == 0) { errno = EIO; goto finish; }
            *length = count;
            result = 0;
            goto finish;
        }
        count += (size_t)n;
    }
    errno = EMSGSIZE;
finish:
    close(fd);
    return result;
}

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

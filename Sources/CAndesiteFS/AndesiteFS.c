#define _GNU_SOURCE
#include "AndesiteFS.h"
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <copyfile.h>
#include <sys/mount.h>

int andesite_supported_filesystem(int directory) {
    struct statfs info;
    // Durable rename/exchange semantics are only assumed for local volumes.
    return fstatfs(directory, &info) == 0 && (info.f_flags & MNT_LOCAL);
}
int andesite_exchange(int directory_a, const char *a, int directory_b, const char *b) {
    return renameatx_np(directory_a, a, directory_b, b, RENAME_SWAP);
}
int andesite_rename_noreplace(int from_directory, const char *from, int to_directory, const char *to) {
    return renameatx_np(from_directory, from, to_directory, to, RENAME_EXCL);
}
int andesite_copy_metadata(int source, int destination) {
    return fcopyfile(source, destination, NULL, COPYFILE_METADATA);
}
#else
#include <sys/syscall.h>
#include <sys/vfs.h>
#include <sys/xattr.h>
#include <linux/fs.h>
#include <stdlib.h>
#include <string.h>
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif
#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1 << 1)
#endif

int andesite_supported_filesystem(int directory) {
    struct statfs info;
    if (fstatfs(directory, &info) != 0) return 0;
    // Refuse network filesystems (NFS, SMB/CIFS) whose rename semantics differ.
    switch ((unsigned long)info.f_type) {
    case 0x6969UL: case 0xFF534D42UL: case 0xFE534D42UL: case 0x517BUL: return 0;
    default: return 1;
    }
}
int andesite_exchange(int directory_a, const char *a, int directory_b, const char *b) {
    return (int)syscall(SYS_renameat2, directory_a, a, directory_b, b, RENAME_EXCHANGE);
}
int andesite_rename_noreplace(int from_directory, const char *from, int to_directory, const char *to) {
    return (int)syscall(SYS_renameat2, from_directory, from, to_directory, to, RENAME_NOREPLACE);
}
int andesite_copy_metadata(int source, int destination) {
    // Mode and extended attributes. Ownership is unchanged: both files are
    // created by the same user in the same directory.
    struct stat info;
    if (fstat(source, &info) != 0 || fchmod(destination, info.st_mode & 07777) != 0) return -1;
    ssize_t size = flistxattr(source, NULL, 0);
    if (size < 0) return (errno == ENOTSUP) ? 0 : -1;
    if (size == 0) return 0;
    char *names = malloc((size_t)size);
    if (!names) return -1;
    size = flistxattr(source, names, (size_t)size);
    int result = 0;
    for (ssize_t offset = 0; size > 0 && offset < size; offset += (ssize_t)strlen(names + offset) + 1) {
        const char *name = names + offset;
        ssize_t length = fgetxattr(source, name, NULL, 0);
        if (length < 0) { result = -1; break; }
        char *value = malloc(length > 0 ? (size_t)length : 1);
        if (!value) { result = -1; break; }
        length = fgetxattr(source, name, value, (size_t)length);
        if (length < 0 || fsetxattr(destination, name, value, (size_t)length, 0) != 0) {
            // Security labels may be unsettable by an ordinary user; skip them.
            if (strncmp(name, "security.", 9) != 0) result = -1;
        }
        free(value);
        if (result != 0) break;
    }
    free(names);
    return result;
}
#endif

#define _GNU_SOURCE
#include "AndesiteFS.h"
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <stdio.h>
#include <copyfile.h>
int andesite_exchange(int directory, const char *stage, const char *target) {
    return renameatx_np(directory, stage, directory, target, RENAME_SWAP);
}
int andesite_copy_metadata(int source, int destination) {
    return fcopyfile(source, destination, NULL, COPYFILE_METADATA);
}
#else
#include <sys/syscall.h>
#include <linux/fs.h>
int andesite_exchange(int directory, const char *stage, const char *target) {
    return syscall(SYS_renameat2, directory, stage, directory, target, RENAME_EXCHANGE);
}
int andesite_copy_metadata(int source, int destination) {
    // Linux ACL/xattr/label preservation is not yet qualified. Fail closed rather
    // than silently dropping metadata. Read-only observation/export still works.
    (void)source; (void)destination; errno = ENOTSUP; return -1;
}
#endif

#ifndef ANDESITE_FS_H
#define ANDESITE_FS_H
int andesite_supported_filesystem(int directory);
int andesite_exchange(int directory, const char *stage, const char *target);
int andesite_copy_metadata(int source, int destination);
#endif

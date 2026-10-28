#ifndef LULIBRE_MD5_H
#define LULIBRE_MD5_H

/* MD5 of a file's contents as 32 hex digits. Returns 0, or -1 with errno
 * set when the file cannot be read. */
int md5_file(const char *path, char hex[33]);

#endif

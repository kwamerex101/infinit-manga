#pragma once

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// Public libarchive read APIs exported by the iOS SDK's libarchive.
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
const char *archive_entry_pathname(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);

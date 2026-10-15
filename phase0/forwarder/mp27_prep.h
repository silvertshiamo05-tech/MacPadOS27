// mp27_prep.h - see mp27_prep.c
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MP27_PREP_VERSION "1"

typedef void (*mp27_log_fn)(const char *fmt, ...);

typedef struct {
    int files_seen, files_patched;
    int textures_converted, textures_skipped;
    uint64_t bytes_written;
} mp27_prep_stats;

// Prepares <data_dir> (a Unity "Data" folder) in place. Returns 0 on success
// (or if already prepared), -1 if no Unity data was found.
int mp27_prepare_data(const char *data_dir, mp27_log_fn log, mp27_prep_stats *stats);

#ifdef __cplusplus
}
#endif

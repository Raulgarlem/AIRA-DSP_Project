#ifndef AIRA_DAS_LOCALIZER_H
#define AIRA_DAS_LOCALIZER_H

#include <stddef.h>

#define DAS_MICROPHONES 3
#define DAS_FRAME_LENGTH 1024
#define DAS_HOP_LENGTH 512
#define DAS_ANGLE_COUNT 360
#define DAS_MAX_SOURCES 4

typedef struct das_localizer das_localizer_t;

typedef struct {
    unsigned long long frame_index;
    double start_time_s;
    double end_time_s;
    int source_count;
    int angles_deg[DAS_MAX_SOURCES];
    int use_snr_mask;
    double confidence;
} das_result_t;

das_localizer_t *das_localizer_create(
    unsigned int sample_rate,
    double microphone_distance_m,
    int source_count);

void das_localizer_destroy(das_localizer_t *localizer);

int das_localizer_process_hop(
    das_localizer_t *localizer,
    const float samples[DAS_MICROPHONES][DAS_HOP_LENGTH],
    das_result_t *result);

#endif

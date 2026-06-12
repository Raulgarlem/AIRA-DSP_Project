#ifndef AIRA_DAS_LOCALIZER_H
#define AIRA_DAS_LOCALIZER_H

#include <stddef.h>

#define DAS_MICROPHONES 3
#define DAS_FRAME_LENGTH 1024
#define DAS_HOP_LENGTH 512
#define DAS_ANGLE_COUNT 360
#define DAS_MAX_SOURCES 4

typedef struct das_localizer das_localizer_t;

typedef enum {
    DAS_METHOD_ADAPTIVE = 0,
    DAS_METHOD_SRP_PHAT = 1
} das_method_t;

typedef struct {
    unsigned long long frame_index;
    double start_time_s;
    double end_time_s;
    int source_count;
    int angles_deg[DAS_MAX_SOURCES];
    das_method_t method;
    int use_snr_mask;
    int stability_ready;
    int stable;
    int stability_measurements;
    int maximum_variation_deg;
    int consecutive_stable_states;
    double first_stable_time_s;
} das_result_t;

das_localizer_t *das_localizer_create(
    unsigned int sample_rate,
    double microphone_distance_m,
    int source_count,
    das_method_t method);

void das_localizer_destroy(das_localizer_t *localizer);

int das_localizer_process_hop(
    das_localizer_t *localizer,
    float samples[DAS_MICROPHONES][DAS_HOP_LENGTH],
    das_result_t *result);

#endif

#include "das_localizer.h"

#include <complex.h>
#include <fftw3.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define DAS_SOUND_SPEED 343.0
#define DAS_MIN_FREQUENCY_HZ 300.0
#define DAS_MAX_FREQUENCY_HZ 4000.0
#define DAS_MIN_PEAK_SEPARATION_DEG 20
#define DAS_NOISE_HISTORY 30
#define DAS_DECISION_INTERVAL 3
#define DAS_DECISION_WARMUP 12
#define DAS_SWITCH_CONFIRMATIONS 2

struct das_localizer {
    unsigned int sample_rate;
    int source_count;
    int selected_bin_count;
    int first_bin;
    int last_bin;
    int history_count;
    int history_position;
    int current_mode_snr;
    int pending_mode_snr;
    int pending_count;
    unsigned long long frame_index;
    double window[DAS_FRAME_LENGTH];
    double frame[DAS_MICROPHONES][DAS_FRAME_LENGTH];
    double fft_input[DAS_FRAME_LENGTH];
    fftw_complex fft_output[DAS_FRAME_LENGTH / 2 + 1];
    fftw_plan fft_plan;
    double complex spectra[DAS_MICROPHONES][DAS_FRAME_LENGTH / 2 + 1];
    double power_smooth[DAS_FRAME_LENGTH / 2 + 1];
    double power_history[DAS_NOISE_HISTORY][DAS_FRAME_LENGTH / 2 + 1];
    double complex *steering;
    double base_spectrum[DAS_ANGLE_COUNT];
    double snr_spectrum[DAS_ANGLE_COUNT];
};

static int angular_distance(int a, int b)
{
    int distance = abs(a - b) % 360;
    return distance > 180 ? 360 - distance : distance;
}

static double spatial_confidence(
    const double spectrum[DAS_ANGLE_COUNT],
    const int peaks[DAS_MAX_SOURCES],
    int peak_count)
{
    double maximum = 0.0;
    double minimum_peak = 1e300;
    double mean = 0.0;
    int angle;

    for (angle = 0; angle < DAS_ANGLE_COUNT; ++angle) {
        mean += spectrum[angle];
        if (spectrum[angle] > maximum) {
            maximum = spectrum[angle];
        }
    }
    mean /= DAS_ANGLE_COUNT;

    for (angle = 0; angle < peak_count; ++angle) {
        double value = spectrum[peaks[angle] + 180];
        if (value < minimum_peak) {
            minimum_peak = value;
        }
    }
    if (peak_count == 0 || maximum <= 0.0) {
        return 0.0;
    }
    return (minimum_peak / maximum) * (maximum / (mean + 1e-12));
}

static int find_peaks(
    const double spectrum[DAS_ANGLE_COUNT],
    int source_count,
    int peaks[DAS_MAX_SOURCES])
{
    int selected = 0;
    int angle;

    while (selected < source_count) {
        int best_angle = 0;
        double best_value = -1.0;

        for (angle = -180; angle < 180; ++angle) {
            int index = angle + 180;
            int previous = (index + DAS_ANGLE_COUNT - 1) % DAS_ANGLE_COUNT;
            int next = (index + 1) % DAS_ANGLE_COUNT;
            int allowed = 1;
            int peak_id;

            if (spectrum[index] < spectrum[previous] ||
                spectrum[index] < spectrum[next]) {
                continue;
            }
            for (peak_id = 0; peak_id < selected; ++peak_id) {
                if (angular_distance(angle, peaks[peak_id]) <
                    DAS_MIN_PEAK_SEPARATION_DEG) {
                    allowed = 0;
                    break;
                }
            }
            if (allowed && spectrum[index] > best_value) {
                best_value = spectrum[index];
                best_angle = angle;
            }
        }
        if (best_value < 0.0) {
            break;
        }
        peaks[selected++] = best_angle;
    }

    for (angle = 0; angle + 1 < selected; ++angle) {
        int other;
        for (other = angle + 1; other < selected; ++other) {
            if (peaks[other] < peaks[angle]) {
                int temporary = peaks[angle];
                peaks[angle] = peaks[other];
                peaks[other] = temporary;
            }
        }
    }
    return selected;
}

static double complex *steering_at(
    das_localizer_t *localizer,
    int selected_bin,
    int angle_index,
    int microphone)
{
    size_t index = ((size_t)selected_bin * DAS_ANGLE_COUNT +
                    (size_t)angle_index) * DAS_MICROPHONES +
                   (size_t)microphone;
    return &localizer->steering[index];
}

das_localizer_t *das_localizer_create(
    unsigned int sample_rate,
    double microphone_distance_m,
    int source_count)
{
    das_localizer_t *localizer;
    double positions[DAS_MICROPHONES][2] = {
        {0.0, 0.0},
        {-microphone_distance_m, 0.0},
        {-microphone_distance_m / 2.0,
         -sqrt(3.0) * microphone_distance_m / 2.0}
    };
    double center_x = 0.0;
    double center_y = 0.0;
    int microphone;
    int bin;
    int angle;

    if (sample_rate == 0 || microphone_distance_m <= 0.0 ||
        source_count < 1 || source_count > DAS_MAX_SOURCES) {
        return NULL;
    }

    localizer = calloc(1, sizeof(*localizer));
    if (localizer == NULL) {
        return NULL;
    }
    localizer->sample_rate = sample_rate;
    localizer->source_count = source_count;
    localizer->first_bin = (int)ceil(
        DAS_MIN_FREQUENCY_HZ * DAS_FRAME_LENGTH / sample_rate);
    localizer->last_bin = (int)floor(
        DAS_MAX_FREQUENCY_HZ * DAS_FRAME_LENGTH / sample_rate);
    localizer->selected_bin_count =
        localizer->last_bin - localizer->first_bin + 1;

    localizer->fft_plan = fftw_plan_dft_r2c_1d(
        DAS_FRAME_LENGTH,
        localizer->fft_input,
        localizer->fft_output,
        FFTW_ESTIMATE);
    if (localizer->fft_plan == NULL) {
        das_localizer_destroy(localizer);
        return NULL;
    }

    localizer->steering = calloc(
        (size_t)localizer->selected_bin_count *
            DAS_ANGLE_COUNT * DAS_MICROPHONES,
        sizeof(*localizer->steering));
    if (localizer->steering == NULL) {
        das_localizer_destroy(localizer);
        return NULL;
    }

    for (bin = 0; bin < DAS_FRAME_LENGTH; ++bin) {
        localizer->window[bin] =
            0.5 - 0.5 * cos(2.0 * M_PI * bin / DAS_FRAME_LENGTH);
    }

    for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
        center_x += positions[microphone][0] / DAS_MICROPHONES;
        center_y += positions[microphone][1] / DAS_MICROPHONES;
    }
    for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
        positions[microphone][0] -= center_x;
        positions[microphone][1] -= center_y;
    }

    for (bin = localizer->first_bin; bin <= localizer->last_bin; ++bin) {
        int selected_bin = bin - localizer->first_bin;
        double frequency = (double)bin * sample_rate / DAS_FRAME_LENGTH;
        for (angle = -180; angle < 180; ++angle) {
            double radians = angle * M_PI / 180.0;
            double direction_x = sin(radians);
            double direction_y = cos(radians);
            for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
                double delay = -(
                    positions[microphone][0] * direction_x +
                    positions[microphone][1] * direction_y) /
                    DAS_SOUND_SPEED;
                *steering_at(
                    localizer, selected_bin, angle + 180, microphone) =
                    cexp(-I * 2.0 * M_PI * frequency * delay);
            }
        }
    }
    return localizer;
}

void das_localizer_destroy(das_localizer_t *localizer)
{
    if (localizer == NULL) {
        return;
    }
    if (localizer->fft_plan != NULL) {
        fftw_destroy_plan(localizer->fft_plan);
    }
    free(localizer->steering);
    free(localizer);
}

int das_localizer_process_hop(
    das_localizer_t *localizer,
    const float samples[DAS_MICROPHONES][DAS_HOP_LENGTH],
    das_result_t *result)
{
    double weights[DAS_FRAME_LENGTH / 2 + 1] = {0.0};
    double weight_sum = 0.0;
    int active_bins = 0;
    int base_peaks[DAS_MAX_SOURCES] = {0};
    int snr_peaks[DAS_MAX_SOURCES] = {0};
    int microphone;
    int sample;
    int bin;
    int angle;

    if (localizer == NULL || samples == NULL || result == NULL) {
        return 0;
    }

    for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
        memmove(
            localizer->frame[microphone],
            localizer->frame[microphone] + DAS_HOP_LENGTH,
            DAS_HOP_LENGTH * sizeof(double));
        for (sample = 0; sample < DAS_HOP_LENGTH; ++sample) {
            localizer->frame[microphone][DAS_HOP_LENGTH + sample] =
                samples[microphone][sample];
        }
    }
    ++localizer->frame_index;
    if (localizer->frame_index < 2) {
        return 0;
    }

    for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
        for (sample = 0; sample < DAS_FRAME_LENGTH; ++sample) {
            localizer->fft_input[sample] =
                localizer->frame[microphone][sample] *
                localizer->window[sample];
        }
        fftw_execute(localizer->fft_plan);
        for (bin = localizer->first_bin; bin <= localizer->last_bin; ++bin) {
            localizer->spectra[microphone][bin] =
                localizer->fft_output[bin][0] +
                I * localizer->fft_output[bin][1];
        }
    }

    for (bin = localizer->first_bin; bin <= localizer->last_bin; ++bin) {
        double power = 0.0;
        double noise_floor = 1e300;
        double ratio;
        int history;

        for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
            double magnitude = cabs(localizer->spectra[microphone][bin]);
            power += magnitude * magnitude / DAS_MICROPHONES;
        }
        if (localizer->history_count == 0) {
            localizer->power_smooth[bin] = power;
        } else {
            localizer->power_smooth[bin] =
                0.7 * localizer->power_smooth[bin] + 0.3 * power;
        }
        localizer->power_history[localizer->history_position][bin] =
            localizer->power_smooth[bin];
        for (history = 0; history < localizer->history_count + 1; ++history) {
            double value = localizer->power_history[history][bin];
            if (value < noise_floor) {
                noise_floor = value;
            }
        }
        ratio = localizer->power_smooth[bin] / (noise_floor + 1e-12);
        weights[bin] = fmax(0.0, 1.0 - pow(10.0, 0.6) / (ratio + 1e-12));
        weight_sum += weights[bin];
        if (weights[bin] > 0.0) {
            ++active_bins;
        }
    }
    localizer->history_position =
        (localizer->history_position + 1) % DAS_NOISE_HISTORY;
    if (localizer->history_count < DAS_NOISE_HISTORY - 1) {
        ++localizer->history_count;
    }

    memset(localizer->base_spectrum, 0, sizeof(localizer->base_spectrum));
    memset(localizer->snr_spectrum, 0, sizeof(localizer->snr_spectrum));
    for (bin = localizer->first_bin; bin <= localizer->last_bin; ++bin) {
        int selected_bin = bin - localizer->first_bin;
        for (angle = 0; angle < DAS_ANGLE_COUNT; ++angle) {
            double complex beam = 0.0;
            double beam_power;
            for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
                beam += conj(*steering_at(
                            localizer, selected_bin, angle, microphone)) *
                        localizer->spectra[microphone][bin];
            }
            beam_power =
                creal(beam * conj(beam)) /
                (DAS_MICROPHONES * DAS_MICROPHONES);
            localizer->base_spectrum[angle] += beam_power;
            localizer->snr_spectrum[angle] += weights[bin] * beam_power;
        }
    }

    find_peaks(
        localizer->base_spectrum, localizer->source_count, base_peaks);
    find_peaks(
        localizer->snr_spectrum, localizer->source_count, snr_peaks);

    if (localizer->frame_index > DAS_DECISION_WARMUP &&
        localizer->frame_index % DAS_DECISION_INTERVAL == 0) {
        double base_confidence = spatial_confidence(
            localizer->base_spectrum, base_peaks, localizer->source_count);
        double snr_confidence = spatial_confidence(
            localizer->snr_spectrum, snr_peaks, localizer->source_count);
        int mask_valid =
            active_bins >= 20 &&
            weight_sum / localizer->selected_bin_count >= 0.15;
        int requested_mode =
            mask_valid && snr_confidence > 1.05 * base_confidence;

        if (requested_mode == localizer->current_mode_snr) {
            localizer->pending_count = 0;
        } else if (requested_mode == localizer->pending_mode_snr) {
            ++localizer->pending_count;
        } else {
            localizer->pending_mode_snr = requested_mode;
            localizer->pending_count = 1;
        }
        if (localizer->pending_count >= DAS_SWITCH_CONFIRMATIONS) {
            localizer->current_mode_snr = requested_mode;
            localizer->pending_count = 0;
        }
    }

    memset(result, 0, sizeof(*result));
    result->frame_index = localizer->frame_index - 1;
    result->start_time_s =
        (double)((localizer->frame_index - 2) * DAS_HOP_LENGTH) /
        localizer->sample_rate;
    result->end_time_s =
        result->start_time_s +
        (double)DAS_FRAME_LENGTH / localizer->sample_rate;
    result->source_count = localizer->source_count;
    result->use_snr_mask = localizer->current_mode_snr;
    if (result->use_snr_mask) {
        memcpy(
            result->angles_deg,
            snr_peaks,
            (size_t)localizer->source_count * sizeof(int));
        result->confidence = spatial_confidence(
            localizer->snr_spectrum, snr_peaks, localizer->source_count);
    } else {
        memcpy(
            result->angles_deg,
            base_peaks,
            (size_t)localizer->source_count * sizeof(int));
        result->confidence = spatial_confidence(
            localizer->base_spectrum, base_peaks, localizer->source_count);
    }
    return 1;
}

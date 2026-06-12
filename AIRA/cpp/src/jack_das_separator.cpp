#define EIGEN_RUNTIME_NO_MALLOC

#include <Eigen/Dense>
#include <fftw3.h>
#include <jack/jack.h>
#include <cmath>
#include <complex>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define MICROPHONES 3
#define MAX_SOURCES 3
#define FRAME_LENGTH 1024
#define HOP_LENGTH 512
#define FFT_BINS (FRAME_LENGTH / 2 + 1)
#define SOUND_SPEED 343.0
#define OUTPUT_QUEUE_CAPACITY 8192
#define COVARIANCE_SMOOTHING 0.98
#define LCMV_DIAGONAL_LOADING 0.10
#define LCMV_MIN_FREQUENCY_HZ 300.0
#define LCMV_MAX_FREQUENCY_HZ 4000.0
#define LCMV_COVARIANCE_WARMUP_FRAMES 20
#define LCMV_WEIGHT_SMOOTHING 0.90
#define LCMV_MAX_WEIGHT_NORM 2.0

using Complex = std::complex<double>;
using Matrix3c = Eigen::Matrix<Complex, MICROPHONES, MICROPHONES>;
using Vector3c = Eigen::Matrix<Complex, MICROPHONES, 1>;

typedef enum {
    SEPARATION_DAS = 0,
    SEPARATION_LCMV = 1
} separation_method_t;

typedef struct {
    jack_client_t *client;
    jack_port_t *input_ports[MICROPHONES];
    jack_port_t *output_ports[MAX_SOURCES];
    unsigned int sample_rate;
    int source_count;
    separation_method_t method;
    int hop_samples;
    double input_frame[MICROPHONES][FRAME_LENGTH];
    double window[FRAME_LENGTH];
    double overlap[MAX_SOURCES][FRAME_LENGTH];
    double normalization[FRAME_LENGTH];
    double output_queue[MAX_SOURCES][OUTPUT_QUEUE_CAPACITY];
    unsigned int output_read;
    unsigned int output_write;
    double fft_input[FRAME_LENGTH];
    fftw_complex fft_output[FFT_BINS];
    fftw_complex inverse_input[FFT_BINS];
    double inverse_output[FRAME_LENGTH];
    fftw_plan forward_plan;
    fftw_plan inverse_plan;
    Complex spectra[MICROPHONES][FFT_BINS];
    Complex steering[MAX_SOURCES][MICROPHONES][FFT_BINS];
    Matrix3c covariance[FFT_BINS];
    Matrix3c lcmv_weights[FFT_BINS];
    unsigned char lcmv_valid_sources[FFT_BINS];
    Complex previous_weights
        [MAX_SOURCES][FFT_BINS][MICROPHONES];
    unsigned int covariance_frames;
} separator_t;

static volatile sig_atomic_t running = 1;

static void stop_handler(int signal_number)
{
    (void)signal_number;
    running = 0;
}

static void jack_shutdown(void *argument)
{
    (void)argument;
    running = 0;
}

static unsigned int queue_next(unsigned int index)
{
    return (index + 1U) % OUTPUT_QUEUE_CAPACITY;
}

static void das_weights(
    const separator_t *separator,
    int source,
    int bin,
    Vector3c *weights)
{
    int microphone;

    for (microphone = 0; microphone < MICROPHONES; ++microphone) {
        (*weights)(microphone) =
            separator->steering[source][microphone][bin] /
            static_cast<double>(MICROPHONES);
    }
}

template <int Constraints>
static unsigned char solve_lcmv_weight_matrix(
    const Eigen::LDLT<Matrix3c> &covariance_solver,
    const Eigen::Matrix<Complex, MICROPHONES, Constraints> &constraints,
    Matrix3c *weights)
{
    using ConstraintMatrix =
        Eigen::Matrix<Complex, Constraints, Constraints>;
    using WeightMatrix =
        Eigen::Matrix<Complex, MICROPHONES, Constraints>;
    Eigen::Matrix<Complex, MICROPHONES, Constraints>
        inverse_times_constraints =
            covariance_solver.solve(constraints);
    ConstraintMatrix gram =
        constraints.adjoint() * inverse_times_constraints;
    Eigen::LDLT<ConstraintMatrix> gram_solver(gram);
    WeightMatrix active_weights;
    unsigned char valid_sources = 0;
    int source;

    if (gram_solver.info() != Eigen::Success ||
        !inverse_times_constraints.allFinite()) {
        return 0;
    }
    active_weights = inverse_times_constraints * gram_solver.solve(
        ConstraintMatrix::Identity());
    if (gram_solver.info() != Eigen::Success ||
        !active_weights.allFinite()) {
        return 0;
    }
    weights->setZero();
    weights->template leftCols<Constraints>() = active_weights;
    for (source = 0; source < Constraints; ++source) {
        if (active_weights.col(source).norm() <= LCMV_MAX_WEIGHT_NORM) {
            valid_sources |= (1U << source);
        }
    }
    return valid_sources;
}

static unsigned char calculate_lcmv_weight_matrix(
    const separator_t *separator,
    int bin,
    Matrix3c *weights)
{
    Matrix3c loaded;
    Matrix3c constraints = Matrix3c::Zero();
    Eigen::LDLT<Matrix3c> covariance_solver;
    double trace;
    int microphone;
    int constraint;

    if (separator->covariance_frames <
        LCMV_COVARIANCE_WARMUP_FRAMES) {
        return 0;
    }
    loaded =
        0.5 * (
            separator->covariance[bin] +
            separator->covariance[bin].adjoint());
    trace = loaded.trace().real();
    loaded.diagonal().array() +=
        LCMV_DIAGONAL_LOADING * trace / MICROPHONES + 1e-12;
    covariance_solver.compute(loaded);
    if (covariance_solver.info() != Eigen::Success) {
        return 0;
    }
    for (constraint = 0;
         constraint < separator->source_count;
         ++constraint) {
        for (microphone = 0; microphone < MICROPHONES; ++microphone) {
            constraints(microphone, constraint) =
                separator->steering[constraint][microphone][bin];
        }
    }

    switch (separator->source_count) {
    case 1:
        return solve_lcmv_weight_matrix<1>(
            covariance_solver,
            constraints.leftCols<1>(),
            weights);
    case 2:
        return solve_lcmv_weight_matrix<2>(
            covariance_solver,
            constraints.leftCols<2>(),
            weights);
    case 3:
        return solve_lcmv_weight_matrix<3>(
            covariance_solver,
            constraints,
            weights);
    default:
        return 0;
    }
}

static void prepare_lcmv_weights(separator_t *separator)
{
    int bin;

    memset(
        separator->lcmv_valid_sources,
        0,
        sizeof(separator->lcmv_valid_sources));
    if (separator->method != SEPARATION_LCMV) {
        return;
    }
    for (bin = 0; bin < FFT_BINS; ++bin) {
        double frequency =
            (double)bin * separator->sample_rate / FRAME_LENGTH;

        if (frequency < LCMV_MIN_FREQUENCY_HZ ||
            frequency > LCMV_MAX_FREQUENCY_HZ) {
            continue;
        }
        separator->lcmv_valid_sources[bin] =
            calculate_lcmv_weight_matrix(
                separator,
                bin,
                &separator->lcmv_weights[bin]);
    }
}

static void update_covariance(separator_t *separator)
{
    int bin;
    int first;
    int second;

    for (bin = 0; bin < FFT_BINS; ++bin) {
        for (first = 0; first < MICROPHONES; ++first) {
            for (second = 0; second < MICROPHONES; ++second) {
                Complex instantaneous =
                    separator->spectra[first][bin] *
                    std::conj(separator->spectra[second][bin]);
                if (separator->covariance_frames == 0) {
                    separator->covariance[bin](first, second) =
                        instantaneous;
                } else {
                    separator->covariance[bin](first, second) =
                        COVARIANCE_SMOOTHING *
                            separator->covariance[bin](first, second) +
                        (1.0 - COVARIANCE_SMOOTHING) * instantaneous;
                }
            }
        }
    }
    if (separator->covariance_frames <
        LCMV_COVARIANCE_WARMUP_FRAMES) {
        ++separator->covariance_frames;
    }
}

static void queue_output_hop(separator_t *separator)
{
    int sample;

    for (sample = 0; sample < HOP_LENGTH; ++sample) {
        unsigned int next = queue_next(separator->output_write);
        int source;

        if (next == separator->output_read) {
            separator->output_read = queue_next(separator->output_read);
        }
        for (source = 0; source < separator->source_count; ++source) {
            double normalization = separator->normalization[sample];
            separator->output_queue[source][separator->output_write] =
                normalization > 1e-8
                    ? separator->overlap[source][sample] / normalization
                    : 0.0;
        }
        separator->output_write = next;
    }
}

static void process_hop(separator_t *separator)
{
    int microphone;
    int source;
    int sample;
    int bin;

    for (microphone = 0; microphone < MICROPHONES; ++microphone) {
        for (sample = 0; sample < FRAME_LENGTH; ++sample) {
            separator->fft_input[sample] =
                separator->input_frame[microphone][sample] *
                separator->window[sample];
        }
        fftw_execute(separator->forward_plan);
        for (bin = 0; bin < FFT_BINS; ++bin) {
            separator->spectra[microphone][bin] = Complex(
                separator->fft_output[bin][0],
                separator->fft_output[bin][1]);
        }
    }
    update_covariance(separator);
    prepare_lcmv_weights(separator);

    for (source = 0; source < separator->source_count; ++source) {
        for (bin = 0; bin < FFT_BINS; ++bin) {
            Complex beam = 0.0;
            Vector3c weights;
            int use_lcmv =
                separator->lcmv_valid_sources[bin] &
                (1U << source);

            if (use_lcmv) {
                weights =
                    separator->lcmv_weights[bin].col(source);
            } else {
                das_weights(separator, source, bin, &weights);
            }
            for (microphone = 0; microphone < MICROPHONES; ++microphone) {
                if (use_lcmv) {
                    Complex previous =
                        separator->previous_weights[source][bin][microphone];
                    if (std::abs(previous) > 0.0) {
                        weights(microphone) =
                            LCMV_WEIGHT_SMOOTHING * previous +
                            (1.0 - LCMV_WEIGHT_SMOOTHING) *
                                weights(microphone);
                    }
                    separator->previous_weights[source][bin][microphone] =
                        weights(microphone);
                } else {
                    separator->previous_weights[source][bin][microphone] =
                        0.0;
                }
                beam += std::conj(weights(microphone)) *
                        separator->spectra[microphone][bin];
            }
            separator->inverse_input[bin][0] = beam.real();
            separator->inverse_input[bin][1] = beam.imag();
        }
        fftw_execute(separator->inverse_plan);
        for (sample = 0; sample < FRAME_LENGTH; ++sample) {
            separator->overlap[source][sample] +=
                separator->inverse_output[sample] *
                separator->window[sample] / FRAME_LENGTH;
        }
    }
    for (sample = 0; sample < FRAME_LENGTH; ++sample) {
        separator->normalization[sample] +=
            separator->window[sample] * separator->window[sample];
    }

    queue_output_hop(separator);
    for (source = 0; source < separator->source_count; ++source) {
        memmove(
            separator->overlap[source],
            separator->overlap[source] + HOP_LENGTH,
            HOP_LENGTH * sizeof(double));
        memset(
            separator->overlap[source] + HOP_LENGTH,
            0,
            HOP_LENGTH * sizeof(double));
    }
    memmove(
        separator->normalization,
        separator->normalization + HOP_LENGTH,
        HOP_LENGTH * sizeof(double));
    memset(
        separator->normalization + HOP_LENGTH,
        0,
        HOP_LENGTH * sizeof(double));
}

static int process_callback(jack_nframes_t nframes, void *argument)
{
    separator_t *separator = static_cast<separator_t *>(argument);
    const jack_default_audio_sample_t *inputs[MICROPHONES];
    jack_default_audio_sample_t *outputs[MAX_SOURCES];
    jack_nframes_t frame;
    int microphone;
    int source;

    for (microphone = 0; microphone < MICROPHONES; ++microphone) {
        inputs[microphone] =
            static_cast<const jack_default_audio_sample_t *>(
                jack_port_get_buffer(
                    separator->input_ports[microphone], nframes));
    }
    for (source = 0; source < separator->source_count; ++source) {
        outputs[source] =
            static_cast<jack_default_audio_sample_t *>(
                jack_port_get_buffer(
                    separator->output_ports[source], nframes));
    }

    for (frame = 0; frame < nframes; ++frame) {
        for (source = 0; source < separator->source_count; ++source) {
            outputs[source][frame] =
                separator->output_read != separator->output_write
                    ? separator->output_queue[source][separator->output_read]
                    : 0.0;
        }
        if (separator->output_read != separator->output_write) {
            separator->output_read = queue_next(separator->output_read);
        }

        for (microphone = 0; microphone < MICROPHONES; ++microphone) {
            separator->input_frame[microphone]
                                  [HOP_LENGTH + separator->hop_samples] =
                inputs[microphone][frame];
        }
        ++separator->hop_samples;
        if (separator->hop_samples == HOP_LENGTH) {
            process_hop(separator);
            for (microphone = 0; microphone < MICROPHONES; ++microphone) {
                memmove(
                    separator->input_frame[microphone],
                    separator->input_frame[microphone] + HOP_LENGTH,
                    HOP_LENGTH * sizeof(double));
            }
            separator->hop_samples = 0;
        }
    }
    return 0;
}

static int initialize_separator(
    separator_t *separator,
    double microphone_distance,
    const int angles[MAX_SOURCES])
{
    double positions[MICROPHONES][2] = {
        {0.0, 0.0},
        {-microphone_distance, 0.0},
        {-microphone_distance / 2.0,
         -std::sqrt(3.0) * microphone_distance / 2.0}
    };
    double center_x = 0.0;
    double center_y = 0.0;
    int microphone;
    int source;
    int sample;
    int bin;

    separator->forward_plan = fftw_plan_dft_r2c_1d(
        FRAME_LENGTH,
        separator->fft_input,
        separator->fft_output,
        FFTW_ESTIMATE);
    separator->inverse_plan = fftw_plan_dft_c2r_1d(
        FRAME_LENGTH,
        separator->inverse_input,
        separator->inverse_output,
        FFTW_ESTIMATE);
    if (separator->forward_plan == NULL || separator->inverse_plan == NULL) {
        return 0;
    }
    for (sample = 0; sample < FRAME_LENGTH; ++sample) {
        separator->window[sample] =
            0.5 - 0.5 * std::cos(
                2.0 * M_PI * sample / FRAME_LENGTH);
    }
    for (microphone = 0; microphone < MICROPHONES; ++microphone) {
        center_x += positions[microphone][0] / MICROPHONES;
        center_y += positions[microphone][1] / MICROPHONES;
    }
    for (microphone = 0; microphone < MICROPHONES; ++microphone) {
        positions[microphone][0] -= center_x;
        positions[microphone][1] -= center_y;
    }
    for (source = 0; source < separator->source_count; ++source) {
        double radians = angles[source] * M_PI / 180.0;
        double direction_x = std::sin(radians);
        double direction_y = std::cos(radians);

        for (microphone = 0; microphone < MICROPHONES; ++microphone) {
            double delay = -(
                positions[microphone][0] * direction_x +
                positions[microphone][1] * direction_y) / SOUND_SPEED;

            for (bin = 0; bin < FFT_BINS; ++bin) {
                double frequency =
                    (double)bin * separator->sample_rate / FRAME_LENGTH;
                separator->steering[source][microphone][bin] =
                    std::exp(
                        Complex(0.0, -2.0 * M_PI * frequency * delay));
            }
        }
    }
    return 1;
}

static void usage(const char *program)
{
    fprintf(
        stderr,
        "Uso: %s METODO DISTANCIA NUMERO_FUENTES "
        "ANGULO_1 [ANGULO_2 ANGULO_3]\n"
        "METODO: das | lcmv\n",
        program);
}

int main(int argc, char **argv)
{
    separator_t separator{};
    jack_status_t status;
    double microphone_distance;
    int angles[MAX_SOURCES] = {0};
    int microphone;
    int source;

    if (argc < 5 || argc > 7) {
        usage(argv[0]);
        return 1;
    }
    if (strcmp(argv[1], "das") == 0) {
        separator.method = SEPARATION_DAS;
    } else if (strcmp(argv[1], "lcmv") == 0) {
        separator.method = SEPARATION_LCMV;
    } else {
        usage(argv[0]);
        return 1;
    }
    microphone_distance = strtod(argv[2], NULL);
    separator.source_count = atoi(argv[3]);
    if (microphone_distance <= 0.0 ||
        separator.source_count < 1 ||
        separator.source_count > MAX_SOURCES ||
        argc != separator.source_count + 4) {
        usage(argv[0]);
        return 1;
    }
    for (source = 0; source < separator.source_count; ++source) {
        angles[source] = atoi(argv[source + 4]);
        if (angles[source] < -180 || angles[source] > 180) {
            usage(argv[0]);
            return 1;
        }
    }

    separator.client = jack_client_open(
        "jack_das_separator", JackNoStartServer, &status);
    if (separator.client == NULL) {
        fprintf(stderr, "No se pudo conectar al servidor JACK (0x%x).\n", status);
        return 1;
    }
    separator.sample_rate = jack_get_sample_rate(separator.client);
    if (!initialize_separator(&separator, microphone_distance, angles)) {
        fprintf(stderr, "No se pudo inicializar el separador DAS.\n");
        jack_client_close(separator.client);
        return 1;
    }

    for (microphone = 0; microphone < MICROPHONES; ++microphone) {
        char port_name[32];
        snprintf(port_name, sizeof(port_name), "input_%d", microphone + 1);
        separator.input_ports[microphone] = jack_port_register(
            separator.client,
            port_name,
            JACK_DEFAULT_AUDIO_TYPE,
            JackPortIsInput,
            0);
        if (separator.input_ports[microphone] == NULL) {
            fprintf(stderr, "No se pudo registrar %s.\n", port_name);
            return 1;
        }
    }
    for (source = 0; source < separator.source_count; ++source) {
        char port_name[32];
        snprintf(port_name, sizeof(port_name), "output_%d", source + 1);
        separator.output_ports[source] = jack_port_register(
            separator.client,
            port_name,
            JACK_DEFAULT_AUDIO_TYPE,
            JackPortIsOutput,
            0);
        if (separator.output_ports[source] == NULL) {
            fprintf(stderr, "No se pudo registrar %s.\n", port_name);
            return 1;
        }
    }

    jack_set_process_callback(
        separator.client, process_callback, &separator);
    jack_on_shutdown(separator.client, jack_shutdown, NULL);
    signal(SIGINT, stop_handler);
    signal(SIGTERM, stop_handler);
    Eigen::internal::set_is_malloc_allowed(false);
    if (jack_activate(separator.client) != 0) {
        fprintf(stderr, "No se pudo activar jack_das_separator.\n");
        return 1;
    }

    printf(
        "Separador %s activo a %u Hz con %d fuentes.\n",
        separator.method == SEPARATION_LCMV ? "LCMV" : "DAS",
        separator.sample_rate,
        separator.source_count);
    while (running) {
        sleep(1);
    }

    jack_deactivate(separator.client);
    jack_client_close(separator.client);
    fftw_destroy_plan(separator.forward_plan);
    fftw_destroy_plan(separator.inverse_plan);
    return 0;
}

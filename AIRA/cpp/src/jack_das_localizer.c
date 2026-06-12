#include "das_localizer.h"

#include <errno.h>
#include <jack/jack.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define HOP_QUEUE_CAPACITY 64

typedef struct {
    float samples[DAS_MICROPHONES][DAS_HOP_LENGTH];
} hop_block_t;

static jack_client_t *client;
static jack_port_t *input_ports[DAS_MICROPHONES];
static hop_block_t hop_queue[HOP_QUEUE_CAPACITY];
static float pending_hop[DAS_MICROPHONES][DAS_HOP_LENGTH];
static unsigned int pending_samples;
static _Atomic unsigned int write_index;
static _Atomic unsigned int read_index;
static _Atomic int running = 1;
static _Atomic unsigned long dropped_hops;
static pthread_t worker_thread;
static das_localizer_t *localizer;
static int result_socket = -1;
static struct sockaddr_un result_address;

static int process_callback(jack_nframes_t nframes, void *argument)
{
    const jack_default_audio_sample_t *inputs[DAS_MICROPHONES];
    jack_nframes_t frame;
    int microphone;
    (void)argument;

    for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
        inputs[microphone] = jack_port_get_buffer(input_ports[microphone], nframes);
    }

    for (frame = 0; frame < nframes; ++frame) {
        for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
            pending_hop[microphone][pending_samples] =
                inputs[microphone][frame];
        }
        ++pending_samples;
        if (pending_samples == DAS_HOP_LENGTH) {
            unsigned int write = atomic_load_explicit(
                &write_index, memory_order_relaxed);
            unsigned int next = (write + 1U) % HOP_QUEUE_CAPACITY;
            unsigned int read = atomic_load_explicit(
                &read_index, memory_order_acquire);

            if (next == read) {
                atomic_fetch_add_explicit(
                    &dropped_hops, 1, memory_order_relaxed);
            } else {
                memcpy(hop_queue[write].samples, pending_hop, sizeof(pending_hop));
                atomic_store_explicit(
                    &write_index, next, memory_order_release);
            }
            pending_samples = 0;
        }
    }
    return 0;
}

static void send_result(const das_result_t *result)
{
    char message[512];
    int offset;
    int source;

    offset = snprintf(
        message,
        sizeof(message),
        "RESULT frame=%llu start=%.6f end=%.6f method=%s mode=%s "
        "stable=%d measurements=%d variation=%d consecutive=%d "
        "stable_time=%.6f sources=%d angles=",
        result->frame_index,
        result->start_time_s,
        result->end_time_s,
        result->method == DAS_METHOD_SRP_PHAT ? "srp-phat" : "adaptive",
        result->method == DAS_METHOD_SRP_PHAT
            ? "srp-phat"
            : (result->use_snr_mask ? "snr" : "base"),
        result->stability_ready ? result->stable : -1,
        result->stability_measurements,
        result->stability_ready ? result->maximum_variation_deg : -1,
        result->consecutive_stable_states,
        result->first_stable_time_s,
        result->source_count);
    for (source = 0; source < result->source_count && offset > 0 &&
                     (size_t)offset < sizeof(message);
         ++source) {
        offset += snprintf(
            message + offset,
            sizeof(message) - (size_t)offset,
            "%s%d",
            source == 0 ? "" : ",",
            result->angles_deg[source]);
    }
    if (result->source_count == 0 && offset > 0 &&
        (size_t)offset < sizeof(message)) {
        offset += snprintf(
            message + offset,
            sizeof(message) - (size_t)offset,
            "-");
    }
    if (offset > 0) {
        sendto(
            result_socket,
            message,
            strnlen(message, sizeof(message)),
            MSG_DONTWAIT,
            (const struct sockaddr *)&result_address,
            sizeof(result_address));
    }
}

static void *worker_main(void *argument)
{
    (void)argument;
    while (atomic_load_explicit(&running, memory_order_acquire)) {
        unsigned int read = atomic_load_explicit(
            &read_index, memory_order_relaxed);
        unsigned int write = atomic_load_explicit(
            &write_index, memory_order_acquire);

        if (read == write) {
            usleep(1000);
            continue;
        }
        {
            das_result_t result;
            if (das_localizer_process_hop(
                    localizer, hop_queue[read].samples, &result)) {
                send_result(&result);
            }
        }
        atomic_store_explicit(
            &read_index,
            (read + 1U) % HOP_QUEUE_CAPACITY,
            memory_order_release);
    }
    return NULL;
}

static void stop_handler(int signal_number)
{
    (void)signal_number;
    atomic_store_explicit(&running, 0, memory_order_release);
}

static void jack_shutdown(void *argument)
{
    (void)argument;
    atomic_store_explicit(&running, 0, memory_order_release);
}

static void usage(const char *program)
{
    fprintf(
        stderr,
        "Uso: %s SOCKET DISTANCIA_MICROFONOS MAX_FUENTES UMBRAL_RELATIVO "
        "METODO\n"
        "UMBRAL_RELATIVO: valor en (0, 1], por ejemplo 0.6\n"
        "METODO: adaptive | srp-phat\n",
        program);
}

int main(int argc, char **argv)
{
    jack_status_t status;
    double microphone_distance;
    int max_sources;
    double relative_peak_threshold;
    das_method_t method;
    int microphone;

    if (argc != 6) {
        usage(argv[0]);
        return 1;
    }
    microphone_distance = strtod(argv[2], NULL);
    max_sources = atoi(argv[3]);
    relative_peak_threshold = strtod(argv[4], NULL);
    if (strcmp(argv[5], "adaptive") == 0) {
        method = DAS_METHOD_ADAPTIVE;
    } else if (strcmp(argv[5], "srp-phat") == 0) {
        method = DAS_METHOD_SRP_PHAT;
    } else {
        usage(argv[0]);
        return 1;
    }

    memset(&result_address, 0, sizeof(result_address));
    result_address.sun_family = AF_UNIX;
    if (strlen(argv[1]) >= sizeof(result_address.sun_path)) {
        fprintf(stderr, "La ruta del socket es demasiado larga.\n");
        return 1;
    }
    strcpy(result_address.sun_path, argv[1]);
    result_socket = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (result_socket < 0) {
        perror("socket");
        return 1;
    }

    client = jack_client_open(
        "jack_das_localizer", JackNoStartServer, &status);
    if (client == NULL) {
        fprintf(stderr, "No se pudo conectar al servidor JACK (0x%x).\n", status);
        close(result_socket);
        return 1;
    }
    if (jack_get_sample_rate(client) != 48000) {
        fprintf(
            stderr,
            "JACK debe trabajar a 48000 Hz; frecuencia actual: %u Hz.\n",
            jack_get_sample_rate(client));
        jack_client_close(client);
        close(result_socket);
        return 1;
    }

    localizer = das_localizer_create(
        jack_get_sample_rate(client),
        microphone_distance,
        max_sources,
        relative_peak_threshold,
        method);
    if (localizer == NULL) {
        fprintf(stderr, "No se pudo inicializar el localizador DAS.\n");
        jack_client_close(client);
        close(result_socket);
        return 1;
    }

    for (microphone = 0; microphone < DAS_MICROPHONES; ++microphone) {
        char port_name[32];
        snprintf(port_name, sizeof(port_name), "input_%d", microphone + 1);
        input_ports[microphone] = jack_port_register(
            client,
            port_name,
            JACK_DEFAULT_AUDIO_TYPE,
            JackPortIsInput,
            0);
        if (input_ports[microphone] == NULL) {
            fprintf(stderr, "No se pudo registrar %s.\n", port_name);
            das_localizer_destroy(localizer);
            jack_client_close(client);
            close(result_socket);
            return 1;
        }
    }

    jack_set_process_callback(client, process_callback, NULL);
    jack_on_shutdown(client, jack_shutdown, NULL);
    signal(SIGINT, stop_handler);
    signal(SIGTERM, stop_handler);

    if (jack_activate(client) != 0) {
        fprintf(stderr, "No se pudo activar el cliente JACK.\n");
        das_localizer_destroy(localizer);
        jack_client_close(client);
        close(result_socket);
        return 1;
    }
    if (pthread_create(&worker_thread, NULL, worker_main, NULL) != 0) {
        fprintf(stderr, "No se pudo crear el hilo de localizacion.\n");
        jack_deactivate(client);
        das_localizer_destroy(localizer);
        jack_client_close(client);
        close(result_socket);
        return 1;
    }

    printf(
        "Localizador %s activo: 3 entradas, distancia %.3f m, "
        "hasta %d fuentes, umbral relativo %.3f.\n",
        method == DAS_METHOD_SRP_PHAT ? "SRP-PHAT" : "DAS adaptativo",
        microphone_distance,
        max_sources,
        relative_peak_threshold);
    while (atomic_load_explicit(&running, memory_order_acquire)) {
        sleep(1);
    }

    pthread_join(worker_thread, NULL);
    jack_deactivate(client);
    jack_client_close(client);
    das_localizer_destroy(localizer);
    close(result_socket);
    if (atomic_load_explicit(&dropped_hops, memory_order_relaxed) > 0) {
        fprintf(
            stderr,
            "Advertencia: se descartaron %lu bloques por sobrecarga.\n",
            atomic_load_explicit(&dropped_hops, memory_order_relaxed));
    }
    return 0;
}

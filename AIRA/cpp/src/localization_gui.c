#include <gtk/gtk.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_TRUE_ANGLES 16

typedef struct {
    GtkWidget *window;
    GtkWidget *folder_chooser;
    GtkWidget *play_button;
    GtkWidget *stop_button;
    GtkWidget *status_label;
    GtkWidget *distance_label;
    GtkWidget *true_angles_label;
    GtkWidget *window_label;
    GtkWidget *calculated_angles_label;
    GtkWidget *mode_label;
    GtkWidget *confidence_label;
    GSubprocess *script_process;
    int socket_fd;
    char socket_path[108];
    guint socket_timer;
} app_state_t;

static void set_label_value(GtkWidget *label, const char *title, const char *value)
{
    char *markup = g_markup_printf_escaped(
        "<b>%s</b> %s", title, value);
    gtk_label_set_markup(GTK_LABEL(label), markup);
    g_free(markup);
}

static int parse_case_info(
    const char *folder,
    double *distance,
    int angles[MAX_TRUE_ANGLES],
    int *angle_count,
    char **error_message)
{
    char *info_path = g_build_filename(folder, "info.txt", NULL);
    char *contents = NULL;
    char **lines;
    char *end;
    int count = 0;
    int line_id;

    if (!g_file_get_contents(info_path, &contents, NULL, NULL)) {
        *error_message = g_strdup_printf("No se pudo leer %s.", info_path);
        g_free(info_path);
        return 0;
    }
    lines = g_strsplit_set(contents, "\r\n", -1);
    *distance = g_ascii_strtod(lines[0], &end);
    if (end == lines[0] || *distance <= 0.0) {
        *error_message = g_strdup("La primera linea de info.txt no contiene una distancia valida.");
        g_strfreev(lines);
        g_free(contents);
        g_free(info_path);
        return 0;
    }

    for (line_id = 1; lines[line_id] != NULL; ++line_id) {
        char **tokens = g_strsplit_set(lines[line_id], ", \t", -1);
        int token_id;
        for (token_id = 0; tokens[token_id] != NULL; ++token_id) {
            long value;
            if (tokens[token_id][0] == '\0') {
                continue;
            }
            value = strtol(tokens[token_id], &end, 10);
            if (end != tokens[token_id] &&
                value >= -180 && value <= 180 &&
                count < MAX_TRUE_ANGLES) {
                angles[count++] = (int)value;
            }
        }
        g_strfreev(tokens);
    }
    g_strfreev(lines);
    g_free(contents);
    g_free(info_path);

    if (count < 1 || count > 4) {
        *error_message = g_strdup(
            "info.txt debe contener entre uno y cuatro angulos.");
        return 0;
    }
    *angle_count = count;
    return 1;
}

static int validate_wav_files(const char *folder, char **error_message)
{
    int microphone;
    for (microphone = 1; microphone <= 3; ++microphone) {
        char name[32];
        char *path;
        snprintf(name, sizeof(name), "wav_mic%d.wav", microphone);
        path = g_build_filename(folder, name, NULL);
        if (!g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
            *error_message = g_strdup_printf("Falta el archivo %s.", path);
            g_free(path);
            return 0;
        }
        g_free(path);
    }
    return 1;
}

static void stop_session(app_state_t *state)
{
    if (state->script_process != NULL) {
        g_subprocess_send_signal(state->script_process, SIGTERM);
        g_clear_object(&state->script_process);
    }
    if (state->socket_timer != 0) {
        g_source_remove(state->socket_timer);
        state->socket_timer = 0;
    }
    if (state->socket_fd >= 0) {
        close(state->socket_fd);
        state->socket_fd = -1;
    }
    if (state->socket_path[0] != '\0') {
        unlink(state->socket_path);
        state->socket_path[0] = '\0';
    }
    gtk_widget_set_sensitive(state->play_button, TRUE);
    gtk_widget_set_sensitive(state->stop_button, FALSE);
    gtk_widget_set_sensitive(state->folder_chooser, TRUE);
}

static void on_script_finished(
    GObject *source_object,
    GAsyncResult *result,
    gpointer user_data)
{
    app_state_t *state = user_data;
    GSubprocess *process = G_SUBPROCESS(source_object);
    GError *error = NULL;
    gboolean completed = g_subprocess_wait_finish(process, result, &error);
    const char *status;

    if (state->script_process != process) {
        g_clear_error(&error);
        return;
    }
    if (!completed) {
        status = error != NULL ? error->message : "El script termino con un error.";
    } else {
        status = g_subprocess_get_exit_status(process) == 0
            ? "Reproduccion terminada."
            : "El script termino con un error.";
    }
    gtk_label_set_text(GTK_LABEL(state->status_label), status);
    g_clear_error(&error);
    g_clear_object(&state->script_process);
    stop_session(state);
}

static gboolean poll_results(gpointer user_data)
{
    app_state_t *state = user_data;
    char latest[512] = {0};
    char buffer[512];
    ssize_t received;

    do {
        received = recv(
            state->socket_fd, buffer, sizeof(buffer) - 1, MSG_DONTWAIT);
        if (received > 0) {
            buffer[received] = '\0';
            memcpy(latest, buffer, (size_t)received + 1);
        }
    } while (received > 0);

    if (latest[0] != '\0') {
        unsigned long long frame;
        double start;
        double end;
        double confidence;
        char mode[16];
        char angles[128];
        char window_text[128];
        char confidence_text[64];

        if (sscanf(
                latest,
                "RESULT frame=%llu start=%lf end=%lf mode=%15s confidence=%lf angles=%127s",
                &frame,
                &start,
                &end,
                mode,
                &confidence,
                angles) == 6) {
            char *cursor;
            (void)frame;
            for (cursor = angles; *cursor != '\0'; ++cursor) {
                if (*cursor == ',') {
                    *cursor = ' ';
                }
            }
            snprintf(
                window_text,
                sizeof(window_text),
                "%.3f - %.3f s",
                start,
                end);
            snprintf(
                confidence_text,
                sizeof(confidence_text),
                "%.3f",
                confidence);

            /* These labels are replaced; no angle history is accumulated. */
            set_label_value(state->window_label, "Ventana:", window_text);
            set_label_value(
                state->calculated_angles_label,
                "Angulos calculados:",
                angles);
            set_label_value(
                state->mode_label,
                "Modo DAS:",
                strcmp(mode, "snr") == 0 ? "mascara SNR" : "base");
            set_label_value(
                state->confidence_label,
                "Confianza:",
                confidence_text);
            gtk_label_set_text(GTK_LABEL(state->status_label), "Procesando.");
        }
    } else if (received < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
        gtk_label_set_text(
            GTK_LABEL(state->status_label),
            "Error al recibir resultados del localizador.");
    }

    return G_SOURCE_CONTINUE;
}

static int open_result_socket(app_state_t *state, char **error_message)
{
    struct sockaddr_un address;

    snprintf(
        state->socket_path,
        sizeof(state->socket_path),
        "/tmp/aira-localization-%ld.sock",
        (long)getpid());
    unlink(state->socket_path);
    state->socket_fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (state->socket_fd < 0) {
        *error_message = g_strdup_printf("No se pudo crear el socket: %s.", strerror(errno));
        return 0;
    }
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, state->socket_path);
    if (bind(
            state->socket_fd,
            (const struct sockaddr *)&address,
            sizeof(address)) != 0) {
        *error_message = g_strdup_printf("No se pudo abrir el socket: %s.", strerror(errno));
        close(state->socket_fd);
        state->socket_fd = -1;
        unlink(state->socket_path);
        state->socket_path[0] = '\0';
        return 0;
    }
    return 1;
}

static void show_error(app_state_t *state, const char *message)
{
    GtkWidget *dialog = gtk_message_dialog_new(
        GTK_WINDOW(state->window),
        GTK_DIALOG_MODAL,
        GTK_MESSAGE_ERROR,
        GTK_BUTTONS_CLOSE,
        "%s",
        message);
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

static char *find_aira_directory(void)
{
    char executable_path[4096];
    ssize_t length = readlink(
        "/proc/self/exe", executable_path, sizeof(executable_path) - 1);

    if (length > 0) {
        char *executable_directory;
        char *candidate;
        char *script_path;

        executable_path[length] = '\0';
        executable_directory = g_path_get_dirname(executable_path);
        candidate = g_path_get_dirname(executable_directory);
        script_path = g_build_filename(
            candidate, "StartProjectScript.sh", NULL);
        g_free(executable_directory);
        if (g_file_test(script_path, G_FILE_TEST_IS_REGULAR)) {
            g_free(script_path);
            return candidate;
        }
        g_free(script_path);
        g_free(candidate);
    }
    return g_get_current_dir();
}

static void on_play_clicked(GtkButton *button, gpointer user_data)
{
    app_state_t *state = user_data;
    char *folder = gtk_file_chooser_get_filename(
        GTK_FILE_CHOOSER(state->folder_chooser));
    char *error_message = NULL;
    double distance;
    int true_angles[MAX_TRUE_ANGLES];
    int angle_count;
    char distance_text[64];
    char true_angles_text[128] = {0};
    char source_count_text[16];
    char *script_path;
    char *aira_directory;
    GSubprocessLauncher *launcher;
    GError *error = NULL;
    int angle;
    (void)button;

    if (folder == NULL) {
        show_error(state, "Seleccione primero una carpeta.");
        return;
    }
    if (!validate_wav_files(folder, &error_message) ||
        !parse_case_info(
            folder,
            &distance,
            true_angles,
            &angle_count,
            &error_message)) {
        show_error(state, error_message);
        g_free(error_message);
        g_free(folder);
        return;
    }
    if (!open_result_socket(state, &error_message)) {
        show_error(state, error_message);
        g_free(error_message);
        g_free(folder);
        return;
    }

    snprintf(distance_text, sizeof(distance_text), "%.3f m", distance);
    for (angle = 0; angle < angle_count; ++angle) {
        size_t used = strlen(true_angles_text);
        snprintf(
            true_angles_text + used,
            sizeof(true_angles_text) - used,
            "%s%d",
            angle == 0 ? "" : " ",
            true_angles[angle]);
    }
    snprintf(source_count_text, sizeof(source_count_text), "%d", angle_count);
    set_label_value(state->distance_label, "Distancia:", distance_text);
    set_label_value(
        state->true_angles_label,
        "Angulos reales:",
        true_angles_text);
    set_label_value(state->window_label, "Ventana:", "-");
    set_label_value(state->calculated_angles_label, "Angulos calculados:", "-");
    set_label_value(state->mode_label, "Modo DAS:", "-");
    set_label_value(state->confidence_label, "Confianza:", "-");

    aira_directory = find_aira_directory();
    script_path = g_build_filename(aira_directory, "StartProjectScript.sh", NULL);

    launcher = g_subprocess_launcher_new(
        G_SUBPROCESS_FLAGS_STDOUT_INHERIT |
        G_SUBPROCESS_FLAGS_STDERR_INHERIT);
    g_subprocess_launcher_set_cwd(launcher, aira_directory);
    state->script_process = g_subprocess_launcher_spawn(
        launcher,
        &error,
        "bash",
        script_path,
        folder,
        state->socket_path,
        source_count_text,
        NULL);
    g_object_unref(launcher);
    g_free(script_path);
    g_free(aira_directory);
    g_free(folder);

    if (state->script_process == NULL) {
        show_error(state, error->message);
        g_clear_error(&error);
        stop_session(state);
        return;
    }
    g_subprocess_wait_async(
        state->script_process, NULL, on_script_finished, state);
    gtk_widget_set_sensitive(state->play_button, FALSE);
    gtk_widget_set_sensitive(state->stop_button, TRUE);
    gtk_widget_set_sensitive(state->folder_chooser, FALSE);
    gtk_label_set_text(
        GTK_LABEL(state->status_label),
        "Iniciando JACK y las conexiones...");
    state->socket_timer = g_timeout_add(50, poll_results, state);
}

static void on_stop_clicked(GtkButton *button, gpointer user_data)
{
    app_state_t *state = user_data;
    (void)button;
    stop_session(state);
    gtk_label_set_text(GTK_LABEL(state->status_label), "Detenido.");
}

static void on_window_destroy(GtkWidget *widget, gpointer user_data)
{
    app_state_t *state = user_data;
    (void)widget;
    stop_session(state);
    gtk_main_quit();
}

int main(int argc, char **argv)
{
    app_state_t state = {0};
    GtkWidget *grid;
    GtkWidget *title;

    gtk_init(&argc, &argv);
    state.socket_fd = -1;

    state.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(state.window), "Localizacion DAS AIRA");
    gtk_window_set_default_size(GTK_WINDOW(state.window), 680, 390);
    gtk_container_set_border_width(GTK_CONTAINER(state.window), 20);
    g_signal_connect(
        state.window, "destroy", G_CALLBACK(on_window_destroy), &state);

    grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 14);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
    gtk_container_add(GTK_CONTAINER(state.window), grid);

    title = gtk_label_new(NULL);
    gtk_label_set_markup(
        GTK_LABEL(title),
        "<span size=\"x-large\"><b>Localizacion DAS adaptativa</b></span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), title, 0, 0, 3, 1);

    state.folder_chooser = gtk_file_chooser_button_new(
        "Seleccione la carpeta de grabaciones",
        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER);
    gtk_widget_set_hexpand(state.folder_chooser, TRUE);
    gtk_grid_attach(GTK_GRID(grid), state.folder_chooser, 0, 1, 3, 1);

    state.play_button = gtk_button_new_with_label("Play");
    state.stop_button = gtk_button_new_with_label("Stop");
    gtk_widget_set_sensitive(state.stop_button, FALSE);
    g_signal_connect(
        state.play_button, "clicked", G_CALLBACK(on_play_clicked), &state);
    g_signal_connect(
        state.stop_button, "clicked", G_CALLBACK(on_stop_clicked), &state);
    gtk_grid_attach(GTK_GRID(grid), state.play_button, 0, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), state.stop_button, 1, 2, 1, 1);

    state.status_label = gtk_label_new("Listo.");
    gtk_widget_set_halign(state.status_label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), state.status_label, 0, 3, 3, 1);

    state.distance_label = gtk_label_new(NULL);
    state.true_angles_label = gtk_label_new(NULL);
    state.window_label = gtk_label_new(NULL);
    state.calculated_angles_label = gtk_label_new(NULL);
    state.mode_label = gtk_label_new(NULL);
    state.confidence_label = gtk_label_new(NULL);
    set_label_value(state.distance_label, "Distancia:", "-");
    set_label_value(state.true_angles_label, "Angulos reales:", "-");
    set_label_value(state.window_label, "Ventana:", "-");
    set_label_value(state.calculated_angles_label, "Angulos calculados:", "-");
    set_label_value(state.mode_label, "Modo DAS:", "-");
    set_label_value(state.confidence_label, "Confianza:", "-");

    gtk_widget_set_halign(state.distance_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.true_angles_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.window_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.calculated_angles_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.mode_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.confidence_label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), state.distance_label, 0, 4, 3, 1);
    gtk_grid_attach(GTK_GRID(grid), state.true_angles_label, 0, 5, 3, 1);
    gtk_grid_attach(GTK_GRID(grid), state.window_label, 0, 6, 3, 1);
    gtk_grid_attach(
        GTK_GRID(grid), state.calculated_angles_label, 0, 7, 3, 1);
    gtk_grid_attach(GTK_GRID(grid), state.mode_label, 0, 8, 3, 1);
    gtk_grid_attach(GTK_GRID(grid), state.confidence_label, 0, 9, 3, 1);

    gtk_widget_show_all(state.window);
    gtk_main();
    return 0;
}

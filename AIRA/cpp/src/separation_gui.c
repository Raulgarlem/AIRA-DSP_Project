#define _POSIX_C_SOURCE 200809L

#include <gtk/gtk.h>

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_SOURCES 3

typedef struct {
    GtkWidget *window;
    GtkWidget *folder_chooser;
    GtkWidget *method_combo;
    GtkWidget *play_button;
    GtkWidget *stop_button;
    GtkWidget *source_radios[MAX_SOURCES];
    GtkWidget *status_label;
    GtkWidget *distance_label;
    GtkWidget *doa_label;
    GtkWidget *configuration_label;
    GSubprocess *script_process;
    char *aira_directory;
    int source_count;
    int switching_source;
} app_state_t;

static void set_label_value(
    GtkWidget *label,
    const char *title,
    const char *value)
{
    char *markup = g_markup_printf_escaped(
        "<b>%s</b> %s", title, value);
    gtk_label_set_markup(GTK_LABEL(label), markup);
    g_free(markup);
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
            candidate, "StartSeparationScript.sh", NULL);
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

static int parse_case_info(
    const char *folder,
    double *distance,
    int angles[MAX_SOURCES],
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
        *error_message = g_strdup_printf(
            "No se pudo leer %s.", info_path);
        g_free(info_path);
        return 0;
    }
    lines = g_strsplit_set(contents, "\r\n", -1);
    *distance = g_ascii_strtod(lines[0], &end);
    if (end == lines[0] || *distance <= 0.0) {
        *error_message = g_strdup(
            "La primera linea de info.txt no contiene una distancia valida.");
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
                value >= -180 && value <= 180) {
                if (count >= MAX_SOURCES) {
                    *error_message = g_strdup(
                        "La separacion en linea admite hasta tres fuentes.");
                    g_strfreev(tokens);
                    g_strfreev(lines);
                    g_free(contents);
                    g_free(info_path);
                    return 0;
                }
                angles[count++] = value == -180 ? 180 : (int)value;
            }
        }
        g_strfreev(tokens);
    }
    g_strfreev(lines);
    g_free(contents);
    g_free(info_path);

    if (count < 1) {
        *error_message = g_strdup(
            "info.txt debe contener al menos un angulo.");
        return 0;
    }
    *angle_count = count;
    return 1;
}

static void set_session_controls(app_state_t *state, gboolean running)
{
    int source;

    gtk_widget_set_sensitive(state->play_button, !running);
    gtk_widget_set_sensitive(state->stop_button, running);
    gtk_widget_set_sensitive(state->folder_chooser, !running);
    gtk_widget_set_sensitive(state->method_combo, !running);
    for (source = 0; source < MAX_SOURCES; ++source) {
        gtk_widget_set_sensitive(
            state->source_radios[source],
            running && source < state->source_count);
    }
}

static void stop_session(app_state_t *state)
{
    if (state->script_process != NULL) {
        g_subprocess_send_signal(state->script_process, SIGTERM);
        g_clear_object(&state->script_process);
    }
    state->source_count = 0;
    set_session_controls(state, FALSE);
}

static void on_script_finished(
    GObject *source_object,
    GAsyncResult *result,
    gpointer user_data)
{
    app_state_t *state = user_data;
    GSubprocess *process = G_SUBPROCESS(source_object);
    GError *error = NULL;
    gboolean completed;

    if (state->script_process != process) {
        return;
    }
    completed = g_subprocess_wait_finish(process, result, &error);
    if (!completed || g_subprocess_get_exit_status(process) != 0) {
        gtk_label_set_text(
            GTK_LABEL(state->status_label),
            error != NULL
                ? error->message
                : "La separacion termino con un error.");
    } else {
        gtk_label_set_text(
            GTK_LABEL(state->status_label),
            "Reproduccion terminada.");
    }
    g_clear_error(&error);
    g_clear_object(&state->script_process);
    state->source_count = 0;
    set_session_controls(state, FALSE);
}

static void on_source_toggled(
    GtkToggleButton *button,
    gpointer user_data)
{
    app_state_t *state = user_data;
    char source_text[8];
    char *script_path;
    char *standard_error = NULL;
    GError *error = NULL;
    int source;

    if (!gtk_toggle_button_get_active(button) ||
        state->script_process == NULL ||
        state->switching_source) {
        return;
    }
    for (source = 0; source < state->source_count; ++source) {
        if (GTK_WIDGET(button) == state->source_radios[source]) {
            break;
        }
    }
    if (source >= state->source_count) {
        return;
    }

    state->switching_source = 1;
    snprintf(source_text, sizeof(source_text), "%d", source + 1);
    script_path = g_build_filename(
        state->aira_directory, "SwitchSeparationSource.sh", NULL);
    {
        char *arguments[] = {
            (char *)"bash",
            script_path,
            source_text,
            NULL
        };
        if (!g_spawn_sync(
                state->aira_directory,
                arguments,
                NULL,
                G_SPAWN_SEARCH_PATH,
                NULL,
                NULL,
                NULL,
                &standard_error,
                NULL,
                &error)) {
            show_error(
                state,
                error != NULL
                    ? error->message
                    : "No se pudo cambiar la fuente.");
        } else if (standard_error != NULL && standard_error[0] != '\0') {
            show_error(state, standard_error);
        } else {
            char status[64];
            snprintf(
                status,
                sizeof(status),
                "Escuchando fuente %d.",
                source + 1);
            gtk_label_set_text(GTK_LABEL(state->status_label), status);
        }
    }
    g_clear_error(&error);
    g_free(standard_error);
    g_free(script_path);
    state->switching_source = 0;
}

static void on_play_clicked(GtkButton *button, gpointer user_data)
{
    app_state_t *state = user_data;
    char *folder = gtk_file_chooser_get_filename(
        GTK_FILE_CHOOSER(state->folder_chooser));
    char *error_message = NULL;
    double distance;
    int angles[MAX_SOURCES];
    int angle_count;
    const char *method;
    char distance_text[64];
    char doa_text[128] = {0};
    char angle_text[MAX_SOURCES][16];
    char *script_path;
    char *arguments[4 + MAX_SOURCES];
    GSubprocessLauncher *launcher;
    GError *error = NULL;
    int angle;
    (void)button;

    if (folder == NULL) {
        show_error(state, "Seleccione primero una carpeta.");
        return;
    }
    method = gtk_combo_box_get_active_id(
        GTK_COMBO_BOX(state->method_combo));
    if (method == NULL) {
        show_error(state, "Seleccione DAS o LCMV.");
        g_free(folder);
        return;
    }
    if (!validate_wav_files(folder, &error_message) ||
        !parse_case_info(
            folder,
            &distance,
            angles,
            &angle_count,
            &error_message)) {
        show_error(state, error_message);
        g_free(error_message);
        g_free(folder);
        return;
    }

    snprintf(distance_text, sizeof(distance_text), "%.3f m", distance);
    for (angle = 0; angle < angle_count; ++angle) {
        size_t used = strlen(doa_text);
        snprintf(
            doa_text + used,
            sizeof(doa_text) - used,
            "%s%d",
            angle == 0 ? "" : " ",
            angles[angle]);
        snprintf(
            angle_text[angle],
            sizeof(angle_text[angle]),
            "%d",
            angles[angle]);
    }

    script_path = g_build_filename(
        state->aira_directory, "StartSeparationScript.sh", NULL);
    arguments[0] = (char *)"bash";
    arguments[1] = script_path;
    arguments[2] = folder;
    arguments[3] = (char *)method;
    for (angle = 0; angle < angle_count; ++angle) {
        arguments[4 + angle] = angle_text[angle];
    }
    arguments[4 + angle_count] = NULL;

    launcher = g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_NONE);
    g_subprocess_launcher_set_cwd(launcher, state->aira_directory);
    state->script_process = g_subprocess_launcher_spawnv(
        launcher,
        (const gchar *const *)arguments,
        &error);
    g_object_unref(launcher);
    g_free(script_path);
    g_free(folder);

    if (state->script_process == NULL) {
        show_error(state, error->message);
        g_clear_error(&error);
        return;
    }

    state->source_count = angle_count;
    gtk_toggle_button_set_active(
        GTK_TOGGLE_BUTTON(state->source_radios[0]), TRUE);
    set_label_value(state->distance_label, "Distancia:", distance_text);
    set_label_value(state->doa_label, "DOA reales:", doa_text);
    set_label_value(
        state->configuration_label,
        "Configuracion:",
        strcmp(method, "lcmv") == 0
            ? "DOA conocidos + LCMV WOLA en linea"
            : "DOA conocidos + DAS WOLA en linea");
    gtk_label_set_text(
        GTK_LABEL(state->status_label),
        "Procesando. Escuchando fuente 1.");
    set_session_controls(state, TRUE);
    g_subprocess_wait_async(
        state->script_process, NULL, on_script_finished, state);
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
    g_free(state->aira_directory);
    gtk_main_quit();
}

int main(int argc, char **argv)
{
    app_state_t state = {0};
    GtkWidget *grid;
    GtkWidget *title;
    GtkWidget *method_title;
    GtkWidget *source_title;
    int source;

    gtk_init(&argc, &argv);
    state.aira_directory = find_aira_directory();

    state.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(state.window), "Separacion AIRA");
    gtk_window_set_default_size(GTK_WINDOW(state.window), 760, 500);
    gtk_container_set_border_width(GTK_CONTAINER(state.window), 20);
    g_signal_connect(
        state.window, "destroy", G_CALLBACK(on_window_destroy), &state);

    grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 12);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
    gtk_container_add(GTK_CONTAINER(state.window), grid);

    title = gtk_label_new(NULL);
    gtk_label_set_markup(
        GTK_LABEL(title),
        "<span size=\"x-large\"><b>Separacion en linea</b></span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), title, 0, 0, 3, 1);

    method_title = gtk_label_new(NULL);
    gtk_label_set_markup(
        GTK_LABEL(method_title),
        "<b>Metodo de separacion con DOA reales</b>");
    gtk_widget_set_halign(method_title, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), method_title, 0, 1, 3, 1);

    state.method_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append(
        GTK_COMBO_BOX_TEXT(state.method_combo),
        "das",
        "DAS WOLA");
    gtk_combo_box_text_append(
        GTK_COMBO_BOX_TEXT(state.method_combo),
        "lcmv",
        "LCMV WOLA");
    gtk_combo_box_set_active(GTK_COMBO_BOX(state.method_combo), 0);
    gtk_widget_set_hexpand(state.method_combo, TRUE);
    gtk_grid_attach(
        GTK_GRID(grid), state.method_combo, 0, 2, 3, 1);

    state.folder_chooser = gtk_file_chooser_button_new(
        "Seleccione la carpeta de grabaciones",
        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER);
    gtk_widget_set_hexpand(state.folder_chooser, TRUE);
    gtk_grid_attach(
        GTK_GRID(grid), state.folder_chooser, 0, 3, 3, 1);

    source_title = gtk_label_new(NULL);
    gtk_label_set_markup(
        GTK_LABEL(source_title),
        "<b>Fuente monitorizada</b>");
    gtk_widget_set_halign(source_title, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), source_title, 0, 4, 3, 1);

    state.source_radios[0] = gtk_radio_button_new_with_label(
        NULL, "Source 1");
    for (source = 1; source < MAX_SOURCES; ++source) {
        char label[32];
        snprintf(label, sizeof(label), "Source %d", source + 1);
        state.source_radios[source] =
            gtk_radio_button_new_with_label_from_widget(
                GTK_RADIO_BUTTON(state.source_radios[0]),
                label);
    }
    for (source = 0; source < MAX_SOURCES; ++source) {
        gtk_widget_set_sensitive(state.source_radios[source], FALSE);
        g_signal_connect(
            state.source_radios[source],
            "toggled",
            G_CALLBACK(on_source_toggled),
            &state);
        gtk_grid_attach(
            GTK_GRID(grid),
            state.source_radios[source],
            source,
            5,
            1,
            1);
    }

    state.play_button = gtk_button_new_with_label("Play");
    state.stop_button = gtk_button_new_with_label("Stop");
    gtk_widget_set_sensitive(state.stop_button, FALSE);
    g_signal_connect(
        state.play_button, "clicked", G_CALLBACK(on_play_clicked), &state);
    g_signal_connect(
        state.stop_button, "clicked", G_CALLBACK(on_stop_clicked), &state);
    gtk_grid_attach(GTK_GRID(grid), state.play_button, 0, 6, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), state.stop_button, 1, 6, 1, 1);

    state.status_label = gtk_label_new("Listo.");
    state.distance_label = gtk_label_new(NULL);
    state.doa_label = gtk_label_new(NULL);
    state.configuration_label = gtk_label_new(NULL);
    gtk_widget_set_halign(state.status_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.distance_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.doa_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.configuration_label, GTK_ALIGN_START);
    set_label_value(state.distance_label, "Distancia:", "-");
    set_label_value(state.doa_label, "DOA reales:", "-");
    set_label_value(state.configuration_label, "Configuracion:", "-");
    gtk_grid_attach(GTK_GRID(grid), state.status_label, 0, 7, 3, 1);
    gtk_grid_attach(GTK_GRID(grid), state.distance_label, 0, 8, 3, 1);
    gtk_grid_attach(GTK_GRID(grid), state.doa_label, 0, 9, 3, 1);
    gtk_grid_attach(
        GTK_GRID(grid), state.configuration_label, 0, 10, 3, 1);

    gtk_widget_show_all(state.window);
    gtk_main();
    return 0;
}

#include <gtk/gtk.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_TRUE_ANGLES 16

typedef struct {
    GtkWidget *window;
    GtkWidget *online_radio;
    GtkWidget *known_doa_radio;
    GtkWidget *localization_combo;
    GtkWidget *separation_combo;
    GtkWidget *folder_chooser;
    GtkWidget *play_button;
    GtkWidget *stop_button;
    GtkWidget *status_label;
    GtkWidget *distance_label;
    GtkWidget *doa_label;
    GtkWidget *configuration_label;
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
                value >= -180 && value <= 180 &&
                count < MAX_TRUE_ANGLES) {
                angles[count++] = value == -180 ? 180 : (int)value;
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

static const char *localization_label(const char *method)
{
    return strcmp(method, "srp-phat") == 0
        ? "SRP-PHAT"
        : "DAS adaptativo";
}

static const char *separation_label(const char *method)
{
    if (strcmp(method, "lcmv") == 0) {
        return "LCMV";
    }
    if (strcmp(method, "gsc") == 0) {
        return "GSC";
    }
    return "Beamforming DAS";
}

static void on_mode_toggled(GtkToggleButton *button, gpointer user_data)
{
    app_state_t *state = user_data;
    gboolean online;
    (void)button;

    online = gtk_toggle_button_get_active(
        GTK_TOGGLE_BUTTON(state->online_radio));
    gtk_widget_set_sensitive(state->localization_combo, online);
}

static void on_play_clicked(GtkButton *button, gpointer user_data)
{
    app_state_t *state = user_data;
    char *folder = gtk_file_chooser_get_filename(
        GTK_FILE_CHOOSER(state->folder_chooser));
    char *error_message = NULL;
    const char *separation_method;
    const char *localization_method;
    double distance;
    int angles[MAX_TRUE_ANGLES];
    int angle_count;
    int angle;
    char distance_text[64];
    char doa_text[128] = {0};
    char configuration_text[256];
    gboolean online;
    (void)button;

    if (folder == NULL) {
        show_error(state, "Seleccione primero una carpeta.");
        return;
    }
    separation_method = gtk_combo_box_get_active_id(
        GTK_COMBO_BOX(state->separation_combo));
    if (separation_method == NULL) {
        show_error(state, "Seleccione un metodo de separacion.");
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
    }

    online = gtk_toggle_button_get_active(
        GTK_TOGGLE_BUTTON(state->online_radio));
    localization_method = gtk_combo_box_get_active_id(
        GTK_COMBO_BOX(state->localization_combo));
    if (online && localization_method == NULL) {
        show_error(state, "Seleccione un metodo de localizacion.");
        g_free(folder);
        return;
    }

    if (online) {
        snprintf(
            configuration_text,
            sizeof(configuration_text),
            "En linea: %s + %s",
            localization_label(localization_method),
            separation_label(separation_method));
    } else {
        snprintf(
            configuration_text,
            sizeof(configuration_text),
            "DOA conocidos + %s",
            separation_label(separation_method));
    }

    set_label_value(state->distance_label, "Distancia:", distance_text);
    set_label_value(state->doa_label, "DOA del caso:", doa_text);
    set_label_value(
        state->configuration_label,
        "Configuracion:",
        configuration_text);
    gtk_label_set_text(
        GTK_LABEL(state->status_label),
        "Configuracion valida. La separacion aun no esta implementada.");
    gtk_widget_set_sensitive(state->stop_button, TRUE);
    g_free(folder);
}

static void on_stop_clicked(GtkButton *button, gpointer user_data)
{
    app_state_t *state = user_data;
    (void)button;

    set_label_value(state->distance_label, "Distancia:", "-");
    set_label_value(state->doa_label, "DOA del caso:", "-");
    set_label_value(state->configuration_label, "Configuracion:", "-");
    gtk_label_set_text(GTK_LABEL(state->status_label), "Detenido.");
    gtk_widget_set_sensitive(state->stop_button, FALSE);
}

static void on_window_destroy(GtkWidget *widget, gpointer user_data)
{
    (void)widget;
    (void)user_data;
    gtk_main_quit();
}

int main(int argc, char **argv)
{
    app_state_t state = {0};
    GtkWidget *grid;
    GtkWidget *title;
    GtkWidget *mode_title;
    GtkWidget *localization_title;
    GtkWidget *separation_title;

    gtk_init(&argc, &argv);

    state.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(state.window), "Separacion AIRA");
    gtk_window_set_default_size(GTK_WINDOW(state.window), 760, 560);
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
        "<span size=\"x-large\"><b>Separacion de fuentes</b></span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), title, 0, 0, 3, 1);

    mode_title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(mode_title), "<b>Modo de operacion</b>");
    gtk_widget_set_halign(mode_title, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), mode_title, 0, 1, 3, 1);

    state.online_radio = gtk_radio_button_new_with_label(NULL, "En linea");
    state.known_doa_radio = gtk_radio_button_new_with_label_from_widget(
        GTK_RADIO_BUTTON(state.online_radio),
        "Con DOA conocidos");
    gtk_toggle_button_set_active(
        GTK_TOGGLE_BUTTON(state.online_radio), TRUE);
    g_signal_connect(
        state.online_radio,
        "toggled",
        G_CALLBACK(on_mode_toggled),
        &state);
    g_signal_connect(
        state.known_doa_radio,
        "toggled",
        G_CALLBACK(on_mode_toggled),
        &state);
    gtk_grid_attach(GTK_GRID(grid), state.online_radio, 0, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), state.known_doa_radio, 1, 2, 1, 1);

    localization_title = gtk_label_new(NULL);
    gtk_label_set_markup(
        GTK_LABEL(localization_title),
        "<b>Localizacion para modo en linea</b>");
    gtk_widget_set_halign(localization_title, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), localization_title, 0, 3, 3, 1);

    state.localization_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append(
        GTK_COMBO_BOX_TEXT(state.localization_combo),
        "adaptive",
        "DAS adaptativo");
    gtk_combo_box_text_append(
        GTK_COMBO_BOX_TEXT(state.localization_combo),
        "srp-phat",
        "SRP-PHAT");
    gtk_combo_box_set_active(GTK_COMBO_BOX(state.localization_combo), 0);
    gtk_widget_set_hexpand(state.localization_combo, TRUE);
    gtk_grid_attach(GTK_GRID(grid), state.localization_combo, 0, 4, 3, 1);

    separation_title = gtk_label_new(NULL);
    gtk_label_set_markup(
        GTK_LABEL(separation_title),
        "<b>Metodo de separacion</b>");
    gtk_widget_set_halign(separation_title, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), separation_title, 0, 5, 3, 1);

    state.separation_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append(
        GTK_COMBO_BOX_TEXT(state.separation_combo),
        "das",
        "Beamforming DAS");
    gtk_combo_box_text_append(
        GTK_COMBO_BOX_TEXT(state.separation_combo),
        "lcmv",
        "LCMV");
    gtk_combo_box_text_append(
        GTK_COMBO_BOX_TEXT(state.separation_combo),
        "gsc",
        "GSC");
    gtk_combo_box_set_active(GTK_COMBO_BOX(state.separation_combo), 0);
    gtk_widget_set_hexpand(state.separation_combo, TRUE);
    gtk_grid_attach(GTK_GRID(grid), state.separation_combo, 0, 6, 3, 1);

    state.folder_chooser = gtk_file_chooser_button_new(
        "Seleccione la carpeta de grabaciones",
        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER);
    gtk_widget_set_hexpand(state.folder_chooser, TRUE);
    gtk_grid_attach(GTK_GRID(grid), state.folder_chooser, 0, 7, 3, 1);

    state.play_button = gtk_button_new_with_label("Play");
    state.stop_button = gtk_button_new_with_label("Stop");
    gtk_widget_set_sensitive(state.stop_button, FALSE);
    g_signal_connect(
        state.play_button, "clicked", G_CALLBACK(on_play_clicked), &state);
    g_signal_connect(
        state.stop_button, "clicked", G_CALLBACK(on_stop_clicked), &state);
    gtk_grid_attach(GTK_GRID(grid), state.play_button, 0, 8, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), state.stop_button, 1, 8, 1, 1);

    state.status_label = gtk_label_new("Listo.");
    state.distance_label = gtk_label_new(NULL);
    state.doa_label = gtk_label_new(NULL);
    state.configuration_label = gtk_label_new(NULL);
    gtk_widget_set_halign(state.status_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.distance_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.doa_label, GTK_ALIGN_START);
    gtk_widget_set_halign(state.configuration_label, GTK_ALIGN_START);
    set_label_value(state.distance_label, "Distancia:", "-");
    set_label_value(state.doa_label, "DOA del caso:", "-");
    set_label_value(state.configuration_label, "Configuracion:", "-");
    gtk_grid_attach(GTK_GRID(grid), state.status_label, 0, 9, 3, 1);
    gtk_grid_attach(GTK_GRID(grid), state.distance_label, 0, 10, 3, 1);
    gtk_grid_attach(GTK_GRID(grid), state.doa_label, 0, 11, 3, 1);
    gtk_grid_attach(
        GTK_GRID(grid), state.configuration_label, 0, 12, 3, 1);

    gtk_widget_show_all(state.window);
    gtk_main();
    return 0;
}

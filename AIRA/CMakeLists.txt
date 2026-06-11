cmake_minimum_required(VERSION 3.16)

project(AIRA)

# =========================
# Configuración general
# =========================

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -g -O2")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g -O2")

# =========================
# Dependencias
# =========================

find_package(PkgConfig REQUIRED)

pkg_check_modules(JACK REQUIRED jack)
pkg_check_modules(SNDFILE REQUIRED sndfile)
pkg_check_modules(FFTW3 REQUIRED fftw3)
pkg_check_modules(GTK3 REQUIRED gtk+-3.0)
find_package(Threads REQUIRED)

include_directories(
    ${JACK_INCLUDE_DIRS}
    ${SNDFILE_INCLUDE_DIRS}
    ${FFTW3_INCLUDE_DIRS}
    ${GTK3_INCLUDE_DIRS}
    ${CMAKE_CURRENT_SOURCE_DIR}/cpp/include
)

# =========================
# ReadMicWavs
# =========================

add_executable(
    ReadMicWavs
    cpp/src/ReadMicWavs.cpp
)

target_link_libraries(
    ReadMicWavs
    ${JACK_LIBRARIES}
    ${SNDFILE_LIBRARIES}
)

# =========================
# ReadMicWavsMulti
# =========================

add_executable(
    ReadMicWavsMulti
    cpp/src/ReadMicWavsMulti.cpp
)

target_link_libraries(
    ReadMicWavsMulti
    ${JACK_LIBRARIES}
    ${SNDFILE_LIBRARIES}
)

# =========================
# JACK Agent
# =========================

add_executable(
    jack_in_to_out
    cpp/src/jack_in_to_out.c
)

target_link_libraries(
    jack_in_to_out
    ${JACK_LIBRARIES}
)

# =========================
# Localizacion DAS en JACK
# =========================

add_library(
    das_localizer
    cpp/src/das_localizer.c
)

target_compile_options(
    das_localizer
    PRIVATE
    ${FFTW3_CFLAGS_OTHER}
)

target_link_libraries(
    das_localizer
    ${FFTW3_LIBRARIES}
    m
)

add_executable(
    jack_das_localizer
    cpp/src/jack_das_localizer.c
)

target_compile_options(
    jack_das_localizer
    PRIVATE
    ${JACK_CFLAGS_OTHER}
)

target_link_libraries(
    jack_das_localizer
    das_localizer
    ${JACK_LIBRARIES}
    Threads::Threads
)

# =========================
# Interfaz GTK3
# =========================

add_executable(
    localization_gui
    cpp/src/localization_gui.c
)

target_compile_options(
    localization_gui
    PRIVATE
    ${GTK3_CFLAGS_OTHER}
)

target_link_libraries(
    localization_gui
    ${GTK3_LIBRARIES}
)

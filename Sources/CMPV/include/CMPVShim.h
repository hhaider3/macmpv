#ifndef CMPV_SHIM_H
#define CMPV_SHIM_H

#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <dlfcn.h>
#include <stdint.h>

static inline mpv_handle *cinewave_mpv_create(void) {
    return mpv_create();
}

static inline int cinewave_mpv_initialize(mpv_handle *handle) {
    return mpv_initialize(handle);
}

static inline const char *cinewave_mpv_error_string(int error) {
    return mpv_error_string(error);
}

static inline int cinewave_mpv_set_option_string(
    mpv_handle *handle,
    const char *name,
    const char *value
) {
    return mpv_set_option_string(handle, name, value);
}

static inline int cinewave_mpv_command_1(mpv_handle *handle, const char *arg0) {
    const char *args[] = {arg0, NULL};
    return mpv_command(handle, args);
}

static inline int cinewave_mpv_command_2(
    mpv_handle *handle,
    const char *arg0,
    const char *arg1
) {
    const char *args[] = {arg0, arg1, NULL};
    return mpv_command(handle, args);
}

static inline int cinewave_mpv_command_3(
    mpv_handle *handle,
    const char *arg0,
    const char *arg1,
    const char *arg2
) {
    const char *args[] = {arg0, arg1, arg2, NULL};
    return mpv_command(handle, args);
}

static inline double cinewave_mpv_get_double(
    mpv_handle *handle,
    const char *name,
    double fallback
) {
    double value = fallback;
    return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0
        ? value
        : fallback;
}

static inline int cinewave_mpv_get_flag(
    mpv_handle *handle,
    const char *name,
    int fallback
) {
    int value = fallback;
    return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0
        ? value
        : fallback;
}

static inline int64_t cinewave_mpv_get_int64(
    mpv_handle *handle,
    const char *name,
    int64_t fallback
) {
    int64_t value = fallback;
    return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0
        ? value
        : fallback;
}

static inline char *cinewave_mpv_get_string(
    mpv_handle *handle,
    const char *name
) {
    return mpv_get_property_string(handle, name);
}

static inline int cinewave_mpv_set_double(
    mpv_handle *handle,
    const char *name,
    double value
) {
    return mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &value);
}

static inline int cinewave_mpv_set_flag(
    mpv_handle *handle,
    const char *name,
    int value
) {
    return mpv_set_property(handle, name, MPV_FORMAT_FLAG, &value);
}

static inline int cinewave_mpv_set_string(
    mpv_handle *handle,
    const char *name,
    const char *value
) {
    return mpv_set_property_string(handle, name, value);
}

static inline const mpv_event *cinewave_mpv_wait_event(mpv_handle *handle, double timeout) {
    return mpv_wait_event(handle, timeout);
}

static inline int cinewave_mpv_event_id(const mpv_event *event) {
    return event ? (int)event->event_id : (int)MPV_EVENT_NONE;
}

static inline uint64_t cinewave_mpv_event_reply_userdata(const mpv_event *event) {
    return event ? event->reply_userdata : 0;
}

static inline int cinewave_mpv_event_none(void) {
    return (int)MPV_EVENT_NONE;
}

static inline int cinewave_mpv_event_file_loaded(void) {
    return (int)MPV_EVENT_FILE_LOADED;
}

static inline int cinewave_mpv_event_end_file(void) {
    return (int)MPV_EVENT_END_FILE;
}

static inline int cinewave_mpv_event_end_file_error(const mpv_event *event) {
    if (!event || event->event_id != MPV_EVENT_END_FILE) return 0;
    mpv_event_end_file *end_file = (mpv_event_end_file *)event->data;
    return end_file ? end_file->error : 0;
}

static inline int cinewave_mpv_event_shutdown(void) {
    return (int)MPV_EVENT_SHUTDOWN;
}

static inline int cinewave_mpv_event_property_change(void) {
    return (int)MPV_EVENT_PROPERTY_CHANGE;
}

static inline int cinewave_mpv_observe_property(mpv_handle *handle, uint64_t userdata, const char *name, int format) {
    return mpv_observe_property(handle, userdata, name, (mpv_format)format);
}

static inline void cinewave_mpv_wakeup(mpv_handle *handle) {
    mpv_wakeup(handle);
}

static inline void cinewave_mpv_render_set_update_callback(mpv_render_context *ctx, void (*cb)(void *), void *data) {
    mpv_render_context_set_update_callback(ctx, cb, data);
}

static inline void cinewave_mpv_render_report_swap(mpv_render_context *ctx) {
    mpv_render_context_report_swap(ctx);
}

static inline int cinewave_mpv_format_flag(void) { return MPV_FORMAT_FLAG; }
static inline int cinewave_mpv_format_double(void) { return MPV_FORMAT_DOUBLE; }
static inline int cinewave_mpv_format_string(void) { return MPV_FORMAT_STRING; }

static inline void *cinewave_mpv_gl_proc_address(void *context, const char *name) {
    (void)context;
    static void *open_gl = NULL;
    if (!open_gl) {
        open_gl = dlopen(
            "/System/Library/Frameworks/OpenGL.framework/OpenGL",
            RTLD_LAZY | RTLD_LOCAL
        );
    }
    return open_gl ? dlsym(open_gl, name) : NULL;
}

static inline int cinewave_mpv_render_create(
    mpv_render_context **render_context,
    mpv_handle *handle
) {
    mpv_opengl_init_params open_gl = {
        .get_proc_address = cinewave_mpv_gl_proc_address,
        .get_proc_address_ctx = NULL,
    };
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &open_gl},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    return mpv_render_context_create(render_context, handle, parameters);
}

static inline uint64_t cinewave_mpv_render_update(
    mpv_render_context *render_context
) {
    return mpv_render_context_update(render_context);
}

static inline int cinewave_mpv_render_has_frame(uint64_t flags) {
    return (flags & MPV_RENDER_UPDATE_FRAME) != 0;
}

static inline void cinewave_mpv_render_frame(
    mpv_render_context *render_context,
    int framebuffer,
    int width,
    int height
) {
    mpv_opengl_fbo target = {
        .fbo = framebuffer,
        .w = width,
        .h = height,
        .internal_format = 0,
    };
    int flip_y = 1;
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &target},
        {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    mpv_render_context_render(render_context, parameters);
}

static inline void cinewave_mpv_render_free(
    mpv_render_context *render_context
) {
    if (render_context) {
        mpv_render_context_free(render_context);
    }
}

static inline void cinewave_mpv_destroy(mpv_handle *handle) {
    if (handle) {
        mpv_terminate_destroy(handle);
    }
}

static inline void cinewave_mpv_free(void *data) {
    mpv_free(data);
}

#endif

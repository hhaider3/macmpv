// Reproduce mpv#18274 without connecting devices or playing audible sound.
// Force AudioUnit initialization to fail, then check that no CoreAudio listener
// remains registered with a pointer to the freed audio output.
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <mpv/client.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef MACMPV_AUDIO_INTERPOSE
static atomic_int init_failures;
static atomic_int listeners;
static pthread_mutex_t listener_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    AudioObjectPropertySelector selector;
    AudioObjectPropertyListenerProc callback;
    void *context;
} registrations[64];
int macmpv_test_init_failures(void) { return atomic_load(&init_failures); }
int macmpv_test_listeners(void) { return atomic_load(&listeners); }

static bool is_hotplug_listener(AudioObjectID object, const AudioObjectPropertyAddress *address)
{
    return object == kAudioObjectSystemObject &&
        (address->mSelector == kAudioHardwarePropertyDevices ||
         address->mSelector == kAudioHardwarePropertyDefaultOutputDevice);
}

static OSStatus track_add(AudioObjectID object, const AudioObjectPropertyAddress *address,
                          AudioObjectPropertyListenerProc callback, void *context)
{
    if (is_hotplug_listener(object, address)) {
        pthread_mutex_lock(&listener_lock);
        size_t slot = 64;
        for (size_t i = 0; i < 64; i++) {
            if (registrations[i].callback == callback && registrations[i].context == context &&
                registrations[i].selector == address->mSelector) {
                pthread_mutex_unlock(&listener_lock);
                return noErr;
            }
            if (!registrations[i].callback) slot = i;
        }
        if (slot == 64) abort();
        registrations[slot].selector = address->mSelector;
        registrations[slot].callback = callback;
        registrations[slot].context = context;
        atomic_fetch_add(&listeners, 1);
        pthread_mutex_unlock(&listener_lock);
        // Do not install the dangling callback into the real audio system.
        return noErr;
    }
    return noErr;
}

static OSStatus track_remove(AudioObjectID object, const AudioObjectPropertyAddress *address,
                             AudioObjectPropertyListenerProc callback, void *context)
{
    if (is_hotplug_listener(object, address)) {
        pthread_mutex_lock(&listener_lock);
        for (size_t i = 0; i < 64; i++) {
            if (registrations[i].callback == callback && registrations[i].context == context &&
                registrations[i].selector == address->mSelector) {
                registrations[i].callback = NULL;
                atomic_fetch_sub(&listeners, 1);
                break;
            }
        }
        pthread_mutex_unlock(&listener_lock);
        return noErr;
    }
    return noErr;
}

static OSStatus fail_audio_init(AudioUnit unit)
{
    atomic_fetch_add(&init_failures, 1);
    return kAudioUnitErr_FailedInitialization;
}

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *new_function; const void *old_function; } \
        interpose_##original = { (const void *)&replacement, (const void *)&original }
INTERPOSE(track_add, AudioObjectAddPropertyListener);
INTERPOSE(track_remove, AudioObjectRemovePropertyListener);
INTERPOSE(fail_audio_init, AudioUnitInitialize);

#else
extern int macmpv_test_init_failures(void);
extern int macmpv_test_listeners(void);

int main(void)
{
#define MPV_FUNCTION(name) __typeof__(&name) fn_##name = name
    MPV_FUNCTION(mpv_create);
    MPV_FUNCTION(mpv_set_option_string);
    MPV_FUNCTION(mpv_initialize);
    MPV_FUNCTION(mpv_command);
    MPV_FUNCTION(mpv_wait_event);
    MPV_FUNCTION(mpv_request_log_messages);
    MPV_FUNCTION(mpv_terminate_destroy);

    mpv_handle *player = fn_mpv_create();
    if (!player) return 2;
    const char *options[][2] = {
        {"config", "no"}, {"load-scripts", "no"}, {"vo", "null"},
        {"ao", "coreaudio"}, {"audio-format", "float"}, {"terminal", "yes"},
        {"msg-level", "all=error"}
    };
    for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
        if (fn_mpv_set_option_string(player, options[i][0], options[i][1]) < 0) return 2;
    }
    if (fn_mpv_initialize(player) < 0) return 2;
    fn_mpv_request_log_messages(player, "error");
    // libavdevice's silent source avoids temporary media or private user files.
    const char *command[] = {"loadfile", "av://lavfi:anullsrc=r=48000:cl=stereo", NULL};
    if (fn_mpv_command(player, command) < 0) return 2;
    bool ended = false;
    for (int i = 0; i < 200; i++) {
        mpv_event *event = fn_mpv_wait_event(player, 0.05);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *message = event->data;
            fprintf(stderr, "[%s] %s", message->prefix, message->text);
        }
        if (event->event_id == MPV_EVENT_END_FILE) { ended = true; break; }
    }
    fn_mpv_terminate_destroy(player);
    int failures = macmpv_test_init_failures();
    int remaining = macmpv_test_listeners();
    printf("Initialization failures injected: %d; dangling hotplug listeners: %d\n", failures, remaining);
    if (!ended || failures == 0) {
        fprintf(stderr, "Test did not reach the intended audio initialization failure.\n");
        return 2;
    }
    return remaining == 0 ? 0 : 1;
}
#endif

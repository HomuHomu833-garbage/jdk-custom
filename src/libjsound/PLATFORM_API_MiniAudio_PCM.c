/*
 * MIT License -- see the LICENSE file at the root of this repository.
 * Copyright (c) 2025-2026 Lily Ross
 *
 * A DirectAudio (javax.sound.sampled PCM) backend for OpenJDK's libjsound,
 * built on miniaudio instead of ALSA.
 *
 * Why: OpenJDK's only unix PCM backend is ALSA, and it needs <alsa/asoundlib.h>
 * at build time and libasound.so.2 at run time. No cross sysroot used by this
 * repository ships either, and bionic devices have no ALSA at all, so those
 * builds shipped with no native sound provider whatsoever. miniaudio declares
 * the backend symbols itself and dlopen()s whatever the machine actually has --
 * PulseAudio/ALSA/JACK/sndio/OSS on unix, AAudio/OpenSL ES on android -- so
 * there is no build-time dependency and one binary works on all of them.
 *
 * Scope: this implements DirectAudio (SourceDataLine/TargetDataLine) only. The
 * ports (mixer control) and MIDI providers are compiled out by the build --
 * miniaudio has no equivalent for either. See scripts/build.sh.
 *
 * Model: one mixer, index 0, which is whatever the system calls its default
 * device. Each open line gets its own ma_device plus a single-producer/
 * single-consumer ring buffer, and the device data callback is the other end of
 * that ring buffer. That mirrors how the ALSA backend is driven by the Java
 * layer: DAUDIO_Write/Read move bytes, and position and drain state are derived
 * from how full the buffer is (the same estimate the ALSA backend makes in
 * estimatePositionFromAvail).
 *
 * This file is copied into the JDK source tree by scripts/build.sh, next to a
 * pinned miniaudio.h, and is compiled as part of libjsound (GPLv2 with the
 * Classpath Exception). MIT is compatible with that.
 */

/*
 * Pull in the miniaudio implementation here: this is the only translation unit
 * that uses it. Everything above device I/O -- decoding, the resource manager,
 * the node graph, the high level engine -- is switched off; we only ever need a
 * raw device and a ring buffer, and leaving the rest out keeps libjsound small.
 */
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_WAV
#define MA_NO_FLAC
#define MA_NO_MP3
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "DirectAudio.h"

#if USE_DAUDIO == TRUE

/*
 * miniaudio's multi-byte sample formats are native endian; Java asks for an
 * explicit byte order, so we advertise and accept only the one we are.
 */
#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__) && \
    (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
#define MA_JSOUND_BIG_ENDIAN 1
#else
#define MA_JSOUND_BIG_ENDIAN 0
#endif

/*
 * How many lines we claim can be open at once. The backends that matter here
 * mix in software (PulseAudio, AAudio, OpenSL ES, JACK, sndio), so this is a
 * soft limit; on a bare ALSA hw device the second open fails and the Java layer
 * turns that into a LineUnavailableException, which is the honest answer.
 */
#define MA_JSOUND_MAX_SIMUL_LINES 32

/* How long DAUDIO_Write/Read sleep between attempts when the buffer is full. */
#define MA_JSOUND_WAIT_MILLIS 2

typedef struct tag_MiniAudioPcmInfo {
    ma_device    device;
    ma_pcm_rb    rb;
    int          isSource;           /* TRUE: playback, FALSE: capture */
    int          frameSize;          /* bytes per frame */
    int          bufferSizeInBytes;  /* ring buffer capacity, whole frames */
    int          deviceValid;
    int          rbValid;
    volatile int isRunning;
    volatile int isFlushed;
    volatile int isClosing;
} MiniAudioPcmInfo;

/*
 * One context for the whole process. It is created on first use and never torn
 * down: it outlives individual lines, and libjsound has no shutdown hook to
 * hang the uninit off. theContextState is 0 before the first attempt, 1 once
 * usable, -1 once we know audio is unavailable (so we stop retrying).
 */
static ma_context     theContext;
static int            theContextState = 0;
static pthread_mutex_t theContextLock = PTHREAD_MUTEX_INITIALIZER;

static ma_context* getContext(void) {
    ma_context* result = NULL;

    pthread_mutex_lock(&theContextLock);
    if (theContextState == 0) {
        ma_context_config config = ma_context_config_init();
        if (ma_context_init(NULL, 0, &config, &theContext) == MA_SUCCESS) {
            theContextState = 1;
        } else {
            theContextState = -1;
        }
    }
    if (theContextState == 1) {
        result = &theContext;
    }
    pthread_mutex_unlock(&theContextLock);
    return result;
}

static void napMillis(long millis) {
    struct timespec ts;

    ts.tv_sec = (time_t) (millis / 1000);
    ts.tv_nsec = (long) ((millis % 1000) * 1000000L);
    nanosleep(&ts, NULL);
}

/*
 * Map a Java PCM format onto a miniaudio one. Java's 8-bit PCM is unsigned and
 * everything wider is signed, which is exactly the set miniaudio has.
 */
static int toMaFormat(int encoding, int sampleSizeInBits, int frameSize,
                      int channels, int isSigned, int isBigEndian,
                      ma_format* pFormat) {
    int bytesPerSample;

    if (encoding != DAUDIO_PCM || channels <= 0 || frameSize <= 0) {
        return FALSE;
    }
    if (frameSize % channels != 0) {
        return FALSE;
    }
    bytesPerSample = frameSize / channels;
    if (bytesPerSample * 8 != sampleSizeInBits) {
        /* padded or packed layouts (e.g. 24-in-32) are not something we can
         * hand to miniaudio unchanged */
        return FALSE;
    }
    if (bytesPerSample > 1 && (isBigEndian ? 1 : 0) != MA_JSOUND_BIG_ENDIAN) {
        return FALSE;
    }

    switch (bytesPerSample) {
    case 1: if (isSigned) return FALSE; *pFormat = ma_format_u8;  return TRUE;
    case 2: if (!isSigned) return FALSE; *pFormat = ma_format_s16; return TRUE;
    case 3: if (!isSigned) return FALSE; *pFormat = ma_format_s24; return TRUE;
    case 4: if (!isSigned) return FALSE; *pFormat = ma_format_s32; return TRUE;
    default: return FALSE;
    }
}

/*
 * The device end of the ring buffer. For playback we drain as much as is
 * queued; miniaudio has already silenced the output buffer, so a short read
 * simply plays silence for the rest of the period (an underrun). For capture we
 * fill what fits and drop the rest (an overrun), which is what the ALSA backend
 * ends up doing too.
 */
static void maDataCallback(ma_device* pDevice, void* pOutput, const void* pInput,
                           ma_uint32 frameCount) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) pDevice->pUserData;
    ma_uint32 remaining = frameCount;

    if (info == NULL) {
        return;
    }

    if (info->isSource) {
        ma_uint8* dst = (ma_uint8*) pOutput;
        while (remaining > 0) {
            ma_uint32 frames = remaining;
            void* src = NULL;

            if (ma_pcm_rb_acquire_read(&info->rb, &frames, &src) != MA_SUCCESS
                || frames == 0) {
                break;
            }
            memcpy(dst, src, (size_t) frames * info->frameSize);
            ma_pcm_rb_commit_read(&info->rb, frames);
            dst += (size_t) frames * info->frameSize;
            remaining -= frames;
        }
    } else {
        const ma_uint8* src = (const ma_uint8*) pInput;
        while (remaining > 0) {
            ma_uint32 frames = remaining;
            void* dst = NULL;

            if (ma_pcm_rb_acquire_write(&info->rb, &frames, &dst) != MA_SUCCESS
                || frames == 0) {
                break;
            }
            memcpy(dst, src, (size_t) frames * info->frameSize);
            ma_pcm_rb_commit_write(&info->rb, frames);
            src += (size_t) frames * info->frameSize;
            remaining -= frames;
        }
    }
}

/* ************************************************************************** */
/* DirectAudio.h implementation                                               */
/* ************************************************************************** */

INT32 DAUDIO_GetDirectAudioDeviceCount() {
    /* One mixer: the system default device. If no backend came up at all,
     * report no mixers rather than handing out lines that cannot open. */
    return (getContext() != NULL) ? 1 : 0;
}

INT32 DAUDIO_GetDirectAudioDeviceDescription(INT32 mixerIndex,
                                             DirectAudioDeviceDescription* description) {
    ma_context* context = getContext();

    if (context == NULL || mixerIndex != 0 || description == NULL) {
        return FALSE;
    }

    description->deviceID = 0;
    description->maxSimulLines = MA_JSOUND_MAX_SIMUL_LINES;
    snprintf(description->name, sizeof(description->name),
             "%s", "Default Audio Device");
    snprintf(description->vendor, sizeof(description->vendor),
             "%s", "miniaudio");
    snprintf(description->description, sizeof(description->description),
             "Default audio device via %s", ma_get_backend_name(context->backend));
    snprintf(description->version, sizeof(description->version),
             "%s", MA_VERSION_STRING);
    return TRUE;
}

void DAUDIO_GetFormats(INT32 mixerIndex, INT32 deviceID, int isSource, void* creator) {
    static const int sampleSizes[] = { 8, 16, 24, 32 };
    int i, channels;

    if (getContext() == NULL) {
        return;
    }

    /* miniaudio converts sample rate, channel count and sample format between
     * what we ask for and what the device natively wants, so advertise the set
     * we can hand it verbatim and let it deal with the rest. -1 for the rate
     * means "any", the same thing the ALSA backend reports for plughw. */
    for (i = 0; i < (int) (sizeof(sampleSizes) / sizeof(sampleSizes[0])); i++) {
        int bits = sampleSizes[i];
        int bytes = bits / 8;
        int isSigned = (bits == 8) ? FALSE : TRUE;
        int isBigEndian = (bytes > 1) ? MA_JSOUND_BIG_ENDIAN : FALSE;

        for (channels = 1; channels <= 2; channels++) {
            DAUDIO_AddAudioFormat(creator, bits, bytes * channels, channels,
                                  -1.0f, DAUDIO_PCM, isSigned, isBigEndian);
        }
    }
}

void* DAUDIO_Open(INT32 mixerIndex, INT32 deviceID, int isSource,
                  int encoding, float sampleRate, int sampleSizeInBits,
                  int frameSize, int channels,
                  int isSigned, int isBigEndian, int bufferSizeInBytes) {
    MiniAudioPcmInfo* info;
    ma_context* context;
    ma_device_config config;
    ma_format format;
    ma_uint32 bufferSizeInFrames;

    if (!toMaFormat(encoding, sampleSizeInBits, frameSize, channels,
                    isSigned, isBigEndian, &format)) {
        return NULL;
    }
    context = getContext();
    if (context == NULL) {
        return NULL;
    }

    /* Keep at least a couple of frames so the ring buffer is usable even if the
     * caller asked for something tiny. */
    if (bufferSizeInBytes < frameSize * 2) {
        bufferSizeInBytes = frameSize * 2;
    }
    bufferSizeInFrames = (ma_uint32) (bufferSizeInBytes / frameSize);

    info = (MiniAudioPcmInfo*) calloc(1, sizeof(MiniAudioPcmInfo));
    if (info == NULL) {
        return NULL;
    }
    info->isSource = isSource ? TRUE : FALSE;
    info->frameSize = frameSize;
    info->bufferSizeInBytes = (int) (bufferSizeInFrames * frameSize);
    info->isFlushed = TRUE;

    if (ma_pcm_rb_init(format, (ma_uint32) channels, bufferSizeInFrames,
                       NULL, NULL, &info->rb) != MA_SUCCESS) {
        free(info);
        return NULL;
    }
    info->rbValid = TRUE;

    config = ma_device_config_init(isSource ? ma_device_type_playback
                                            : ma_device_type_capture);
    if (isSource) {
        config.playback.format = format;
        config.playback.channels = (ma_uint32) channels;
    } else {
        config.capture.format = format;
        config.capture.channels = (ma_uint32) channels;
    }
    /* 0 lets miniaudio keep the device's own rate; the Java layer always names
     * one, but guard against a non-specified rate reaching us. */
    config.sampleRate = (sampleRate > 0.0f) ? (ma_uint32) (sampleRate + 0.5f) : 0;
    config.dataCallback = maDataCallback;
    config.pUserData = info;

    if (ma_device_init(context, &config, &info->device) != MA_SUCCESS) {
        ma_pcm_rb_uninit(&info->rb);
        free(info);
        return NULL;
    }
    info->deviceValid = TRUE;
    return info;
}

int DAUDIO_Start(void* id, int isSource) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;

    if (info == NULL) {
        return FALSE;
    }
    if (!info->isRunning) {
        if (ma_device_start(&info->device) != MA_SUCCESS) {
            return FALSE;
        }
        info->isRunning = TRUE;
    }
    return TRUE;
}

int DAUDIO_Stop(void* id, int isSource) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;

    if (info == NULL) {
        return FALSE;
    }
    if (info->isRunning) {
        /* ma_device_stop waits for the audio thread to go idle, so whatever is
         * still queued stays queued -- Java expects stop() to pause, not drop. */
        if (ma_device_stop(&info->device) != MA_SUCCESS) {
            return FALSE;
        }
        info->isRunning = FALSE;
    }
    return TRUE;
}

void DAUDIO_Close(void* id, int isSource) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;

    if (info == NULL) {
        return;
    }
    /* Set first: it is what releases a DAUDIO_Write/Read blocked on a full or
     * empty buffer. ma_device_uninit then stops the device and joins its
     * thread, so no callback can be in flight once it returns. */
    info->isClosing = TRUE;
    if (info->deviceValid) {
        ma_device_uninit(&info->device);
    }
    if (info->rbValid) {
        ma_pcm_rb_uninit(&info->rb);
    }
    free(info);
}

int DAUDIO_Write(void* id, char* data, int byteSize) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;
    int written = 0;

    if (info == NULL || !info->isSource || data == NULL || byteSize < 0) {
        return -1;
    }
    info->isFlushed = FALSE;

    while (written < byteSize) {
        ma_uint32 frames = (ma_uint32) ((byteSize - written) / info->frameSize);
        void* dst = NULL;

        if (frames == 0) {
            break;  /* trailing partial frame, nothing we can queue */
        }
        if (ma_pcm_rb_acquire_write(&info->rb, &frames, &dst) != MA_SUCCESS) {
            return -1;
        }
        if (frames == 0) {
            /* Buffer full. Block, like snd_pcm_writei does: SourceDataLine.write
             * is specified to return only once the data has been queued. Return
             * what we have if the caller is already unblocked, or if the line is
             * being closed underneath us. */
            if (written > 0 || info->isClosing) {
                break;
            }
            napMillis(MA_JSOUND_WAIT_MILLIS);
            continue;
        }
        memcpy(dst, data + written, (size_t) frames * info->frameSize);
        ma_pcm_rb_commit_write(&info->rb, frames);
        written += (int) (frames * info->frameSize);
    }
    return written;
}

int DAUDIO_Read(void* id, char* data, int byteSize) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;
    int read = 0;

    if (info == NULL || info->isSource || data == NULL || byteSize < 0) {
        return -1;
    }
    info->isFlushed = FALSE;

    while (read < byteSize) {
        ma_uint32 frames = (ma_uint32) ((byteSize - read) / info->frameSize);
        void* src = NULL;

        if (frames == 0) {
            break;
        }
        if (ma_pcm_rb_acquire_read(&info->rb, &frames, &src) != MA_SUCCESS) {
            return -1;
        }
        if (frames == 0) {
            /* Nothing captured yet. Same contract as above: TargetDataLine.read
             * blocks until it has something to hand back. */
            if (read > 0 || info->isClosing || !info->isRunning) {
                break;
            }
            napMillis(MA_JSOUND_WAIT_MILLIS);
            continue;
        }
        memcpy(data + read, src, (size_t) frames * info->frameSize);
        ma_pcm_rb_commit_read(&info->rb, frames);
        read += (int) (frames * info->frameSize);
    }
    return read;
}

int DAUDIO_GetBufferSize(void* id, int isSource) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;

    return (info != NULL) ? info->bufferSizeInBytes : 0;
}

int DAUDIO_StillDraining(void* id, int isSource) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;

    if (info == NULL || !info->isSource) {
        return FALSE;
    }
    return (ma_pcm_rb_available_read(&info->rb) > 0) ? TRUE : FALSE;
}

int DAUDIO_Flush(void* id, int isSource) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;
    int wasRunning;

    if (info == NULL) {
        return FALSE;
    }
    if (info->isFlushed) {
        return TRUE;  /* nothing to drop */
    }

    /* The ring buffer is single producer / single consumer, so resetting it
     * under a live device callback would race. Stop the device first (which
     * joins the audio thread), reset, then restart if it had been running --
     * the same drop-and-restart the ALSA backend does. */
    wasRunning = info->isRunning;
    if (wasRunning && ma_device_stop(&info->device) != MA_SUCCESS) {
        return FALSE;
    }
    ma_pcm_rb_reset(&info->rb);
    info->isFlushed = TRUE;
    if (wasRunning && ma_device_start(&info->device) != MA_SUCCESS) {
        info->isRunning = FALSE;
        return FALSE;
    }
    return TRUE;
}

int DAUDIO_GetAvailable(void* id, int isSource) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;

    if (info == NULL) {
        return 0;
    }
    if (info->isSource) {
        if (info->isFlushed) {
            return info->bufferSizeInBytes;
        }
        return (int) (ma_pcm_rb_available_write(&info->rb) * info->frameSize);
    }
    return (int) (ma_pcm_rb_available_read(&info->rb) * info->frameSize);
}

INT64 DAUDIO_GetBytePosition(void* id, int isSource, INT64 javaBytePos) {
    MiniAudioPcmInfo* info = (MiniAudioPcmInfo*) id;
    INT64 result = javaBytePos;

    /* Estimate from how full the buffer is, exactly as the ALSA backend does in
     * estimatePositionFromAvail: for playback javaBytePos is the position we
     * will have reached once everything queued has been played, for capture it
     * is where we were when the buffer was last empty. */
    if (info != NULL && !info->isFlushed) {
        int available = DAUDIO_GetAvailable(id, isSource);

        if (info->isSource) {
            result = javaBytePos - info->bufferSizeInBytes + available;
        } else {
            result = javaBytePos + available;
        }
    }
    /* The estimate runs behind by up to one buffer, so it starts out negative;
     * report the start of the stream rather than a position before it. */
    return (result > 0) ? result : 0;
}

void DAUDIO_SetBytePosition(void* id, int isSource, INT64 javaBytePos) {
    /* Nothing to do: DAUDIO_GetBytePosition works off the javaBytePos it is
     * handed, so the Java layer's own notion of the position is authoritative. */
}

int DAUDIO_RequiresServicing(void* id, int isSource) {
    return FALSE;  /* the device callback drives everything */
}

void DAUDIO_Service(void* id, int isSource) {
    /* never needed, see DAUDIO_RequiresServicing */
}

#endif // USE_DAUDIO

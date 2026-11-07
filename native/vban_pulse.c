/* SPDX-License-Identifier: MIT
 * Experimental 48 kHz stereo s16le VBAN -> asynchronous libpulse receiver.
 * One Pulse mainloop handles UDP, control and timeouts. No helper PCM process.
 */
#define _GNU_SOURCE /* SCHED_RESET_ON_FORK */
#include <pulse/pulseaudio.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sched.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define RATE 48000U
#define FRAME_BYTES 4U
#define SLOTS 64U
#define MAX_PCM 1024U
#define BYTE_RATE (RATE * FRAME_BYTES)
#define MAX_RATE_PPM 2000.0
#define STATUS_BYTES 4096U

enum phase { IDLE, PRIMING, PLAYING, DRAINING, CORKING, FLUSHING };
static const char *phase_names[] = {"idle", "priming", "playing", "draining", "corking", "flushing"};
struct packet { bool used, concealed; uint32_t sequence; size_t size, offset; uint8_t pcm[MAX_PCM]; };
struct stats { uint64_t accepted, invalid, wrong_source, duplicate, late, missing, overflow, server_overflow,
    discontinuities, underflow, sessions, written_bytes; };
struct reply { bool used; struct sockaddr_un address; socklen_t len; };
struct app {
    pa_mainloop *loop; pa_mainloop_api *api; pa_context *context; pa_stream *stream;
    pa_operation *drain; pa_time_event *timer;
    int udp_fd, control_fd; const char *control_path, *sink, *server;
    struct in_addr source; char name[17]; unsigned port, latency_ms, jitter_ms, idle_ms;
    struct sockaddr_un subscriber; socklen_t subscriber_len;
    struct packet packets[SLOTS]; struct stats stats;
    uint32_t next_sequence, highest_sequence; bool sequence_valid, ready, active, pumping;
    enum phase phase; size_t queued, previous_size;
    uint64_t last_valid, last_nonzero, started, gap_since, last_report, last_adjust;
    double backlog_ewma, target_backlog, integral, ppm; unsigned playback_rate;
    pa_usec_t latency; int latency_negative; double gain;
    int64_t phone, held_phone; bool phone_pending, ending, syncing, sync_active, sync_mix, managed, managed_ready;
    unsigned revision, synced_revision, sync_revision, sync_stage;
    int64_t sync_phone; double sync_gain; struct reply replies[16]; bool timing_pending, underrun_pending;
    unsigned desired_rate, inflight_rate, server_rate, rate_acks; bool rate_pending;
    char resampler[64]; int64_t read_index, write_index; pa_usec_t sink_usec, transport_usec;
    uint64_t control_time; pa_usec_t configured_sink_usec; bool target_negotiated;
    const char *scheduling;
    unsigned suspend_delay_ms; uint64_t suspend_at; /* deferred idle suspend; 0 = none pending */
    uint64_t diag_window; unsigned diag_count, diag_suppressed;
};
static volatile sig_atomic_t stopped;
static uint64_t mono_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000; }
static void unref(pa_operation *op) { if (op) pa_operation_unref(op); }
static void fail(struct app *a, const char *message) { fprintf(stderr, "%s: %s\n", message, pa_strerror(pa_context_errno(a->context))); a->api->quit(a->api, 1); }
static void update_target(struct app *a) {
    const pa_buffer_attr *attr = a->ready ? pa_stream_get_buffer_attr(a->stream) : NULL;
    const pa_timing_info *timing = a->ready ? pa_stream_get_timing_info(a->stream) : NULL;
    const pa_sample_spec *spec = a->ready ? pa_stream_get_sample_spec(a->stream) : NULL;
    a->target_negotiated = attr && timing && spec && timing->configured_sink_usec != PA_USEC_INVALID;
    a->configured_sink_usec = a->target_negotiated ? timing->configured_sink_usec : 0;
    /* ADJUST_LATENCY takes a total budget, but returns the client queue alone.
     * Match the measured client + sink backlog using the negotiated sink budget,
     * not the instantaneous sink fill or an additional jitter buffer. Pulse may
     * enlarge these attributes to accommodate a hardware scheduling floor. */
    a->target_backlog = a->target_negotiated
        ? attr->tlength * 1000000.0 / pa_bytes_per_second(spec) + a->configured_sink_usec
        : a->latency_ms * 1000.0;
}
static void status_json(struct app *a, char *out, size_t size, const char *event) {
    const pa_buffer_attr *attr = a->ready ? pa_stream_get_buffer_attr(a->stream) : NULL;
    char phone[32]; if (a->phone < 0) strcpy(phone, "null"); else snprintf(phone, sizeof(phone), "%" PRId64, a->phone);
    int count = snprintf(out, size, "{\"ok\":true,\"event\":\"%s\",\"pid\":%ld,\"active\":%s,\"state\":\"%s\",\"sink_input\":%u,\"phone\":%s,\"phone_pending\":%s,\"queued_ms\":%.3f,\"latency_us\":%" PRIu64 ",\"latency_negative\":%d,\"rate\":%u,\"ppm\":%.1f,\"gain\":%.6f,\"tlength\":%u,\"minreq\":%u,\"prebuf\":%u,\"maxlength\":%u,\"accepted\":%" PRIu64 ",\"invalid\":%" PRIu64 ",\"wrong_source\":%" PRIu64 ",\"duplicate\":%" PRIu64 ",\"late\":%" PRIu64 ",\"missing\":%" PRIu64 ",\"overflow\":%" PRIu64 ",\"discontinuities\":%" PRIu64 ",\"underflow\":%" PRIu64 ",\"sessions\":%" PRIu64 ",\"written_bytes\":%" PRIu64 "}",
        event, (long)getpid(), a->active ? "true" : "false", phase_names[a->phase],
        a->ready ? pa_stream_get_index(a->stream) : PA_INVALID_INDEX, phone, a->phone_pending ? "true" : "false",
        a->queued * 1000.0 / BYTE_RATE, (uint64_t)a->latency, a->latency_negative, a->playback_rate,
        a->ppm, a->gain, attr ? attr->tlength : 0, attr ? attr->minreq : 0,
        attr ? attr->prebuf : 0, attr ? attr->maxlength : 0, a->stats.accepted,
        a->stats.invalid, a->stats.wrong_source, a->stats.duplicate, a->stats.late,
        a->stats.missing, a->stats.overflow, a->stats.discontinuities, a->stats.underflow,
        a->stats.sessions, a->stats.written_bytes);
    if (count <= 0 || (size_t)count >= size) goto truncated;
    size_t used = (size_t)count;
    count = snprintf(out + used - 1, size - used + 1,
        ",\"rate_ack\":%u,\"rate_pending\":%s,\"server_rate\":%u,\"resampler\":\"%s\",\"read_index\":%" PRId64 ",\"write_index\":%" PRId64 ",\"sink_usec\":%" PRIu64 ",\"transport_usec\":%" PRIu64 ",\"monotonic_us\":%" PRIu64 ",\"effective_target_us\":%.1f,\"configured_sink_us\":%" PRIu64 ",\"target_negotiated\":%s,\"scheduling\":\"%s\",\"suspend_pending_ms\":%.0f,\"server_overflow\":%" PRIu64 "}",
        a->rate_acks, a->rate_pending ? "true" : "false", a->server_rate, a->resampler,
        a->read_index, a->write_index, (uint64_t)a->sink_usec, (uint64_t)a->transport_usec, mono_us(),
        a->target_backlog, (uint64_t)a->configured_sink_usec, a->target_negotiated ? "true" : "false", a->scheduling,
        a->suspend_at > mono_us() ? (a->suspend_at - mono_us()) / 1000.0 : 0.0, a->stats.server_overflow);
    if (count >= 0 && (size_t)count < size - used + 1) return;
truncated:
    fprintf(stderr, "status JSON exceeded its buffer\n");
    snprintf(out, size, "{\"ok\":false,\"error\":\"status_truncated\"}");
}
/* Rate-limited one-line diagnostics on stderr (the container log). Counters and
 * queue state only: never PCM, addresses or stream content. */
static void diag(struct app *a, const char *event) {
    uint64_t now = mono_us();
    if (now - a->diag_window >= 1000000) {
        if (a->diag_suppressed) fprintf(stderr, "vban-pulse: %u diagnostics suppressed\n", a->diag_suppressed);
        a->diag_window = now; a->diag_count = 0; a->diag_suppressed = 0;
    }
    if (a->diag_count++ >= 5) { a->diag_suppressed++; return; }
    const pa_timing_info *timing = a->ready ? pa_stream_get_timing_info(a->stream) : NULL;
    const pa_buffer_attr *attr = a->ready ? pa_stream_get_buffer_attr(a->stream) : NULL;
    double server_ms = timing && !timing->read_index_corrupt && !timing->write_index_corrupt
        ? (timing->write_index - timing->read_index) * 1000.0 / BYTE_RATE : -1;
    fprintf(stderr, "vban-pulse: %s phase=%s queued_ms=%.1f server_queue_ms=%.1f latency_ms=%.1f ppm=%.0f "
        "tlength=%u maxlength=%u underflow=%" PRIu64 " server_overflow=%" PRIu64 " ring_overflow=%" PRIu64
        " discontinuities=%" PRIu64 " sessions=%" PRIu64 "\n", event, phase_names[a->phase], a->queued * 1000.0 / BYTE_RATE,
        server_ms, a->latency / 1000.0, a->ppm, attr ? attr->tlength : 0, attr ? attr->maxlength : 0,
        a->stats.underflow, a->stats.server_overflow, a->stats.overflow, a->stats.discontinuities, a->stats.sessions);
    fflush(stderr);
}
static void notify(struct app *a, const char *event) {
    char out[STATUS_BYTES]; status_json(a, out, sizeof(out), event); puts(out); fflush(stdout);
    if (a->subscriber_len && sendto(a->control_fd, out, strlen(out), MSG_DONTWAIT,
            (struct sockaddr *)&a->subscriber, a->subscriber_len) < 0 &&
            (errno == ENOENT || errno == ECONNREFUSED)) a->subscriber_len = 0;
}
static void clear_packets(struct app *a) { memset(a->packets, 0, sizeof(a->packets)); a->queued = 0; a->gap_since = 0; }
static void pump(struct app *a, uint64_t now);
static void begin_idle(struct app *a);
static void reconcile(struct app *a);
static void set_rate(struct app *a, unsigned rate);
static void rate_info(pa_context *context, const pa_sink_input_info *info, int eol, void *userdata) {
    (void)context; struct app *a = userdata;
    if (eol < 0) { fail(a, "read playback rate"); return; }
    if (info) {
        a->server_rate = info->sample_spec.rate;
        snprintf(a->resampler, sizeof(a->resampler), "%s", info->resample_method ? info->resample_method : "none");
        if (a->server_rate != a->inflight_rate) { fail(a, "server playback rate mismatch"); return; }
    }
    if (eol > 0) {
        a->rate_pending = false;
        if (a->desired_rate != a->playback_rate) set_rate(a, a->desired_rate);
        else pump(a, mono_us());
    }
}
static void rate_set(pa_stream *stream, int success, void *userdata) {
    struct app *a = userdata;
    if (!success) { fail(a, "set playback rate"); return; }
    a->playback_rate = pa_stream_get_sample_spec(stream)->rate;
    if (a->playback_rate != a->inflight_rate) { fail(a, "client playback rate mismatch"); return; }
    a->rate_acks++;
    pa_operation *op = pa_context_get_sink_input_info(a->context, pa_stream_get_index(stream), rate_info, a);
    if (!op) fail(a, "query playback rate"); else unref(op);
}
static void set_rate(struct app *a, unsigned rate) {
    a->desired_rate = rate;
    if (!a->ready || a->rate_pending) return;
    a->rate_pending = true; a->inflight_rate = rate;
    pa_operation *op = pa_stream_update_sample_rate(a->stream, rate, rate_set, a);
    if (!op) fail(a, "playback rate operation"); else unref(op);
}
static void sync_next(pa_context *context, int success, void *userdata) {
    struct app *a = userdata;
    if (!success) {
        if (a->sync_stage == 1 && pa_context_errno(context) == PA_ERR_NOENTITY) {
            if (a->phone == a->sync_phone) { a->phone = -1; a->revision++; }
            if (a->held_phone == a->sync_phone) { a->held_phone = -1; a->revision++; }
        } else { fail(a, "output coordination"); return; }
    }
    pa_operation *op = NULL;
    pa_cvolume volume;
    switch (a->sync_stage++) {
    case 0:
        if (a->sync_phone >= 0) {
            pa_cvolume_set(&volume, 2, pa_sw_volume_from_linear(a->sync_mix ? 0.5 : 1));
            op = pa_context_set_sink_input_volume(context, (uint32_t)a->sync_phone, &volume, sync_next, a);
            break;
        }
        sync_next(context, 1, a); return;
    case 1:
        pa_cvolume_set(&volume, 2, pa_sw_volume_from_linear(a->sync_gain * (a->sync_mix ? 0.5 : 1)));
        op = pa_context_set_sink_input_volume(context, pa_stream_get_index(a->stream), &volume, sync_next, a); break;
    case 2:
        if (a->managed && !a->managed_ready) { a->sync_stage = 4; sync_next(context, 1, a); return; }
        if (a->sync_active) a->suspend_at = 0;
        if (a->sync_active) op = pa_context_suspend_sink_by_name(context, a->sink, 0, sync_next, a);
        else op = pa_context_set_sink_mute_by_name(context, a->sink, 1, sync_next, a);
        break;
    case 3:
        if (a->sync_active) op = pa_context_set_sink_mute_by_name(context, a->sink, 0, sync_next, a);
        else if (a->suspend_delay_ms) {
            /* Keep the muted device running briefly: resuming a suspended USB DAC
             * took ~120 ms and the audio queued meanwhile persists as extra latency. */
            a->suspend_at = mono_us() + a->suspend_delay_ms * 1000ULL;
            sync_next(context, 1, a); return;
        }
        else op = pa_context_suspend_sink_by_name(context, a->sink, 1, sync_next, a);
        break;
    default:
        a->synced_revision = a->sync_revision; a->syncing = false;
        if (a->synced_revision != a->revision) { reconcile(a); return; }
        for (unsigned i = 0; i < 16; i++) if (a->replies[i].used) {
            char out[STATUS_BYTES]; status_json(a, out, sizeof(out), "ack");
            sendto(a->control_fd, out, strlen(out), MSG_DONTWAIT,
                (struct sockaddr *)&a->replies[i].address, a->replies[i].len);
            a->replies[i].used = false;
        }
        pump(a, mono_us()); return;
    }
    if (!op) fail(a, "output coordination operation"); else unref(op);
}
static void reconcile(struct app *a) {
    if (!a->ready || a->syncing || a->revision == a->synced_revision) return;
    a->syncing = true; a->sync_stage = 0; a->sync_revision = a->revision;
    a->sync_phone = a->phone >= 0 ? a->phone : a->held_phone; a->sync_gain = a->gain;
    a->sync_active = a->active || a->phone >= 0 || a->phone_pending;
    a->sync_mix = a->active && (a->phone >= 0 || a->phone_pending);
    sync_next(a->context, 1, a);
}

static void flushed(pa_stream *stream, int success, void *userdata) {
    (void)stream; struct app *a = userdata;
    if (!success) { fail(a, "flush"); return; }
    a->underrun_pending = false;
    a->phase = IDLE;
    if (a->ending) { a->active = false; a->ending = false; a->revision++; reconcile(a); notify(a, "inactive"); }
    /* UDP arriving during cork/flush is held in the fixed packet ring. */
    if (a->active) { a->phase = PRIMING; pump(a, mono_us()); }
    else { notify(a, "idle"); diag(a, "idle"); }
}
static void corked(pa_stream *stream, int success, void *userdata) {
    struct app *a = userdata;
    if (!success) { fail(a, "cork"); return; }
    a->phase = FLUSHING;
    pa_operation *op = pa_stream_flush(stream, flushed, a);
    if (!op) fail(a, "flush operation"); else unref(op);
}
static void drained(pa_stream *stream, int success, void *userdata) {
    (void)success; struct app *a = userdata;
    if (a->drain) { unref(a->drain); a->drain = NULL; }
    a->phase = CORKING;
    pa_operation *op = pa_stream_cork(stream, 1, corked, a);
    if (!op) fail(a, "cork operation"); else unref(op);
}
static void begin_idle(struct app *a) {
    a->ending = true; clear_packets(a);
    if (a->phase == PRIMING) { a->phase = CORKING; unref(pa_stream_cork(a->stream, 1, corked, a)); return; }
    a->phase = DRAINING;
    a->drain = pa_stream_drain(a->stream, drained, a);
    if (!a->drain) fail(a, "drain operation");
}
static void start_session(struct app *a, uint32_t sequence, uint64_t now) {
    if (a->drain) { pa_operation_cancel(a->drain); unref(a->drain); a->drain = NULL; }
    clear_packets(a); a->next_sequence = sequence; a->highest_sequence = sequence;
    a->sequence_valid = true; a->active = true; a->ending = false; a->started = now;
    update_target(a);
    a->backlog_ewma = a->target_backlog;
    a->ppm = 0;
    set_rate(a, RATE);
    a->integral = 0; a->last_adjust = now; a->control_time = now;
    if (a->phase != CORKING && a->phase != FLUSHING) a->phase = PRIMING;
    a->stats.sessions++; a->revision++; reconcile(a); notify(a, "active"); diag(a, "session");
}
static bool have_future(struct app *a) {
    return (int32_t)(a->highest_sequence - a->next_sequence) > 0;
}
static void pump(struct app *a, uint64_t now) {
    if (!a->ready || !a->active || a->ending || a->pumping || a->syncing || a->synced_revision != a->revision ||
            (a->managed && !a->managed_ready) ||
            (a->phase != PRIMING && a->phase != PLAYING)) return;
    if (a->phase == PRIMING && now - a->started < a->jitter_ms * 1000U) return;
    if (a->phase == PRIMING) {
        if (a->rate_pending) return;
        const pa_buffer_attr *attr = pa_stream_get_buffer_attr(a->stream);
        uint64_t packet_us = a->previous_size * 1000000U / BYTE_RATE;
        double fill_deadline = fmax(a->latency_ms * 1000.0,
                                   attr ? attr->tlength * 1000000.0 / BYTE_RATE : 0);
        /* Fill the one negotiated queue once; a short notification still starts
         * when its next packet does not arrive. This is not a second PCM buffer. */
        if (attr && a->queued < attr->tlength && now - a->started < fill_deadline &&
                now - a->last_valid < packet_us + 1000) return;
    }
    a->pumping = true;
    size_t writable = pa_stream_writable_size(a->stream);
    if (writable == (size_t)-1) { a->pumping = false; fail(a, "writable size"); return; }
    writable -= writable % FRAME_BYTES;
    unsigned work = 0; size_t wrote = 0;
    while (writable && work++ < SLOTS) {
        struct packet *p = &a->packets[a->next_sequence % SLOTS];
        if (!p->used || p->sequence != a->next_sequence) {
            if (!have_future(a)) break;
            if (!a->gap_since) a->gap_since = now;
            if (now - a->gap_since < a->jitter_ms * 1000U) break;
            /* One bounded PLC block per missing sequence, never from sequence-sized allocation. */
            unsigned missing_run = 1;
            while (missing_run < SLOTS) {
                struct packet *future = &a->packets[(a->next_sequence + missing_run) % SLOTS];
                if (future->used && future->sequence == a->next_sequence + missing_run) break;
                missing_run++;
            }
            if (missing_run == SLOTS) break;
            if (missing_run * a->previous_size > BYTE_RATE * 20U / 1000U) {
                a->stats.discontinuities++; diag(a, "discontinuity");
                /* Already-arrived successors are not missing packets. Preserve
                 * them and skip only the long absent sequence run. */
                a->next_sequence += missing_run;
                continue;
            }
            p->used = true; p->concealed = true; p->sequence = a->next_sequence; p->size = a->previous_size;
            p->offset = 0; memset(p->pcm, 0, p->size); a->queued += p->size; a->stats.missing++;
        }
        if (!p->concealed) a->gap_since = 0;
        size_t count = p->size - p->offset;
        if (count > writable) count = writable;
        /* With prebuf=0 the server may read beyond the write index. Start fresh
         * after a real underrun instead of writing indefinitely behind playback. */
        int64_t offset = a->underrun_pending ? BYTE_RATE * a->jitter_ms / 1000 : 0;
        pa_seek_mode_t seek = a->underrun_pending ? PA_SEEK_RELATIVE_ON_READ : PA_SEEK_RELATIVE;
        if (pa_stream_write(a->stream, p->pcm + p->offset, count, NULL, offset, seek) < 0) {
            a->pumping = false; fail(a, "PCM write"); return;
        }
        a->underrun_pending = false;
        p->offset += count; a->queued -= count; a->stats.written_bytes += count;
        writable -= count; wrote += count;
        if (p->offset == p->size) { a->previous_size = p->size; p->used = false; a->next_sequence++; }
    }
    if (a->phase == PRIMING && wrote) {
        a->phase = PLAYING;
        unref(pa_stream_cork(a->stream, 0, NULL, NULL));
        notify(a, "playing");
    }
    a->pumping = false;
}
static uint32_t read_u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void receive_packet(struct app *a, const uint8_t *data, size_t size, const struct sockaddr_in *source, uint64_t now) {
    if (source->sin_addr.s_addr != a->source.s_addr) { a->stats.wrong_source++; return; }
    if (size < 28 || memcmp(data, "VBAN", 4) || data[4] != 3 || data[6] != 1 || data[7] != 1 ||
        size != 28U + ((unsigned)data[5] + 1U) * FRAME_BYTES ||
        strnlen((const char *)data + 8, 16) != strlen(a->name) || memcmp(data + 8, a->name, strlen(a->name))) {
        a->stats.invalid++; return;
    }
    uint32_t sequence = read_u32(data + 24);
    if (a->last_valid && now - a->last_valid >= a->idle_ms * 1000U) a->sequence_valid = false;
    bool nonzero = false;
    for (size_t i = 28; i < size; i++) if (data[i]) { nonzero = true; break; }
    if (a->sequence_valid && (int32_t)(sequence - a->next_sequence) < 0) { a->stats.late++; return; }
    if (a->sequence_valid) {
        struct packet *old = &a->packets[sequence % SLOTS];
        if (old->used && old->sequence == sequence) { a->stats.duplicate++; return; }
    }
    a->last_valid = now; if (nonzero) a->last_nonzero = now;
    a->stats.accepted++;
    if ((!a->active || a->ending) && !nonzero) { a->next_sequence = sequence + 1; a->sequence_valid = true; return; }
    if (!a->active || a->ending) start_session(a, sequence, now);
    else if (!a->sequence_valid) { clear_packets(a); a->next_sequence = sequence; a->highest_sequence = sequence; a->sequence_valid = true; a->stats.discontinuities++; diag(a, "discontinuity"); }
    if ((uint32_t)(sequence - a->next_sequence) >= SLOTS || a->queued + size - 28 > BYTE_RATE * 40U / 1000U) {
        clear_packets(a); a->next_sequence = sequence; a->stats.overflow++; diag(a, "ring_overflow");
        /* Do not flush in-flight PCM: cap the application queue and recover on fresh input. */
    }
    struct packet *p = &a->packets[sequence % SLOTS];
    p->used = true; p->concealed = false; p->sequence = sequence; p->size = size - 28; p->offset = 0;
    memcpy(p->pcm, data + 28, p->size); a->queued += p->size;
    if ((int32_t)(sequence - a->highest_sequence) > 0) a->highest_sequence = sequence;
    pump(a, now);
}
static void udp_read(pa_mainloop_api *api, pa_io_event *event, int fd, pa_io_event_flags_t flags, void *userdata) {
    (void)api; (void)event; (void)flags; struct app *a = userdata;
    for (unsigned work = 0; work < 256; work++) {
        uint8_t data[2048]; struct sockaddr_in source; socklen_t len = sizeof(source);
        ssize_t n = recvfrom(fd, data, sizeof(data), 0, (struct sockaddr *)&source, &len);
        if (n < 0) { if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) perror("UDP receive"); break; }
        receive_packet(a, data, (size_t)n, &source, mono_us());
    }
}
static void control_read(pa_mainloop_api *api, pa_io_event *event, int fd, pa_io_event_flags_t flags, void *userdata) {
    (void)api; (void)event; (void)flags; struct app *a = userdata;
    char command[128], out[STATUS_BYTES]; struct sockaddr_un address; socklen_t len = sizeof(address);
    ssize_t n = recvfrom(fd, command, sizeof(command) - 1, 0, (struct sockaddr *)&address, &len);
    if (n < 0) return;
    command[n] = 0;
    if (!strcmp(command, "SUBSCRIBE")) { a->subscriber = address; a->subscriber_len = len; }
    if (!strcmp(command, "STATUS") || !strcmp(command, "SUBSCRIBE")) status_json(a, out, sizeof(out), "status");
    else if (!strcmp(command, "HOLD") && a->ready) {
        unsigned slot; for (slot = 0; slot < 16 && a->replies[slot].used; slot++);
        if (slot < 16) {
            if (a->phone >= 0) a->held_phone = a->phone;
            a->phone = -1; a->phone_pending = true;
            a->replies[slot] = (struct reply){true, address, len}; a->revision++; reconcile(a); return;
        }
        snprintf(out, sizeof(out), "{\"ok\":false,\"error\":\"control_busy\"}");
    }
    else if ((!strncmp(command, "GAIN ", 5) || !strncmp(command, "PHONE ", 6)) && a->ready) {
        bool is_gain = command[0] == 'G'; char *start = command + (is_gain ? 5 : 6), *end = NULL;
        errno = 0; double gain = is_gain ? strtod(start, &end) : 0;
        long long phone = is_gain ? -1 : strtoll(start, &end, 10);
        bool valid = end != start && !*end && !errno && (is_gain ? isfinite(gain) && gain >= 0 && gain <= 1 : phone >= -1 && phone < UINT32_MAX);
        unsigned slot; for (slot = 0; slot < 16 && a->replies[slot].used; slot++);
        if (valid && slot < 16) {
            if (is_gain) a->gain = gain; else { a->phone = phone; a->phone_pending = false; a->held_phone = -1; a->managed_ready = true; }
            a->replies[slot] = (struct reply){true, address, len}; a->revision++; reconcile(a); return;
        }
        snprintf(out, sizeof(out), "{\"ok\":false,\"error\":\"invalid_control_or_busy\"}");
    } else snprintf(out, sizeof(out), "{\"ok\":false,\"error\":\"unknown_command_or_not_ready\"}");
    sendto(fd, out, strlen(out), MSG_DONTWAIT, (struct sockaddr *)&address, len);
}
static void write_ready(pa_stream *stream, size_t count, void *userdata) { (void)stream; (void)count; pump(userdata, mono_us()); }
static void underflow(pa_stream *stream, void *userdata) { (void)stream; struct app *a = userdata; if (a->active) { a->stats.underflow++; a->underrun_pending = true; notify(a, "underflow"); diag(a, "underflow"); } }
/* The server dropped written PCM because its queue was full (PulseAudio logs
 * "Failed to push data into queue"). */
static void overflow(pa_stream *stream, void *userdata) { (void)stream; struct app *a = userdata; a->stats.server_overflow++; notify(a, "server_overflow"); diag(a, "server_overflow"); }
static void attr_changed(pa_stream *stream, void *userdata) {
    (void)stream;
    struct app *a = userdata;
    update_target(a);
    notify(a, "buffer_attr");
}
static void stream_state(pa_stream *stream, void *userdata) {
    struct app *a = userdata;
    switch (pa_stream_get_state(stream)) {
    case PA_STREAM_READY: a->ready = true; update_target(a); a->revision++; reconcile(a); notify(a, "ready"); break;
    case PA_STREAM_FAILED: case PA_STREAM_TERMINATED: fail(a, "Pulse stream unavailable"); break;
    default: break;
    }
}
static void context_state(pa_context *context, void *userdata) {
    struct app *a = userdata;
    switch (pa_context_get_state(context)) {
    case PA_CONTEXT_READY: {
        pa_sample_spec spec = {PA_SAMPLE_S16LE, RATE, 2};
        pa_proplist *props = pa_proplist_new();
        pa_proplist_sets(props, PA_PROP_APPLICATION_NAME, "lan-audio-bridge-desktop-native");
        pa_proplist_sets(props, PA_PROP_MEDIA_ROLE, "production");
        a->stream = pa_stream_new_with_proplist(context, "Windows desktop native", &spec, NULL, props);
        pa_proplist_free(props);
        if (!a->stream) { fail(a, "create stream"); return; }
        pa_stream_set_state_callback(a->stream, stream_state, a);
        pa_stream_set_write_callback(a->stream, write_ready, a);
        pa_stream_set_underflow_callback(a->stream, underflow, a);
        pa_stream_set_overflow_callback(a->stream, overflow, a);
        pa_stream_set_buffer_attr_callback(a->stream, attr_changed, a);
        pa_buffer_attr attr = {BYTE_RATE * 40 / 1000, BYTE_RATE * a->latency_ms / 1000, 0, BYTE_RATE * 2 / 1000, (uint32_t)-1};
        pa_cvolume volume; pa_cvolume_set(&volume, 2, pa_sw_volume_from_linear(a->gain));
        pa_stream_flags_t flags = PA_STREAM_START_CORKED | PA_STREAM_ADJUST_LATENCY | PA_STREAM_VARIABLE_RATE |
            PA_STREAM_AUTO_TIMING_UPDATE | PA_STREAM_INTERPOLATE_TIMING | PA_STREAM_DONT_MOVE;
        if (pa_stream_connect_playback(a->stream, a->sink, &attr, flags, &volume, NULL) < 0) fail(a, "connect playback");
        break;
    }
    case PA_CONTEXT_FAILED: case PA_CONTEXT_TERMINATED: fail(a, "Pulse context unavailable"); break;
    default: break;
    }
}
static void timing_updated(pa_stream *stream, int success, void *userdata) {
    struct app *a = userdata; a->timing_pending = false;
    const pa_timing_info *timing = success ? pa_stream_get_timing_info(stream) : NULL;
    if (timing) update_target(a);
    if (!timing || timing->read_index_corrupt || timing->write_index_corrupt || a->phase != PLAYING) return;
    /* Index differences remain valid across rate changes. pa_stream_get_latency
     * interpolation may transiently jump while its time smoother changes rate. */
    double buffered = (timing->write_index - timing->read_index) * 1000000.0 / (a->playback_rate * FRAME_BYTES);
    a->read_index = timing->read_index; a->write_index = timing->write_index;
    a->sink_usec = timing->sink_usec; a->transport_usec = timing->transport_usec;
    double total = fmax(0, buffered + timing->sink_usec + timing->transport_usec);
    if (total > 100000) return;
    a->latency = (pa_usec_t)total; a->latency_negative = buffered < 0;
    uint64_t now = mono_us();
    double dt = fmin(0.25, (now - a->control_time) / 1000000.0);
    a->control_time = now;
    double backlog = a->queued * 1000000.0 / BYTE_RATE + total;
    a->backlog_ewma += (backlog - a->backlog_ewma) * (1 - exp(-dt));
    if (now - a->started <= 2000000 || now - a->last_valid > 10000) return;
    double error_ms = (a->backlog_ewma - a->target_backlog) / 1000.0;
    /* The two clocks' errors add: a measured null sink was +386 ppm while
     * its sender was -200 ppm. A +/-500 ppm actuator cannot close that loop.
     * Integral authority must also cover the drift without requiring the
     * queue to remain near empty. Slew remains 200 ppm per second. */
    a->integral = fmax(-1500, fmin(1500, a->integral + error_ms * 20 * dt));
    double wanted = fmax(-MAX_RATE_PPM, fmin(MAX_RATE_PPM, error_ms * 200 + a->integral));
    double step = 200 * dt;
    a->ppm += fmax(-step, fmin(step, wanted - a->ppm));
    unsigned rate = (unsigned)lround(RATE * (1 + a->ppm / 1000000.0));
    if (rate != a->playback_rate) set_rate(a, rate);
}
static void timer_tick(pa_mainloop_api *api, pa_time_event *event, const struct timeval *tv, void *userdata) {
    (void)tv; struct app *a = userdata; uint64_t now = mono_us();
    if (stopped) { api->quit(api, 0); return; }
    if (a->ready) {
        if (a->active && !a->ending && (a->phase == PLAYING || a->phase == PRIMING) &&
            (now - a->last_valid >= a->idle_ms * 1000U || now - a->last_nonzero >= a->idle_ms * 1000U)) begin_idle(a);
        pump(a, now);
        if (a->suspend_at && now >= a->suspend_at && !a->syncing) {
            a->suspend_at = 0;
            /* The last reconcile found nothing active; a later activation reconciles again and resumes. */
            if (!a->active && a->phone < 0 && !a->phone_pending)
                unref(pa_context_suspend_sink_by_name(a->context, a->sink, 1, NULL, NULL));
        }
        if (a->phase == PLAYING && !a->timing_pending && now - a->last_adjust >= 100000) {
            /* Regulate total application + Pulse backlog, not packet-arrival interval.
             * Low-pass a full second and bound correction/slew to avoid audible pitch jumps. */
            pa_operation *op = pa_stream_update_timing_info(a->stream, timing_updated, a);
            if (op) { a->timing_pending = true; unref(op); }
            a->last_adjust = now;
        }
    }
    if (now - a->last_report >= 1000000) { notify(a, "statistics"); a->last_report = now; }
    struct timeval next; pa_gettimeofday(&next); pa_timeval_add(&next, 1000); api->time_restart(event, &next);
}
static void signal_stop(int signum) { (void)signum; stopped = 1; }
static unsigned number(const char *value, unsigned low, unsigned high) {
    char *end; errno = 0; unsigned long n = strtoul(value, &end, 10);
    if (errno || !*value || *end || n < low || n > high) { fprintf(stderr, "Invalid numeric argument: %s\n", value); exit(2); } return (unsigned)n;
}
int main(int argc, char **argv) {
    struct app app = {.udp_fd = -1, .control_fd = -1, .sink = "output", .port = 6980,
        .latency_ms = 16, .jitter_ms = 8, .idle_ms = 500, .gain = 1, .phone = -1, .held_phone = -1, .playback_rate = RATE, .previous_size = 512, .scheduling = "default"};
    struct app *a = &app; const char *source = NULL; strcpy(a->name, "Windows");
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--managed")) { a->managed = true; continue; }
        if (!strcmp(argv[i], "--realtime")) {
            /* Best effort within RLIMIT_RTPRIO / RLIMIT_NICE; no capability is required or kept. */
            struct sched_param param = {.sched_priority = 4};
            if (sched_setscheduler(0, SCHED_FIFO | SCHED_RESET_ON_FORK, &param) == 0) a->scheduling = "fifo";
            else if (setpriority(PRIO_PROCESS, 0, -11) == 0) a->scheduling = "nice";
            else a->scheduling = "normal";
            continue;
        }
        if (i + 1 >= argc) { fprintf(stderr, "Expected option value\n"); return 2; }
        const char *option = argv[i++], *value = argv[i];
        if (!strcmp(option, "--source-ip")) source = value;
        else if (!strcmp(option, "--server")) a->server = value;
        else if (!strcmp(option, "--sink")) a->sink = value;
        else if (!strcmp(option, "--control")) a->control_path = value;
        else if (!strcmp(option, "--port")) a->port = number(value, 1, 65535);
        else if (!strcmp(option, "--latency-ms")) a->latency_ms = number(value, 4, 30);
        else if (!strcmp(option, "--jitter-ms")) a->jitter_ms = number(value, 1, 20);
        else if (!strcmp(option, "--idle-ms")) a->idle_ms = number(value, 100, 5000);
        else if (!strcmp(option, "--suspend-delay-ms")) a->suspend_delay_ms = number(value, 0, 600000);
        else if (!strcmp(option, "--gain")) { char *end; a->gain = strtod(value, &end); if (end == value || *end || !isfinite(a->gain) || a->gain < 0 || a->gain > 1) return 2; }
        else if (!strcmp(option, "--stream-name") || !strcmp(option, "--stream")) { if (!*value || strlen(value) > 16) return 2; strcpy(a->name, value); }
        else { fprintf(stderr, "Unknown option: %s\n", option); return 2; }
    }
    if (!source || inet_pton(AF_INET, source, &a->source) != 1) { fprintf(stderr, "--source-ip IPv4 is required\n"); return 2; }
    a->loop = pa_mainloop_new(); a->api = pa_mainloop_get_api(a->loop);
    a->udp_fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(a->port), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (a->udp_fd < 0 || bind(a->udp_fd, (struct sockaddr *)&address, sizeof(address)) < 0) { perror("UDP bind"); return 1; }
    int receive_size = 65536; setsockopt(a->udp_fd, SOL_SOCKET, SO_RCVBUF, &receive_size, sizeof(receive_size));
    a->api->io_new(a->api, a->udp_fd, PA_IO_EVENT_INPUT, udp_read, a);
    if (a->control_path) {
        struct sockaddr_un control = {.sun_family = AF_UNIX};
        if (strlen(a->control_path) >= sizeof(control.sun_path)) return 2;
        strcpy(control.sun_path, a->control_path);
        a->control_fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        /* Do not unlink another live receiver's socket. Caller owns stale-file cleanup. */
        if (a->control_fd < 0 || bind(a->control_fd, (struct sockaddr *)&control, sizeof(control)) < 0) { perror("Control bind"); return 1; }
        chmod(a->control_path, 0600);
        a->api->io_new(a->api, a->control_fd, PA_IO_EVENT_INPUT, control_read, a);
    }
    a->context = pa_context_new(a->api, "LAN Audio Bridge Native VBAN");
    pa_context_set_state_callback(a->context, context_state, a);
    if (pa_context_connect(a->context, a->server, PA_CONTEXT_NOAUTOSPAWN, NULL) < 0) { fail(a, "context connect"); return 1; }
    struct timeval timer; pa_gettimeofday(&timer); a->timer = a->api->time_new(a->api, &timer, timer_tick, a);
    signal(SIGINT, signal_stop); signal(SIGTERM, signal_stop);
    int result = 0; pa_mainloop_run(a->loop, &result);
    if (a->drain) { pa_operation_cancel(a->drain); unref(a->drain); }
    if (a->stream) { pa_stream_set_state_callback(a->stream, NULL, NULL); pa_stream_disconnect(a->stream); pa_stream_unref(a->stream); }
    pa_context_set_state_callback(a->context, NULL, NULL); pa_context_disconnect(a->context); pa_context_unref(a->context);
    close(a->udp_fd); if (a->control_fd >= 0) { close(a->control_fd); unlink(a->control_path); }
    pa_mainloop_free(a->loop); return result;
}

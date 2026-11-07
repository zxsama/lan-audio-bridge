// SPDX-License-Identifier: MIT
// Low-latency Windows system-audio -> VBAN PCM16 sender.
//
// Captures the shared-mode mix of one render endpoint with event-driven WASAPI
// loopback and forwards every capture packet immediately as 48 kHz stereo s16le
// VBAN. There is no intermediate ring buffer: the only queue on this side is the
// Windows engine period itself. Loopback is tapped after the engine's software
// endpoint volume/mute but before any hardware volume/mute. The sender therefore
// applies exactly the parts the endpoint implements in hardware
// (IAudioEndpointVolume::QueryHardwareSupport), so Windows volume behaves the same
// on every device without double attenuation.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <avrt.h>
#include <ksmedia.h>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cwchar>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "avrt.lib")
#pragma comment(lib, "user32.lib")

namespace {

constexpr unsigned kRate = 48000;
constexpr unsigned kChannels = 2;
constexpr unsigned kMaxVbanFrames = 256;
constexpr REFERENCE_TIME kRetryHns = 5000000;  // 500 ms
constexpr const wchar_t *kStopEventName = L"Local\\LanAudioBridgeVbanSenderStop";

struct Options {
    wchar_t target[64] = L"";
    unsigned port = 6980;
    char stream[17] = "Windows";
    wchar_t device[512] = L"";  // empty = follow default console render endpoint
    unsigned frames = 128;      // VBAN frames per datagram, 1..256
    bool endpoint_volume = true;
    bool keeper = true;         // hold the endpoint's minimum engine period
    bool volume_sync = true;    // keep all preferred endpoints at the same volume/mute
    unsigned idle_ms = 2000;    // stop sending digital silence after this long; 0 = keep the stream connected
    unsigned stats_ms = 0;
    bool list = false;
    wchar_t log_path[MAX_PATH] = L"";
    // Ordered default-endpoint preference; empty disables the policy.
    static constexpr unsigned kMaxPrefer = 8;
    wchar_t prefer[kMaxPrefer][256] = {};
    unsigned prefer_count = 0;
};

struct Stats {
    uint64_t capture_packets = 0, frames = 0, datagrams = 0, send_errors = 0, discontinuities = 0,
             silent_packets = 0, suppressed = 0, reopen = 0, clipped = 0;
    double max_gap_ms = 0;
};

std::atomic<float> g_gain{1.0f};
std::atomic<bool> g_mute{false};
std::atomic<DWORD> g_hardware{0};  // ENDPOINT_HARDWARE_SUPPORT_* of the captured endpoint
HANDLE g_stop = nullptr, g_reopen = nullptr, g_policy = nullptr;
HANDLE g_volume_devices = nullptr, g_volume_changed = nullptr;  // volume sync wake-ups
HANDLE g_log = INVALID_HANDLE_VALUE;
SRWLOCK g_log_lock = SRWLOCK_INIT;
Options g_opt;

void log(const char *fmt, ...) {
    char buffer[2048];
    va_list args; va_start(args, fmt); int n = vsnprintf(buffer, sizeof(buffer), fmt, args); va_end(args);
    if (n <= 0) return;
    if (n >= (int)sizeof(buffer)) n = sizeof(buffer) - 1;
    HANDLE h = g_log != INVALID_HANDLE_VALUE ? g_log : GetStdHandle(STD_ERROR_HANDLE);
    DWORD written;
    AcquireSRWLockExclusive(&g_log_lock);
    if (h && h != INVALID_HANDLE_VALUE) WriteFile(h, buffer, (DWORD)n, &written, nullptr);
    ReleaseSRWLockExclusive(&g_log_lock);
}

// Minimal JSON string escaping for endpoint names and IDs.
void json_text(const wchar_t *in, char *out, size_t size) {
    char utf8[1024];
    if (!WideCharToMultiByte(CP_UTF8, 0, in ? in : L"", -1, utf8, sizeof(utf8), nullptr, nullptr)) utf8[0] = 0;
    size_t o = 0;
    for (const unsigned char *p = (const unsigned char *)utf8; *p && o + 7 < size; p++) {
        if (*p == '"' || *p == '\\') { out[o++] = '\\'; out[o++] = (char)*p; }
        else if (*p < 0x20) o += snprintf(out + o, size - o, "\\u%04x", *p);
        else out[o++] = (char)*p;
    }
    out[o] = 0;
}

double now_ms() {
    static LARGE_INTEGER f = [] { LARGE_INTEGER x; QueryPerformanceFrequency(&x); return x; }();
    LARGE_INTEGER t; QueryPerformanceCounter(&t);
    return t.QuadPart * 1000.0 / f.QuadPart;
}

template <class T> void release(T *&p) { if (p) { p->Release(); p = nullptr; } }

// Undocumented but long-stable Windows interface used by the Sound control panel
// to change the default endpoint (same vtable as scripts/windows/AudioInterop.cs).
struct __declspec(uuid("f8679f50-850a-41cf-9c72-430f290290c8")) IPolicyConfig : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE GetMixFormat(PCWSTR, WAVEFORMATEX **) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetDeviceFormat(PCWSTR, INT, WAVEFORMATEX **) = 0;
    virtual HRESULT STDMETHODCALLTYPE ResetDeviceFormat(PCWSTR) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetDeviceFormat(PCWSTR, WAVEFORMATEX *, WAVEFORMATEX *) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetProcessingPeriod(PCWSTR, INT, PINT64, PINT64) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetProcessingPeriod(PCWSTR, PINT64) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetShareMode(PCWSTR, void *) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetShareMode(PCWSTR, void *) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetPropertyValue(PCWSTR, const PROPERTYKEY &, PROPVARIANT *) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetPropertyValue(PCWSTR, const PROPERTYKEY &, PROPVARIANT *) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetDefaultEndpoint(PCWSTR, ERole) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetEndpointVisibility(PCWSTR, INT) = 0;
};
const CLSID kPolicyConfigClient = {0x870af99c, 0x171d, 0x4f9e, {0xaf, 0x0d, 0xe6, 0x3d, 0xf4, 0x0c, 0x2b, 0xc9}};

// Follows the default console render endpoint when no explicit device is given,
// and wakes the preference policy on any endpoint change.
class DeviceEvents final : public IMMNotificationClient {
    std::atomic<ULONG> refs{1};
public:
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = --refs; if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) { *out = this; AddRef(); return S_OK; }
        *out = nullptr; return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
        if (flow == eRender && role == eConsole) {
            if (!g_opt.device[0]) SetEvent(g_reopen);
            if (g_policy) SetEvent(g_policy);
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { wake(); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { wake(); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { wake(); return S_OK; }
    static void wake() { if (g_policy) SetEvent(g_policy); if (g_volume_devices) SetEvent(g_volume_devices); }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }
};

// Keeps the Windows default render endpoint on the best available preferred
// device: moves to a higher-ranked preferred endpoint when it (re)appears, and
// replaces a fallback Windows chose after the previous default disappeared.
// A non-preferred default the user selected while ours was still present is kept.
DWORD WINAPI policy_thread(LPVOID) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator *enumerator = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&enumerator))) {
        CoUninitialize(); return 1;
    }
    wchar_t previous[256] = L"";  // last default we observed
    bool first = true;
    HANDLE waits[2] = {g_stop, g_policy};
    for (;;) {
        if (!first) {
            if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0) break;
            // Debounce: device removal fires several notifications in a burst.
            if (WaitForSingleObject(g_stop, 400) == WAIT_OBJECT_0) break;
            ResetEvent(g_policy);
        }
        auto active = [&](const wchar_t *id) {
            IMMDevice *d = nullptr; DWORD state = 0;
            bool ok = SUCCEEDED(enumerator->GetDevice(id, &d)) && SUCCEEDED(d->GetState(&state)) && state == DEVICE_STATE_ACTIVE;
            release(d); return ok;
        };
        int best = -1;
        for (unsigned i = 0; i < g_opt.prefer_count && best < 0; i++) if (active(g_opt.prefer[i])) best = (int)i;
        wchar_t current[256] = L"";
        IMMDevice *d = nullptr; LPWSTR id = nullptr;
        if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &d)) && SUCCEEDED(d->GetId(&id))) {
            wcsncpy_s(current, id, _TRUNCATE); CoTaskMemFree(id);
        }
        release(d);
        int rank = -1;
        for (unsigned i = 0; i < g_opt.prefer_count; i++) if (!_wcsicmp(current, g_opt.prefer[i])) rank = (int)i;
        bool previous_gone = previous[0] && _wcsicmp(previous, current) && !active(previous);
        const char *reason = nullptr;
        if (best >= 0 && rank != best) {
            if (first) reason = "startup";
            else if (rank > best) reason = "preferred_available";
            else if (rank < 0 && previous_gone) reason = "fallback_replaced";
        }
        if (reason) {
            IPolicyConfig *policy = nullptr;
            HRESULT hr = CoCreateInstance(kPolicyConfigClient, nullptr, CLSCTX_ALL, __uuidof(IPolicyConfig), (void **)&policy);
            if (SUCCEEDED(hr)) hr = policy->SetDefaultEndpoint(g_opt.prefer[best], eConsole);
            if (SUCCEEDED(hr)) hr = policy->SetDefaultEndpoint(g_opt.prefer[best], eMultimedia);
            release(policy);
            char from[600], to[600]; json_text(current, from, sizeof(from)); json_text(g_opt.prefer[best], to, sizeof(to));
            log("{\"event\":\"default_endpoint\",\"reason\":\"%s\",\"from\":\"%s\",\"to\":\"%s\",\"hresult\":\"0x%08lx\"}\n",
                reason, from, to, (unsigned long)hr);
            if (SUCCEEDED(hr)) wcsncpy_s(current, g_opt.prefer[best], _TRUNCATE);
        } else if (!first && rank < 0 && current[0] && _wcsicmp(previous, current)) {
            char now_id[600]; json_text(current, now_id, sizeof(now_id));
            log("{\"event\":\"default_endpoint\",\"reason\":\"user_selected\",\"to\":\"%s\"}\n", now_id);
        }
        wcsncpy_s(previous, current, _TRUNCATE);
        first = false;
    }
    release(enumerator);
    CoUninitialize();
    return 0;
}

// Keeps every preferred endpoint at one shared volume and mute, so the NAS
// outputs ("NAS audio" and its backup) behave like a single device. Changes
// made here carry kSyncContext and are ignored when they echo back.
const GUID kSyncContext = {0x6c1f3d2a, 0x47b9, 0x4e8e, {0x9a, 0x21, 0x5d, 0x0b, 0x8f, 0x37, 0xc2, 0x64}};
struct SharedVolume { float scalar = 0; BOOL mute = FALSE; bool valid = false; int source = -1; };
SRWLOCK g_shared_lock = SRWLOCK_INIT;
SharedVolume g_shared;

class SyncEvents final : public IAudioEndpointVolumeCallback {
    std::atomic<ULONG> refs{1};
    int index;
public:
    explicit SyncEvents(int i) : index(i) {}
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = --refs; if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IAudioEndpointVolumeCallback)) { *out = this; AddRef(); return S_OK; }
        *out = nullptr; return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnNotify(PAUDIO_VOLUME_NOTIFICATION_DATA data) override {
        if (IsEqualGUID(data->guidEventContext, kSyncContext)) return S_OK;  // our own change
        AcquireSRWLockExclusive(&g_shared_lock);
        g_shared.scalar = data->fMasterVolume; g_shared.mute = data->bMuted; g_shared.valid = true; g_shared.source = index;
        ReleaseSRWLockExclusive(&g_shared_lock);
        SetEvent(g_volume_changed);
        return S_OK;
    }
};

DWORD WINAPI volume_sync_thread(LPVOID) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator *enumerator = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&enumerator))) {
        CoUninitialize(); return 1;
    }
    IAudioEndpointVolume *volume[Options::kMaxPrefer] = {};
    SyncEvents *events[Options::kMaxPrefer] = {};
    auto close_all = [&] {
        for (unsigned i = 0; i < g_opt.prefer_count; i++) {
            if (volume[i] && events[i]) volume[i]->UnregisterControlChangeNotify(events[i]);
            release(events[i]); release(volume[i]);
        }
    };
    auto open_all = [&] {
        close_all();
        for (unsigned i = 0; i < g_opt.prefer_count; i++) {
            IMMDevice *d = nullptr; DWORD state = 0;
            if (SUCCEEDED(enumerator->GetDevice(g_opt.prefer[i], &d)) && SUCCEEDED(d->GetState(&state)) && state == DEVICE_STATE_ACTIVE &&
                SUCCEEDED(d->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, (void **)&volume[i]))) {
                events[i] = new SyncEvents((int)i);
                volume[i]->RegisterControlChangeNotify(events[i]);
            }
            release(d);
        }
    };
    auto apply = [&](const char *reason) {
        AcquireSRWLockShared(&g_shared_lock);
        SharedVolume shared = g_shared;
        ReleaseSRWLockShared(&g_shared_lock);
        if (!shared.valid) return;
        unsigned changed = 0;
        for (unsigned i = 0; i < g_opt.prefer_count; i++) {
            if (!volume[i] || (int)i == shared.source) continue;
            float scalar = 0; BOOL mute = FALSE;
            volume[i]->GetMasterVolumeLevelScalar(&scalar); volume[i]->GetMute(&mute);
            if (std::fabs(scalar - shared.scalar) > 0.001f) { volume[i]->SetMasterVolumeLevelScalar(shared.scalar, &kSyncContext); changed++; }
            if ((mute != FALSE) != (shared.mute != FALSE)) { volume[i]->SetMute(shared.mute, &kSyncContext); changed++; }
        }
        if (changed) log("{\"event\":\"volume_sync\",\"reason\":\"%s\",\"scalar\":%.3f,\"mute\":%s,\"source\":%d}\n",
                         reason, shared.scalar, shared.mute ? "true" : "false", shared.source);
    };
    open_all();
    // Startup: the current default output (if preferred) leads, otherwise the first active one.
    {
        int leader = -1;
        IMMDevice *d = nullptr; LPWSTR id = nullptr;
        if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &d)) && SUCCEEDED(d->GetId(&id))) {
            for (unsigned i = 0; i < g_opt.prefer_count; i++) if (volume[i] && !_wcsicmp(id, g_opt.prefer[i])) leader = (int)i;
            CoTaskMemFree(id);
        }
        release(d);
        for (unsigned i = 0; i < g_opt.prefer_count && leader < 0; i++) if (volume[i]) leader = (int)i;
        if (leader >= 0) {
            float scalar = 0; BOOL mute = FALSE;
            volume[leader]->GetMasterVolumeLevelScalar(&scalar); volume[leader]->GetMute(&mute);
            AcquireSRWLockExclusive(&g_shared_lock);
            g_shared.scalar = scalar; g_shared.mute = mute; g_shared.valid = true; g_shared.source = leader;
            ReleaseSRWLockExclusive(&g_shared_lock);
            apply("startup");
        }
    }
    HANDLE waits[3] = {g_stop, g_volume_changed, g_volume_devices};
    for (;;) {
        DWORD w = WaitForMultipleObjects(3, waits, FALSE, INFINITE);
        if (w == WAIT_OBJECT_0) break;
        if (w == WAIT_OBJECT_0 + 1) { apply("changed"); continue; }
        // A preferred endpoint may have (re)appeared with its own stored volume: align it.
        if (WaitForSingleObject(g_stop, 500) == WAIT_OBJECT_0) break;
        ResetEvent(g_volume_devices);
        open_all();
        AcquireSRWLockExclusive(&g_shared_lock);
        g_shared.source = -1;  // every endpoint follows the last shared value
        ReleaseSRWLockExclusive(&g_shared_lock);
        apply("device");
    }
    close_all();
    release(enumerator);
    CoUninitialize();
    return 0;
}

// Mirrors the endpoint's attenuation (dB) and mute; push() applies only hardware-implemented parts.
class VolumeEvents final : public IAudioEndpointVolumeCallback {
    std::atomic<ULONG> refs{1};
    IAudioEndpointVolume *volume;
public:
    explicit VolumeEvents(IAudioEndpointVolume *v) : volume(v) {}
    void refresh() {
        float db = 0; BOOL mute = FALSE;
        if (SUCCEEDED(volume->GetMasterVolumeLevel(&db))) g_gain.store(std::pow(10.0f, db / 20.0f));
        if (SUCCEEDED(volume->GetMute(&mute))) g_mute.store(mute != FALSE);
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = --refs; if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IAudioEndpointVolumeCallback)) { *out = this; AddRef(); return S_OK; }
        *out = nullptr; return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnNotify(PAUDIO_VOLUME_NOTIFICATION_DATA data) override {
        g_mute.store(data->bMuted != FALSE);
        float db = 0;
        if (SUCCEEDED(volume->GetMasterVolumeLevel(&db))) g_gain.store(std::pow(10.0f, db / 20.0f));
        return S_OK;
    }
};

struct Sender {
    SOCKET sock = INVALID_SOCKET;
    uint8_t packet[28 + kMaxVbanFrames * 4];
    uint32_t sequence = 0;
    float gain = 1.0f;  // smoothed, ramps per datagram
    uint32_t dither = 0x9e3779b9u;
    double last_audible = -1e18;
    bool sending = true;
    Stats stats;

    bool open(const Options &o) {
        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock == INVALID_SOCKET) return false;
        sockaddr_in to{}; to.sin_family = AF_INET; to.sin_port = htons((u_short)o.port);
        if (InetPtonW(AF_INET, o.target, &to.sin_addr) != 1) return false;
        int tos = 0xb8;  // DSCP EF; honoured only where QoS policy allows it.
        setsockopt(sock, IPPROTO_IP, IP_TOS, (const char *)&tos, sizeof(tos));
        int size = 1 << 16; setsockopt(sock, SOL_SOCKET, SO_SNDBUF, (const char *)&size, sizeof(size));
        if (connect(sock, (sockaddr *)&to, sizeof(to)) != 0) return false;
        memset(packet, 0, 28);
        memcpy(packet, "VBAN", 4);
        packet[4] = 3;  // audio sub-protocol, 48000 Hz index
        packet[6] = kChannels - 1;
        packet[7] = 1;  // PCM, INT16
        memcpy(packet + 8, o.stream, strlen(o.stream));
        return true;
    }
    float tpdf() {
        dither ^= dither << 13; dither ^= dither >> 17; dither ^= dither << 5; float a = (dither & 0xffff) / 65536.0f;
        dither ^= dither << 13; dither ^= dither >> 17; dither ^= dither << 5; float b = (dither & 0xffff) / 65536.0f;
        return a - b;
    }
    // `input` is interleaved float with `channels` channels, or null for silence.
    void push(const float *input, unsigned channels, unsigned count, double now) {
        DWORD hw = g_opt.endpoint_volume ? g_hardware.load() : 0;
        float wanted = (hw & ENDPOINT_HARDWARE_SUPPORT_MUTE) && g_mute.load() ? 0.0f
            : (hw & ENDPOINT_HARDWARE_SUPPORT_VOLUME) ? g_gain.load() : 1.0f;
        bool audible = false;
        if (input && wanted > 0) for (unsigned i = 0; i < count * channels && !audible; i++) audible = input[i] != 0.0f;
        if (audible) last_audible = now;
        bool want_send = audible || !g_opt.idle_ms || now - last_audible < g_opt.idle_ms;
        if (!want_send) { stats.suppressed++; sending = false; return; }
        sending = true;
        for (unsigned done = 0; done < count;) {
            unsigned n = count - done < g_opt.frames ? count - done : g_opt.frames;
            packet[5] = (uint8_t)(n - 1);
            packet[24] = (uint8_t)sequence; packet[25] = (uint8_t)(sequence >> 8);
            packet[26] = (uint8_t)(sequence >> 16); packet[27] = (uint8_t)(sequence >> 24);
            int16_t *out = (int16_t *)(packet + 28);
            float step = (wanted - gain) / n;
            for (unsigned j = 0; j < n; j++) {
                gain += step;
                const float *frame = input ? input + (size_t)(done + j) * channels : nullptr;
                for (unsigned ch = 0; ch < kChannels; ch++) {
                    float x = frame ? frame[channels == 1 ? 0 : ch] * gain : 0.0f;
                    if (x == 0.0f) { out[j * 2 + ch] = 0; continue; }  // keep digital silence exact
                    float v = x * 32767.0f + tpdf();
                    if (v > 32767.0f) { v = 32767.0f; stats.clipped++; }
                    else if (v < -32768.0f) { v = -32768.0f; stats.clipped++; }
                    out[j * 2 + ch] = (int16_t)lrintf(v);
                }
            }
            gain = wanted;
            if (send(sock, (const char *)packet, (int)(28 + n * 4), 0) < 0) stats.send_errors++;
            else stats.datagrams++;
            sequence++;
            done += n;
        }
    }
};

HRESULT open_device(IMMDeviceEnumerator *enumerator, IMMDevice **device) {
    if (g_opt.device[0]) return enumerator->GetDevice(g_opt.device, device);
    return enumerator->GetDefaultAudioEndpoint(eRender, eConsole, device);
}

void describe(IMMDevice *device, wchar_t *name, size_t size) {
    name[0] = 0;
    IPropertyStore *props = nullptr;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
        PROPVARIANT v; PropVariantInit(&v);
        if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &v)) && v.vt == VT_LPWSTR) wcsncpy_s(name, size, v.pwszVal, _TRUNCATE);
        PropVariantClear(&v); props->Release();
    }
}

// Silent shared-mode render stream at the endpoint's minimum engine period
// (IAudioClient3). The engine runs at the smallest period any client requests,
// so this shortens both the mix pull and the loopback packet for every app.
// It is topped up from the capture loop; an underrun only repeats silence.
struct Keeper {
    IAudioClient3 *client = nullptr; IAudioRenderClient *render = nullptr;
    UINT32 buffer = 0, period = 0; bool started = false;
    HRESULT open(IMMDevice *device, const WAVEFORMATEX *mix) {
        HRESULT hr = device->Activate(__uuidof(IAudioClient3), CLSCTX_ALL, nullptr, (void **)&client);
        if (FAILED(hr)) return hr;
        UINT32 def = 0, fundamental = 0, minimum = 0, maximum = 0;
        hr = client->GetSharedModeEnginePeriod(mix, &def, &fundamental, &minimum, &maximum);
        if (FAILED(hr)) return hr;
        if (minimum >= def) return S_FALSE;  // nothing to gain on fixed-period endpoints
        hr = client->InitializeSharedAudioStream(0, minimum, mix, nullptr);
        if (FAILED(hr)) return hr;
        period = minimum;
        if (FAILED(hr = client->GetBufferSize(&buffer))) return hr;
        if (FAILED(hr = client->GetService(__uuidof(IAudioRenderClient), (void **)&render))) return hr;
        BYTE *p = nullptr;
        if (FAILED(hr = render->GetBuffer(buffer, &p))) return hr;
        if (FAILED(hr = render->ReleaseBuffer(buffer, AUDCLNT_BUFFERFLAGS_SILENT))) return hr;
        if (FAILED(hr = client->Start())) return hr;
        started = true;
        return S_OK;
    }
    void top_up() {
        if (!started) return;
        UINT32 padding = 0; BYTE *p = nullptr;
        if (FAILED(client->GetCurrentPadding(&padding)) || padding >= buffer) return;
        if (SUCCEEDED(render->GetBuffer(buffer - padding, &p))) render->ReleaseBuffer(buffer - padding, AUDCLNT_BUFFERFLAGS_SILENT);
    }
    void close() { if (started) client->Stop(); started = false; release(render); release(client); }
};

// One capture session; returns when the device must be reopened or on stop.
HRESULT run_session(IMMDeviceEnumerator *enumerator, Sender &sender) {
    IMMDevice *device = nullptr; IAudioClient *client = nullptr; IAudioCaptureClient *capture = nullptr;
    IAudioEndpointVolume *volume = nullptr; VolumeEvents *volume_events = nullptr;
    WAVEFORMATEX *mix = nullptr; HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    Keeper keeper;
    HRESULT keeper_hr = S_FALSE;
    HRESULT hr = open_device(enumerator, &device);
    bool started = false;
    wchar_t name[256]; LPWSTR id = nullptr;
    WAVEFORMATEXTENSIBLE want{};
    const WAVEFORMATEX *format = nullptr;
    unsigned channels = 0;
    bool is_float = false;
    double last = 0;
    if (FAILED(hr)) goto done;
    describe(device, name, 256); device->GetId(&id);
    if (g_opt.prefer_count && id) {
        bool preferred = false;
        for (unsigned i = 0; i < g_opt.prefer_count; i++) preferred = preferred || !_wcsicmp(id, g_opt.prefer[i]);
        if (!preferred) {
            // The user chose another output (e.g. headphones): send nothing, so the
            // NAS idles normally, and leave that device's engine period alone.
            char jname[600]; json_text(name, jname, sizeof(jname));
            log("{\"event\":\"standby\",\"device\":\"%s\"}\n", jname);
            sender.sending = false;
            HANDLE waits[2] = {g_stop, g_reopen};
            DWORD w = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
            hr = w == WAIT_OBJECT_0 ? S_OK : AUDCLNT_E_DEVICE_INVALIDATED;
            goto done;
        }
    }
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&client);
    if (FAILED(hr)) goto done;
    hr = client->GetMixFormat(&mix);
    if (FAILED(hr)) goto done;
    // Native 48 kHz float mixes are captured unchanged; anything else is converted by the engine.
    is_float = mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
        (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE && ((WAVEFORMATEXTENSIBLE *)mix)->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    if (is_float && mix->nSamplesPerSec == kRate && mix->nChannels >= 1) {
        format = mix; channels = mix->nChannels;
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, format, nullptr);
    } else {
        want.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE; want.Format.nChannels = kChannels; want.Format.nSamplesPerSec = kRate;
        want.Format.wBitsPerSample = 32; want.Format.nBlockAlign = kChannels * 4; want.Format.nAvgBytesPerSec = kRate * kChannels * 4;
        want.Format.cbSize = 22; want.Samples.wValidBitsPerSample = 32; want.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
        want.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
        format = &want.Format; channels = kChannels;
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, 0, 0, format, nullptr);
    }
    if (FAILED(hr)) goto done;
    hr = client->SetEventHandle(ready);
    if (FAILED(hr)) goto done;
    hr = client->GetService(__uuidof(IAudioCaptureClient), (void **)&capture);
    if (FAILED(hr)) goto done;
    g_gain.store(1.0f); g_mute.store(false); g_hardware.store(0);
    if (SUCCEEDED(device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, (void **)&volume))) {
        volume_events = new VolumeEvents(volume);
        volume_events->refresh();
        DWORD hw = 0;
        if (SUCCEEDED(volume->QueryHardwareSupport(&hw))) g_hardware.store(hw);
        volume->RegisterControlChangeNotify(volume_events);
    }
    if (g_opt.keeper) {
        keeper_hr = keeper.open(device, mix);
        if (FAILED(keeper_hr)) keeper.close();  // optional: fall back to the default engine period
    }
    {
        UINT32 buffer = 0; REFERENCE_TIME period = 0, minimum = 0;
        client->GetBufferSize(&buffer); client->GetDevicePeriod(&period, &minimum);
        char jname[600]; json_text(name, jname, sizeof(jname));  // %ls fails for non-ASCII names in the C locale
        log("{\"event\":\"capture\",\"device\":\"%s\",\"rate\":%lu,\"mix_channels\":%u,\"converted\":%s,\"buffer_frames\":%u,\"period_ms\":%.3f,\"keeper_frames\":%u,\"keeper_hresult\":\"0x%08lx\",\"gain\":%.4f,\"mute\":%s,\"hardware_volume\":%s,\"hardware_mute\":%s}\n",
            jname, (unsigned long)mix->nSamplesPerSec, (unsigned)mix->nChannels, format == mix ? "false" : "true",
            buffer, period / 10000.0, keeper.started ? keeper.period : 0u, (unsigned long)keeper_hr,
            g_gain.load(), g_mute.load() ? "true" : "false",
            (g_hardware.load() & ENDPOINT_HARDWARE_SUPPORT_VOLUME) ? "true" : "false",
            (g_hardware.load() & ENDPOINT_HARDWARE_SUPPORT_MUTE) ? "true" : "false");
    }
    hr = client->Start();
    if (FAILED(hr)) goto done;
    started = true;
    for (;;) {
        HANDLE waits[3] = {ready, g_stop, g_reopen};
        DWORD w = WaitForMultipleObjects(3, waits, FALSE, 2000);
        if (w == WAIT_OBJECT_0 + 1) { hr = S_OK; break; }
        if (w == WAIT_OBJECT_0 + 2) { hr = AUDCLNT_E_DEVICE_INVALIDATED; break; }
        if (w == WAIT_TIMEOUT) {  // engine idle: no render stream is active; still notice device loss
            keeper.top_up();
            UINT32 probe = 0;
            if (FAILED(hr = capture->GetNextPacketSize(&probe))) break;
            continue;
        }
        keeper.top_up();
        for (;;) {
            UINT32 next = 0;
            hr = capture->GetNextPacketSize(&next);
            if (FAILED(hr) || !next) break;
            BYTE *data = nullptr; UINT32 frames = 0; DWORD flags = 0;
            hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
            if (FAILED(hr)) break;
            double t = now_ms();
            if (last > 0 && t - last > sender.stats.max_gap_ms) sender.stats.max_gap_ms = t - last;
            last = t;
            sender.stats.capture_packets++; sender.stats.frames += frames;
            if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) sender.stats.discontinuities++;
            bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
            if (silent) sender.stats.silent_packets++;
            sender.push(silent ? nullptr : (const float *)data, channels, frames, t);
            hr = capture->ReleaseBuffer(frames);
            if (FAILED(hr)) break;
        }
        if (FAILED(hr)) break;
    }
done:
    if (FAILED(hr) && hr != AUDCLNT_E_DEVICE_INVALIDATED) log("{\"event\":\"error\",\"hresult\":\"0x%08lx\"}\n", (unsigned long)hr);
    if (started) client->Stop();
    keeper.close();
    if (volume && volume_events) volume->UnregisterControlChangeNotify(volume_events);
    release(volume_events); release(volume); release(capture); release(client); release(device);
    if (mix) CoTaskMemFree(mix);
    if (id) CoTaskMemFree(id);
    CloseHandle(ready);
    return hr;
}

DWORD WINAPI stats_thread(LPVOID param) {
    Sender *s = (Sender *)param;
    while (WaitForSingleObject(g_stop, g_opt.stats_ms) == WAIT_TIMEOUT) {
        Stats x = s->stats;
        log("{\"event\":\"statistics\",\"capture_packets\":%llu,\"frames\":%llu,\"datagrams\":%llu,\"send_errors\":%llu,"
            "\"discontinuities\":%llu,\"silent_packets\":%llu,\"suppressed\":%llu,\"reopen\":%llu,\"clipped\":%llu,"
            "\"max_gap_ms\":%.3f,\"gain\":%.4f,\"mute\":%s,\"sending\":%s}\n",
            x.capture_packets, x.frames, x.datagrams, x.send_errors, x.discontinuities, x.silent_packets, x.suppressed,
            x.reopen, x.clipped, x.max_gap_ms, g_gain.load(), g_mute.load() ? "true" : "false", s->sending ? "true" : "false");
        s->stats.max_gap_ms = 0;
    }
    return 0;
}

BOOL WINAPI on_console(DWORD) { SetEvent(g_stop); return TRUE; }

bool parse_unsigned(const wchar_t *s, unsigned low, unsigned high, unsigned &out) {
    wchar_t *end = nullptr; errno = 0; unsigned long v = wcstoul(s, &end, 10);
    if (errno || !*s || *end || v < low || v > high) return false;
    out = (unsigned)v; return true;
}

int usage() {
    log("usage: vban-sender --target IPv4 [--port 6980] [--stream Windows] [--device ENDPOINT_ID]\n"
        "                   [--prefer ENDPOINT_ID ...] [--frames 128] [--idle-ms 2000]\n"
        "                   [--no-endpoint-volume] [--no-keeper] [--no-volume-sync] [--stats-ms 0] [--log FILE] | --config FILE | --list | --stop\n");
    return 2;
}

// One JSON object per active render endpoint, including its shared-mode engine period range.
int list_devices(IMMDeviceEnumerator *enumerator) {
    IMMDeviceCollection *all = nullptr; UINT count = 0;
    if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &all))) return 1;
    wchar_t current[256] = L"";
    IMMDevice *def = nullptr; LPWSTR def_id = nullptr;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &def)) && SUCCEEDED(def->GetId(&def_id))) {
        wcsncpy_s(current, def_id, _TRUNCATE); CoTaskMemFree(def_id);
    }
    release(def);
    all->GetCount(&count);
    for (UINT i = 0; i < count; i++) {
        IMMDevice *d = nullptr; if (FAILED(all->Item(i, &d))) continue;
        LPWSTR id = nullptr; wchar_t name[256]; d->GetId(&id); describe(d, name, 256);
        UINT32 dflt = 0, fundamental = 0, minimum = 0, maximum = 0; DWORD hw = 0;
        IAudioClient3 *c = nullptr; WAVEFORMATEX *mix = nullptr; IAudioEndpointVolume *v = nullptr;
        if (SUCCEEDED(d->Activate(__uuidof(IAudioClient3), CLSCTX_ALL, nullptr, (void **)&c)) && SUCCEEDED(c->GetMixFormat(&mix)))
            c->GetSharedModeEnginePeriod(mix, &dflt, &fundamental, &minimum, &maximum);
        if (SUCCEEDED(d->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, (void **)&v))) v->QueryHardwareSupport(&hw);
        char jid[600], jname[600]; json_text(id, jid, sizeof(jid)); json_text(name, jname, sizeof(jname));
        log("{\"id\":\"%s\",\"name\":\"%s\",\"default\":%s,\"rate\":%lu,\"channels\":%u,\"default_frames\":%u,\"min_frames\":%u,\"fundamental_frames\":%u,\"hardware_volume\":%s,\"hardware_mute\":%s}\n",
            jid, jname, id && !_wcsicmp(id, current) ? "true" : "false", mix ? (unsigned long)mix->nSamplesPerSec : 0ul,
            mix ? (unsigned)mix->nChannels : 0u, dflt, minimum, fundamental,
            (hw & ENDPOINT_HARDWARE_SUPPORT_VOLUME) ? "true" : "false", (hw & ENDPOINT_HARDWARE_SUPPORT_MUTE) ? "true" : "false");
        if (mix) CoTaskMemFree(mix);
        release(v); release(c);
        if (id) CoTaskMemFree(id); d->Release();
    }
    all->Release();
    return 0;
}

// A windowless (GUI-subsystem) build still prints when started from a console.
void attach_console() {
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    if ((!h || h == INVALID_HANDLE_VALUE) && AttachConsole(ATTACH_PARENT_PROCESS)) {
        HANDLE out = CreateFileW(L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (out != INVALID_HANDLE_VALUE) { SetStdHandle(STD_ERROR_HANDLE, out); SetStdHandle(STD_OUTPUT_HANDLE, out); }
    }
}

bool open_log(const wchar_t *path) {
    // Restart with a fresh file once it exceeds 1 MiB; logs hold only events and counters.
    WIN32_FILE_ATTRIBUTE_DATA info{};
    bool reset = GetFileAttributesExW(path, GetFileExInfoStandard, &info) && (info.nFileSizeHigh || info.nFileSizeLow > (1u << 20));
    g_log = CreateFileW(path, reset ? GENERIC_WRITE : FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
                        reset ? CREATE_ALWAYS : OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    return g_log != INVALID_HANDLE_VALUE;
}

}  // namespace

int wmain(int argc, wchar_t **argv) {
    attach_console();
    // `--config FILE`: one argument per line (UTF-8, optional BOM). Keeps the
    // Windows Run-key command short while endpoint IDs stay exact.
    static wchar_t *file_argv[64]; static wchar_t file_text[16384];
    if (argc == 3 && !wcscmp(argv[1], L"--config")) {
        HANDLE f = CreateFileW(argv[2], GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (f == INVALID_HANDLE_VALUE) return 6;
        static char raw[16384]; DWORD n = 0;
        BOOL ok = ReadFile(f, raw, sizeof(raw) - 1, &n, nullptr); CloseHandle(f);
        if (!ok || n == sizeof(raw) - 1) return 6;
        raw[n] = 0;
        const char *text = (n >= 3 && (unsigned char)raw[0] == 0xef && (unsigned char)raw[1] == 0xbb && (unsigned char)raw[2] == 0xbf) ? raw + 3 : raw;
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, file_text, 16384)) return 6;
        int count = 0; file_argv[count++] = argv[0];
        for (wchar_t *line = file_text; *line && count < 63;) {
            wchar_t *end = wcspbrk(line, L"\r\n");
            if (end) *end = 0;
            if (*line) file_argv[count++] = line;
            if (!end) break;
            line = end + 1;
        }
        argc = count; argv = file_argv;
    }
    for (int i = 1; i < argc; i++) {
        const wchar_t *a = argv[i];
        if (!wcscmp(a, L"--list")) { g_opt.list = true; continue; }
        if (!wcscmp(a, L"--no-endpoint-volume")) { g_opt.endpoint_volume = false; continue; }
        if (!wcscmp(a, L"--no-keeper")) { g_opt.keeper = false; continue; }
        if (!wcscmp(a, L"--no-volume-sync")) { g_opt.volume_sync = false; continue; }
        if (!wcscmp(a, L"--stop")) {
            // Graceful stop of the running instance (it has no window or console).
            HANDLE e = OpenEventW(EVENT_MODIFY_STATE, FALSE, kStopEventName);
            if (!e) return 4;
            SetEvent(e); CloseHandle(e); return 0;
        }
        if (i + 1 >= argc) return usage();
        const wchar_t *v = argv[++i];
        if (!wcscmp(a, L"--target")) { if (wcslen(v) >= 64) return usage(); wcscpy_s(g_opt.target, v); }
        else if (!wcscmp(a, L"--port")) { if (!parse_unsigned(v, 1, 65535, g_opt.port)) return usage(); }
        else if (!wcscmp(a, L"--frames")) { if (!parse_unsigned(v, 16, kMaxVbanFrames, g_opt.frames)) return usage(); }
        else if (!wcscmp(a, L"--idle-ms")) {
            if (!parse_unsigned(v, 0, 600000, g_opt.idle_ms) || (g_opt.idle_ms && g_opt.idle_ms < 200)) return usage();
        }
        else if (!wcscmp(a, L"--stats-ms")) { if (!parse_unsigned(v, 100, 3600000, g_opt.stats_ms)) return usage(); }
        else if (!wcscmp(a, L"--device")) { if (wcslen(v) >= 512) return usage(); wcscpy_s(g_opt.device, v); }
        else if (!wcscmp(a, L"--prefer")) {
            if (g_opt.prefer_count >= Options::kMaxPrefer || wcslen(v) >= 256 || !*v) return usage();
            wcscpy_s(g_opt.prefer[g_opt.prefer_count++], v);
        }
        else if (!wcscmp(a, L"--log")) { if (wcslen(v) >= MAX_PATH) return usage(); wcscpy_s(g_opt.log_path, v); }
        else if (!wcscmp(a, L"--stream")) {
            int n = WideCharToMultiByte(CP_UTF8, 0, v, -1, g_opt.stream, sizeof(g_opt.stream), nullptr, nullptr);
            if (n <= 1) return usage();
        } else return usage();
    }
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) return 1;
    IMMDeviceEnumerator *enumerator = nullptr;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&enumerator);
    if (FAILED(hr)) return 1;
    if (g_opt.list) {
        // Listing is data, not diagnostics: write it to stdout.
        HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
        if (out && out != INVALID_HANDLE_VALUE) g_log = out;
        return list_devices(enumerator);
    }
    if (!g_opt.target[0]) return usage();
    if (g_opt.prefer_count && g_opt.device[0]) return usage();  // the policy only applies when following the default
    if (g_opt.log_path[0] && !open_log(g_opt.log_path)) return 5;

    HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\LanAudioBridgeVbanSender");
    if (!single || GetLastError() == ERROR_ALREADY_EXISTS) { log("{\"event\":\"error\",\"error\":\"already_running\"}\n"); return 3; }
    WSADATA wsa; if (WSAStartup(MAKEWORD(2, 2), &wsa)) return 1;
    static Sender sender;
    if (!sender.open(g_opt)) { log("{\"event\":\"error\",\"error\":\"socket\",\"wsa\":%d}\n", WSAGetLastError()); return 2; }
    g_stop = CreateEventW(nullptr, TRUE, FALSE, kStopEventName);
    g_reopen = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    SetConsoleCtrlHandler(on_console, TRUE);
    DeviceEvents *device_events = new DeviceEvents();
    enumerator->RegisterEndpointNotificationCallback(device_events);
    HANDLE stats = g_opt.stats_ms ? CreateThread(nullptr, 0, stats_thread, &sender, 0, nullptr) : nullptr;
    HANDLE policy = nullptr;
    if (g_opt.prefer_count) {
        g_policy = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        policy = CreateThread(nullptr, 0, policy_thread, nullptr, 0, nullptr);
    }
    HANDLE volume_sync = nullptr;
    if (g_opt.volume_sync && g_opt.prefer_count >= 2) {
        g_volume_devices = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        g_volume_changed = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        volume_sync = CreateThread(nullptr, 0, volume_sync_thread, nullptr, 0, nullptr);
    }

    DWORD task = 0; HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
    if (mmcss) AvSetMmThreadPriority(mmcss, AVRT_PRIORITY_CRITICAL);
    else SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    log("{\"event\":\"start\",\"target\":\"%ls\",\"port\":%u,\"stream\":\"%s\",\"frames\":%u,\"mmcss\":%s}\n",
        g_opt.target, g_opt.port, g_opt.stream, g_opt.frames, mmcss ? "true" : "false");
    while (WaitForSingleObject(g_stop, 0) == WAIT_TIMEOUT) {
        hr = run_session(enumerator, sender);
        if (WaitForSingleObject(g_stop, 0) == WAIT_OBJECT_0) break;
        sender.stats.reopen++;
        // Device switch: reopen immediately. Failure/removal: back off before retrying.
        if (hr != AUDCLNT_E_DEVICE_INVALIDATED) WaitForSingleObject(g_stop, (DWORD)(kRetryHns / 10000));
    }
    if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
    if (stats) { WaitForSingleObject(stats, 2000); CloseHandle(stats); }
    if (policy) { WaitForSingleObject(policy, 2000); CloseHandle(policy); }
    if (volume_sync) { WaitForSingleObject(volume_sync, 2000); CloseHandle(volume_sync); }
    enumerator->UnregisterEndpointNotificationCallback(device_events);
    device_events->Release(); enumerator->Release();
    closesocket(sender.sock); WSACleanup(); CoUninitialize();
    log("{\"event\":\"stop\"}\n");
    return 0;
}

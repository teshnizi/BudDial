// Speech / no-speech evaluation for BudDial's touch decision (main.m: speech iff speechSeconds >= kSpeechSeconds).
//
// Every test clip is built in memory from the user's bench takes plus synthetic noise; nothing is
// written to disk. Each clip is measured with:
//   A    analyzeTake from src/Recorder.m, ported exactly
//   Ac   A, but 20 ms frames that are the start cue (most power in 300-470 Hz, within 0.6 s of the
//        touch) are not counted as speech
//   B*   the same frames with a more robust noise floor (variants listed at run time)
//   S*   Silero VAD (whisper.cpp VAD API) speech windows at probability 0.5 / 0.6 / 0.7
//   Sg   Silero segments with whisper.cpp's default VAD params (what whisper-server uses)
//   S.5+12  Silero at 0.5 on the clip made 12 dB louder (is Silero only missing this mic because it is quiet?)
//
// Run: tools/eval_speech_detection.sh [bench session dir]

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ggml-backend.h>
#include <whisper.h>

#define RATE 16000
#define FRAME 320              // 20 ms
#define TOUCH 9600             // every clip has 0.6 s of pre-roll: the touch is at 0.6 s
#define FILE_TOUCH 1600        // bench files were saved after analyzeTake's cut: 100 ms before the touch
#define MAXTAKES 32
#define CUTOFF 0.08            // kSpeechSeconds in src/main.m
#define CUE_SHARE 0.5          // a frame is "cue" when this share of its power is in 300-470 Hz
#define CUE_WINDOW (RATE * 6 / 10)   // cue frames are only looked for in the first 0.6 s after the touch

static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static double sq(double v) { return v * v; }
static double db_of_power(double p) { return 10 * log10(p > 1e-12 ? p : 1e-12); }
static double power_of_db(double db) { return pow(10, db / 10); }
static int cmp_double(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static double median(double *v, int n) { if (!n) return 0; qsort(v, n, sizeof(double), cmp_double); return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2; }

// ---------------------------------------------------------------- random numbers (deterministic)
static uint64_t rng_state;
static uint64_t rng_next(void) {
    uint64_t z = (rng_state += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull; z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static double uniform(void) { return (rng_next() >> 11) * (1.0 / 9007199254740992.0); }
static double uniform_in(double a, double b) { return a + (b - a) * uniform(); }
static double gauss(void) { double u = uniform(), v = uniform(); return sqrt(-2 * log(u > 1e-300 ? u : 1e-300)) * cos(2 * M_PI * v); }

// ---------------------------------------------------------------- per-frame features
// 20 ms frame levels (dBFS) and the share of each frame's power in the start cue's band (300-470 Hz),
// from an RBJ band-pass biquad (0 dB peak) centred at 375 Hz.
static void frame_features(const float *x, int n, double *db, double *share) {
    double w0 = 2 * M_PI * 375 / RATE, q = 375.0 / 170, alpha = sin(w0) / (2 * q), a0 = 1 + alpha;
    double b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0;
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (int f = 0; f < n / FRAME; f++) {
        double s = 0, b = 0;
        for (int i = f * FRAME; i < (f + 1) * FRAME; i++) {
            double v = x[i], y = b0 * v + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = v; y2 = y1; y1 = y;
            s += v * v; b += y * y;
        }
        if (db) db[f] = 20 * log10(fmax(1e-5, sqrt(s / FRAME)));
        if (share) share[f] = s > 0 ? b / s : 0;
    }
}

// ---------------------------------------------------------------- noise and cue synthesis
typedef enum { N_PINK, N_BROWN, N_BABBLE, N_BABBLE_LOUD, N_COUNT } Noise;
static const char *noise_name[N_COUNT] = {"pink", "brown", "babble", "babble@floor"};

static void highpass60(float *x, int n) {   // built-in Mac mics roll off the deep bass
    double a = exp(-2 * M_PI * 60.0 / RATE), px = 0, py = 0;
    for (int i = 0; i < n; i++) { double y = a * (py + x[i] - px); px = x[i]; py = y; x[i] = (float)y; }
}
static void scale_to_db(float *x, int n, double db) {
    double s = 0; for (int i = 0; i < n; i++) s += sq(x[i]);
    double g = s > 0 ? sqrt(power_of_db(db) / (s / n)) : 0;
    for (int i = 0; i < n; i++) x[i] *= (float)g;
}
// Steady fan-like noise (pink or brown) at a long-term level of `db` dBFS, added to out.
static void add_steady(float *out, int n, Noise kind, double db) {
    int warm = RATE / 2, m = n + warm;
    float *w = malloc(m * sizeof(float));
    double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, y = 0;
    for (int i = 0; i < m; i++) {
        double g = gauss();
        if (kind == N_BROWN) { y = 0.995 * y + g; w[i] = (float)y; continue; }
        b0 = 0.99886 * b0 + g * 0.0555179; b1 = 0.99332 * b1 + g * 0.0750759; b2 = 0.96900 * b2 + g * 0.1538520;   // Paul Kellet's pink filter
        b3 = 0.86650 * b3 + g * 0.3104856; b4 = 0.55000 * b4 + g * 0.5329522; b5 = -0.7616 * b5 - g * 0.0168980;
        w[i] = (float)(b0 + b1 + b2 + b3 + b4 + b5 + b6 + g * 0.5362); b6 = g * 0.115926;
    }
    highpass60(w, m);
    scale_to_db(w + warm, n, db);
    for (int i = 0; i < n; i++) out[i] += w[warm + i];
    free(w);
}

// ---------------------------------------------------------------- takes
typedef struct {
    char name[16], text[256];
    float *x; int n;           // clean take: 0.5 s of room noise prepended (touch at TOUCH), real cue replaced by room noise
    double floor_db;           // p20 of 20 ms frame levels of the saved file (the app's own floor estimate)
    double speech_db;          // active speech level: power mean of frames after the touch more than 6 dB above the floor
    int onset;                 // first sample of speech after the touch (100 ms mean more than 5 dB above the floor)
    int cue_found; double cue_ms, cue_len_ms, cue_peak_db, cue_share, cue_a_frames;   // the real cue in the saved file
} Take;
static Take takes[MAXTAKES];
static int ntakes;
static double cue_latency_ms = 150, cue_level_db = -30;   // calibrated from the real cues in main()

static float *read_wav(const char *path, int *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    unsigned char h[12];
    if (fread(h, 1, 12, f) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) { fclose(f); return NULL; }
    int channels = 0, bits = 0, rate = 0;
    for (;;) {
        unsigned char c[8];
        if (fread(c, 1, 8, f) != 8) break;
        uint32_t size = c[4] | c[5] << 8 | c[6] << 16 | (uint32_t)c[7] << 24;
        if (!memcmp(c, "fmt ", 4)) {
            unsigned char fmt[64] = {0};
            if (size > sizeof fmt || fread(fmt, 1, size, f) != size) break;
            channels = fmt[2] | fmt[3] << 8; rate = fmt[4] | fmt[5] << 8 | fmt[6] << 16 | fmt[7] << 24; bits = fmt[14] | fmt[15] << 8;
        } else if (!memcmp(c, "data", 4)) {
            if (channels != 1 || bits != 16 || rate != RATE) break;
            int16_t *raw = malloc(size);
            size_t got = fread(raw, 2, size / 2, f);
            float *x = malloc(got * sizeof(float));
            for (size_t i = 0; i < got; i++) x[i] = raw[i] / 32768.0f;
            free(raw); fclose(f); *n = (int)got;
            return x;
        } else fseek(f, size + (size & 1), SEEK_CUR);
    }
    fclose(f);
    return NULL;
}

// Replace x[a, b) with steady room noise at floor_db, 10 ms crossfades at both ends.
static void patch_with_noise(float *x, int n, int a, int b, double floor_db) {
    int fade = RATE / 100;
    if (a < 0) a = 0;
    if (b > n) b = n;
    float *fill = calloc(n, sizeof(float));
    add_steady(fill, n, N_PINK, floor_db);
    for (int i = a - fade; i < b + fade; i++) {
        if (i < 0 || i >= n) continue;
        double g = i < a ? (double)(i - (a - fade)) / fade : i >= b ? (double)(b + fade - i) / fade : 1;
        x[i] = (float)(x[i] * (1 - g) + fill[i] * g);
    }
    free(fill);
}

// Load a saved bench file: find its real start cue, measure it, replace it with room noise (speech
// clips then hold speech only), and prepend 0.5 s of room noise so the touch sits at 0.6 s.
static int load_take(Take *t, const char *dir, int index) {
    char path[1200];
    snprintf(path, sizeof path, "%s/%02d.wav", dir, index);
    int n; float *raw = read_wav(path, &n);
    if (!raw) return 0;
    snprintf(t->name, sizeof t->name, "%02d", index);
    snprintf(path, sizeof path, "%s/%02d.txt", dir, index);
    FILE *f = fopen(path, "r");
    if (f) { if (!fgets(t->text, sizeof t->text, f)) t->text[0] = 0; fclose(f); t->text[strcspn(t->text, "\n")] = 0; }

    int frames = n / FRAME;
    double *db = malloc(frames * sizeof(double)), *share = malloc(frames * sizeof(double)), *sorted = malloc(frames * sizeof(double));
    frame_features(raw, n, db, share);
    memcpy(sorted, db, frames * sizeof(double));
    qsort(sorted, frames, sizeof(double), cmp_double);
    t->floor_db = sorted[frames / 5];
    // The cue: the longest run of cue-band frames within 0.6 s after the touch.
    int best = -1, best_len = 0;
    for (int fr = FILE_TOUCH / FRAME; fr < (FILE_TOUCH + CUE_WINDOW) / FRAME && fr < frames;) {
        if (share[fr] < CUE_SHARE || db[fr] < t->floor_db + 3) { fr++; continue; }
        int e = fr; while (e < frames && share[e] >= CUE_SHARE && db[e] >= t->floor_db + 3) e++;
        if (e - fr > best_len) { best = fr; best_len = e - fr; }
        fr = e;
    }
    t->cue_found = best_len >= 3;
    if (t->cue_found) {
        double peak = -200, sh = 0, thr = fmax(fmin(t->floor_db, -45) + 10, -52);
        int above = 0;
        for (int fr = best; fr < best + best_len; fr++) { peak = fmax(peak, db[fr]); sh += share[fr]; above += db[fr] > thr; }
        t->cue_ms = (best * FRAME - FILE_TOUCH) * 1000.0 / RATE;
        t->cue_len_ms = best_len * 20.0; t->cue_peak_db = peak; t->cue_share = sh / best_len; t->cue_a_frames = above;
        patch_with_noise(raw, n, best * FRAME - FRAME, (best + best_len + 1) * FRAME, t->floor_db);
    }
    int lead = TOUCH - FILE_TOUCH;
    t->n = n + lead;
    t->x = calloc(t->n, sizeof(float));
    memcpy(t->x + lead, raw, n * sizeof(float));
    patch_with_noise(t->x, t->n, 0, lead, t->floor_db);
    free(raw); free(db); free(share); free(sorted);

    frames = t->n / FRAME;
    db = malloc(frames * sizeof(double));
    frame_features(t->x, t->n, db, NULL);
    double p = 0; int k = 0; t->onset = -1;
    for (int fr = TOUCH / FRAME; fr < frames; fr++) {
        if (db[fr] > t->floor_db + 6) { p += power_of_db(db[fr]); k++; }
        // Onset: from 60 ms after the touch (skip the touch click some takes have), a 100 ms stretch whose
        // mean is 5 dB over the floor with at least 3 of its 5 frames 4 dB over it.
        if (t->onset < 0 && fr >= (TOUCH + RATE * 6 / 100) / FRAME && fr + 5 <= frames) {
            double m = 0; int loud = 0;
            for (int j = 0; j < 5; j++) { m += power_of_db(db[fr + j]); loud += db[fr + j] > t->floor_db + 4; }
            if (db_of_power(m / 5) > t->floor_db + 5 && loud >= 3) t->onset = fr * FRAME;
        }
    }
    t->speech_db = k ? db_of_power(p / k) : t->floor_db;
    if (t->onset < 0) t->onset = TOUCH;
    free(db);
    return 1;
}

// Other people talking: 3 or 4 other bench takes (from the touch on), each at its own active level
// normalised to 0 dB, randomly time shifted and looped, summed, then set to `db` long-term level.
static void add_babble(float *out, int n, int exclude, double db) {
    int talkers = 3 + (int)(uniform() * 2), used[MAXTAKES] = {0};
    float *sum = calloc(n, sizeof(float));
    for (int t = 0; t < talkers; t++) {
        int k;
        do k = (int)(uniform() * ntakes); while (k == exclude || used[k]);
        used[k] = 1;
        const float *src = takes[k].x + TOUCH; int len = takes[k].n - TOUCH;
        double g = 1 / sqrt(power_of_db(takes[k].speech_db));
        int shift = (int)(uniform() * len);
        for (int i = 0; i < n; i++) sum[i] += (float)(g * src[(i + shift) % len]);
    }
    scale_to_db(sum, n, db);
    for (int i = 0; i < n; i++) out[i] += sum[i];
    free(sum);
}
// BudDial's start cue (Feedback.m glide 330 to 440 Hz, 140 ms, same envelope) as the mic hears it:
// peak level and delay after the touch calibrated from the real cues in the bench takes.
static void add_cue(float *out, int n, int at) {
    int len = RATE * 140 / 1000;
    double attack = RATE * .018, release = RATE * .06, phase = 0, amp = sqrt(2) * pow(10, cue_level_db / 20);
    for (int i = 0; i < len && at + i < n; i++) {
        double t = (double)i / len, hz = 330 + 110 * (1 - (1 - t) * (1 - t));
        phase += 2 * M_PI * hz / RATE;
        double in = i < attack ? .5 - .5 * cos(M_PI * i / attack) : 1;
        double o = len - i < release ? .5 - .5 * cos(M_PI * (len - i) / release) : 1;
        out[at + i] += (float)(amp * in * o * sin(phase));
    }
}

// ---------------------------------------------------------------- clips
typedef enum { K_SENTENCE, K_WORD, K_QUIET, K_RAISED, K_HOLD, K_TAP, K_COUNT } Kind;
static const char *kind_name[K_COUNT] = {"sentence", "word", "quiet-6dB", "raised+6dB", "hold", "tap"};
static int kind_has_speech(Kind k) { return k <= K_RAISED; }

static double bench_speech_db(void) {
    double levels[MAXTAKES]; for (int i = 0; i < ntakes; i++) levels[i] = takes[i].speech_db;
    return median(levels, ntakes);
}

static float *mix(Kind kind, Noise noise, double floor_db, int cue, int take, int *n_out) {
    int n; float *x;
    double speech_ref, base_floor = -120;
    if (kind == K_HOLD || kind == K_TAP) {
        double seconds = kind == K_HOLD ? uniform_in(1.0, 1.6) : uniform_in(0.2, 0.9);
        n = TOUCH + (int)(seconds * RATE);
        x = calloc(n, sizeof(float));
        speech_ref = bench_speech_db();
    } else {
        Take *t = &takes[take];
        double gain = kind == K_QUIET ? 0.5 : kind == K_RAISED ? 2 : 1;   // a softer or louder talker, room unchanged
        if (kind == K_WORD) {
            // About one short word: 300 ms from the speech onset (40 ms earlier, 30 ms fades), between
            // 0.6 s of pre-roll and 1.0 s of steady room noise at the take's own floor.
            int from = t->onset - RATE * 40 / 1000, len = RATE * 340 / 1000, fade = RATE * 30 / 1000;
            if (from + len > t->n) len = t->n - from;
            n = TOUCH + len + RATE;
            x = calloc(n, sizeof(float));
            add_steady(x, n, N_PINK, t->floor_db);
            for (int i = 0; i < len; i++) {
                double g = i < fade ? (double)i / fade : i > len - fade ? (double)(len - i) / fade : 1;
                x[TOUCH + i] = (float)(x[TOUCH + i] * (1 - g) + t->x[from + i] * g);
            }
        } else {
            n = t->n;
            x = malloc(n * sizeof(float));
            for (int i = 0; i < n; i++) x[i] = (float)(t->x[i] * gain);
        }
        base_floor = t->floor_db + (kind == K_WORD ? 0 : 20 * log10(gain));
        speech_ref = t->speech_db + 20 * log10(gain);
    }
    if (noise == N_BABBLE_LOUD) {
        // The talkers are the room noise: babble at the floor level (on top of the recorded room for
        // speech clips; over a quiet -55 dBFS bed for no-speech clips).
        add_babble(x, n, take, floor_db);
        if (base_floor < -55) add_steady(x, n, N_PINK, -55);
    } else {
        // A steady bed brings the room floor up to floor_db (power added on top of what is there).
        double bed = power_of_db(floor_db) - power_of_db(base_floor);
        if (bed > power_of_db(floor_db) * 0.05) add_steady(x, n, noise == N_BROWN ? N_BROWN : N_PINK, db_of_power(bed));
        if (noise == N_BABBLE) add_babble(x, n, take, speech_ref - uniform_in(10, 15));   // distant talkers
    }
    if (cue) add_cue(x, n, TOUCH + (int)(cue_latency_ms * RATE / 1000));
    *n_out = n;
    return x;
}

static int16_t *quantize(const float *x, int n) {
    int16_t *q = malloc(n * sizeof(int16_t));
    for (int i = 0; i < n; i++) { double v = round(x[i] * 32768.0); q[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v); }
    return q;
}

// ---------------------------------------------------------------- method A: analyzeTake, exact port
static double analyze_take(const int16_t *x, unsigned long n, unsigned long touch) {
    const unsigned long frame = 320;
    unsigned long frames = n / frame;
    if (frames < 5) return 0;
    double *db = malloc(frames * sizeof(double)), *sorted = malloc(frames * sizeof(double));
    for (unsigned long f = 0; f < frames; f++) {
        double sum = 0;
        for (unsigned long i = 0; i < frame; i++) { double v = x[f * frame + i] / 32768.0; sum += v * v; }
        db[f] = sorted[f] = 20 * log10(fmax(1e-5, sqrt(sum / frame)));
    }
    for (unsigned long i = 1; i < frames; i++) {
        double v = sorted[i]; unsigned long j = i;
        while (j > 0 && sorted[j - 1] > v) { sorted[j] = sorted[j - 1]; j--; }
        sorted[j] = v;
    }
    double threshold = fmax(fmin(sorted[frames / 5], -45) + 10, -52);
    unsigned long touchFrame = frames < touch / frame ? frames : touch / frame, quiet = 0, first = 0;
    for (long f = (long)touchFrame - 1; f >= 0; f--) {
        if (db[f] > threshold) { quiet = 0; continue; }
        if (++quiet == 10) {
            unsigned long speechStart = (unsigned long)f + quiet;
            first = speechStart > 5 ? speechStart - 5 : 0;
            break;
        }
    }
    unsigned long speech = 0;
    for (unsigned long f = first; f < frames; f++) if (db[f] > threshold) speech++;
    free(db); free(sorted);
    return speech * 0.02;
}

// ---------------------------------------------------------------- energy variants (Ac, B*)
typedef struct {
    const char *name, *desc;
    double cap;              // floor capped at this (dBFS); 0 = no cap
    double margin;           // threshold = max(floor + margin, -52)
    int floor_from_preroll;  // floor = min(p20 of the pre-roll frames, p20 of all frames)
    int min_run;             // count only runs of at least this many frames above the threshold
    int cue_reject;          // do not count cue frames (share >= CUE_SHARE within CUE_WINDOW of the touch)
    double guard;            // if set, the threshold is also at least the uncapped floor + guard dB
} EnergyVariant;

static double energy_speech(const float *x, int n, int touch, const EnergyVariant *v) {
    int frames = n / FRAME;
    if (frames < 5) return 0;
    double *db = malloc(frames * sizeof(double)), *share = malloc(frames * sizeof(double)), *sorted = malloc(frames * sizeof(double));
    frame_features(x, n, db, share);
    memcpy(sorted, db, frames * sizeof(double));
    int touchFrame = touch / FRAME < frames ? touch / FRAME : frames;
    qsort(sorted, frames, sizeof(double), cmp_double);
    double floor = sorted[frames / 5];
    if (v->floor_from_preroll && touchFrame >= 5) {
        memcpy(sorted, db, touchFrame * sizeof(double));
        qsort(sorted, touchFrame, sizeof(double), cmp_double);
        floor = fmin(floor, sorted[touchFrame / 5]);
    }
    double uncapped = floor;
    if (v->cap) floor = fmin(floor, v->cap);
    double threshold = fmax(floor + v->margin, -52);
    if (v->guard) threshold = fmax(threshold, uncapped + v->guard);
    int quiet = 0, first = 0;
    for (int f = touchFrame - 1; f >= 0; f--) {
        if (db[f] > threshold) { quiet = 0; continue; }
        if (++quiet == 10) { int s = f + quiet; first = s > 5 ? s - 5 : 0; break; }
    }
    // A frame counts when it is above the threshold and (with cue rejection) is not the start cue.
    char *counted = malloc(frames);
    for (int f = 0; f < frames; f++)
        counted[f] = db[f] > threshold && !(v->cue_reject && f >= touchFrame && f < touchFrame + CUE_WINDOW / FRAME && share[f] >= CUE_SHARE);
    int speech = 0;
    for (int f = first; f < frames;) {
        if (!counted[f]) { f++; continue; }
        int e = f; while (e < frames && counted[e]) e++;
        if (e - f >= v->min_run) speech += e - f;
        f = e;
    }
    free(counted);
    free(db); free(share); free(sorted);
    return speech * 0.02;
}

static const EnergyVariant variants[] = {
    {"Ac", "A, but start-cue frames are not counted (power share in 300-470 Hz >= 0.5, within 0.6 s after the touch)", -45, 10, 0, 1, 1, 0},
    {"B1", "Ac with the cap removed: threshold = max(p20 + 10, -52)", 0, 10, 0, 1, 1, 0},
    {"B2", "Ac with floor = min(p20 pre-roll, p20 take), no cap, margin 6 dB, only runs >= 3 frames (60 ms)", 0, 6, 1, 3, 1, 0},
    {"B3", "Ac, and the threshold is also at least p20 + 4 dB: max(min(p20, -45) + 10, p20 + 4, -52)", -45, 10, 0, 1, 1, 4},
};
#define NVARIANTS (int)(sizeof variants / sizeof variants[0])

// ---------------------------------------------------------------- Silero VAD
static struct whisper_vad_context *vad;
static double vad_seconds, vad_audio_seconds;
static const double silero_th[3] = {0.5, 0.6, 0.7};

// Speech windows with p >= th after the same pre-roll cut as analyzeTake (walk back from the touch;
// the first ~200 ms pause ends any speech that runs across it; keep ~100 ms of lead-in).
static double silero_count(const float *p, int np, double win, int touch, double th) {
    int touchWin = (int)(touch / (win * RATE)); if (touchWin > np) touchWin = np;
    int pause = (int)ceil(0.2 / win), lead = (int)round(0.1 / win), quiet = 0, first = 0, speech = 0;
    for (int f = touchWin - 1; f >= 0; f--) {
        if (p[f] >= th) { quiet = 0; continue; }
        if (++quiet == pause) { int s = f + quiet; first = s > lead ? s - lead : 0; break; }
    }
    for (int f = first; f < np; f++) if (p[f] >= th) speech++;
    return speech * win;
}

typedef struct { double s[3], seg, gained; } SileroResult;
static SileroResult silero(const float *x, int n, int touch) {
    double t0 = now_s();
    if (!whisper_vad_detect_speech(vad, x, n)) { fprintf(stderr, "whisper_vad_detect_speech failed\n"); exit(1); }
    vad_seconds += now_s() - t0; vad_audio_seconds += (double)n / RATE;
    int np = whisper_vad_n_probs(vad);
    float *p = whisper_vad_probs(vad);
    double win = (double)n / RATE / np;
    SileroResult r;
    for (int k = 0; k < 3; k++) r.s[k] = silero_count(p, np, win, touch, silero_th[k]);
    struct whisper_vad_segments *seg = whisper_vad_segments_from_probs(vad, whisper_vad_default_params());
    r.seg = 0;
    double from = (double)touch / RATE - 0.1;
    for (int i = 0; seg && i < whisper_vad_segments_n_segments(seg); i++) {
        double a = whisper_vad_segments_get_segment_t0(seg, i) / 100, b = whisper_vad_segments_get_segment_t1(seg, i) / 100;   // centiseconds
        if (b > from) r.seg += b - fmax(a, from);
    }
    if (seg) whisper_vad_free_segments(seg);
    // The same clip 12 dB louder (clipped to full scale): does Silero only miss this mic because it is quiet?
    float *g = malloc(n * sizeof(float));
    for (int i = 0; i < n; i++) g[i] = fmaxf(-1, fminf(1, x[i] * 3.981f));
    if (!whisper_vad_detect_speech(vad, g, n)) { fprintf(stderr, "whisper_vad_detect_speech failed\n"); exit(1); }
    r.gained = silero_count(whisper_vad_probs(vad), whisper_vad_n_probs(vad), win, touch, 0.5);
    free(g);
    return r;
}

// ---------------------------------------------------------------- results
enum { M_A, M_AC, M_B1, M_B2, M_B3, M_S5, M_S6, M_S7, M_SEG, M_S5G, NMETHODS };
static const char *method_name[NMETHODS] = {"A", "Ac", "B1", "B2", "B3", "S.5", "S.6", "S.7", "Sg", "S.5+12"};

typedef struct { Kind kind; Noise noise; int floor_db, cue, take; double floor_measured; double v[NMETHODS]; } Row;
static Row *rows; static int nrows, caprows;

static void measure(Kind kind, Noise noise, int floor_db, int cue, int take) {
    int n; float *x = mix(kind, noise, floor_db, cue, take, &n);
    int16_t *pcm = quantize(x, n);
    for (int i = 0; i < n; i++) x[i] = pcm[i] / 32768.0f;   // every method sees exactly the int16 the app records
    if (nrows == caprows) { caprows = caprows ? caprows * 2 : 1024; rows = realloc(rows, caprows * sizeof(Row)); }
    Row *r = &rows[nrows++];
    r->kind = kind; r->noise = noise; r->floor_db = floor_db; r->cue = cue; r->take = take;
    int frames = n / FRAME; double *db = malloc(frames * sizeof(double));
    frame_features(x, n, db, NULL);
    qsort(db, frames, sizeof(double), cmp_double);
    r->floor_measured = db[frames / 5];
    free(db);
    r->v[M_A] = analyze_take(pcm, n, TOUCH);
    for (int k = 0; k < NVARIANTS; k++) r->v[M_AC + k] = energy_speech(x, n, TOUCH, &variants[k]);
    SileroResult s = silero(x, n, TOUCH);
    for (int k = 0; k < 3; k++) r->v[M_S5 + k] = s.s[k];
    r->v[M_SEG] = s.seg;
    r->v[M_S5G] = s.gained;
    free(pcm); free(x);   // the mix only ever lived in memory
}

static int is_error(const Row *r, int m, double cutoff) { return kind_has_speech(r->kind) ? r->v[m] < cutoff : r->v[m] >= cutoff; }
static int row_core(const Row *r) { return r->noise != N_BABBLE_LOUD && r->kind != K_QUIET && r->kind != K_RAISED; }

static void print_conditions(void) {
    printf("\nPer condition: median / worst speech seconds (worst = lowest for speech clips, highest for no-speech\n"
           "clips), then the error rate against the %.2f s rule. flr = target room floor (dBFS), meas = median p20\n"
           "frame level actually measured, n = clips.\n", CUTOFF);
    printf("%-10s %-12s %4s %3s %5s %3s", "kind", "noise", "flr", "cue", "meas", "n");
    for (int m = 0; m < NMETHODS; m++) printf(" | %-15s", method_name[m]);
    printf("\n");
    for (int k = 0; k < K_COUNT; k++) for (int nz = 0; nz < N_COUNT; nz++) for (int fl = -55; fl <= -30; fl++) for (int c = 0; c < 2; c++) {
        int cnt = 0; double meas[512];
        for (int i = 0; i < nrows; i++) if (rows[i].kind == (Kind)k && rows[i].noise == (Noise)nz && rows[i].floor_db == fl && rows[i].cue == c) meas[cnt++] = rows[i].floor_measured;
        if (!cnt) continue;
        printf("%-10s %-12s %4d %3s %5.1f %3d", kind_name[k], noise_name[nz], fl, c ? "yes" : "no", median(meas, cnt), cnt);
        for (int m = 0; m < NMETHODS; m++) {
            double v[512]; int j = 0, err = 0; double worst = kind_has_speech(k) ? 1e9 : -1e9;
            for (int i = 0; i < nrows; i++) {
                Row *r = &rows[i];
                if (r->kind != (Kind)k || r->noise != (Noise)nz || r->floor_db != fl || r->cue != c) continue;
                v[j++] = r->v[m]; err += is_error(r, m, CUTOFF);
                worst = kind_has_speech(k) ? fmin(worst, r->v[m]) : fmax(worst, r->v[m]);
            }
            char cell[32]; snprintf(cell, sizeof cell, "%.2f/%.2f %3.0f%%", median(v, j), worst, 100.0 * err / j);
            printf(" | %-15s", cell);
        }
        printf("\n");
    }
}

// Error rate of method m at cutoff over rows matching kind (or -1: all speech kinds / -2: all no-speech), floor, core.
static double rate(int m, double cutoff, int kind, int floor_db, int core, int *count) {
    int e = 0, t = 0;
    for (int i = 0; i < nrows; i++) {
        Row *r = &rows[i];
        if (kind >= 0 ? r->kind != (Kind)kind : kind == -1 ? !kind_has_speech(r->kind) : kind_has_speech(r->kind)) continue;
        if (floor_db && r->floor_db != floor_db) continue;
        if (core >= 0 && row_core(r) != core) continue;
        if (core == 0 && r->noise != N_BABBLE_LOUD) continue;
        e += is_error(r, m, cutoff); t++;
    }
    if (count) *count = t;
    return t ? 100.0 * e / t : -1;
}

static void print_summary(double cutoff) {
    printf("\nCore error rates at %.2f s by room floor. Core = pink, brown, distant babble; speech at the recorded level.\n"
           "miss = speech read as no speech (dangerous: Return or undo); fail = no-speech read as speech.\n", cutoff);
    const int floors[] = {-55, -43, -38, -36, -34};
    printf("%-6s", "method");
    for (int f = 0; f < 5; f++) printf(" | %-31d", floors[f]);
    printf("\n%-6s", "");
    for (int f = 0; f < 5; f++) printf(" | %-7s %-7s %-7s %-7s", "s.miss", "w.miss", "h.fail", "t.fail");
    printf("\n");
    for (int m = 0; m < NMETHODS; m++) {
        printf("%-6s", method_name[m]);
        for (int f = 0; f < 5; f++) {
            printf(" |");
            const int kinds[] = {K_SENTENCE, K_WORD, K_HOLD, K_TAP};
            for (int k = 0; k < 4; k++) {
                int c; double r = rate(m, cutoff, kinds[k], floors[f], 1, &c);
                char cell[16]; if (c) snprintf(cell, sizeof cell, "%5.1f%%", r); else snprintf(cell, sizeof cell, "  -");
                printf(" %-7s", cell);
            }
        }
        printf("\n");
    }
}

// Error rates of the energy methods over a range of cutoffs: s.miss, w.miss, then holds and taps pooled.
static void print_sweep(void) {
    const int floors[] = {-55, -43, -38, -36, -34}, methods[] = {M_A, M_AC, M_B2};
    printf("\nCutoff sweep (core): sentence miss / word miss / hold+tap fail, per room floor.\n%-6s %-6s", "method", "cutoff");
    for (int f = 0; f < 5; f++) printf(" | %-20d", floors[f]);
    printf("\n");
    for (int mi = 0; mi < 3; mi++) for (int c = 2; c <= 10; c++) {
        double cut = c * 0.02 - 1e-9;
        printf("%-6s %-6.2f", method_name[methods[mi]], c * 0.02);
        for (int f = 0; f < 5; f++) {
            int n1, n2, n3;
            double s = rate(methods[mi], cut, K_SENTENCE, floors[f], 1, &n1), w = rate(methods[mi], cut, K_WORD, floors[f], 1, &n2), h = rate(methods[mi], cut, -2, floors[f], 1, &n3);
            char cell[40];
            if (n1) snprintf(cell, sizeof cell, "%3.0f%% %3.0f%% %5.1f%%", s, w, h); else snprintf(cell, sizeof cell, "  -    -  %5.1f%%", h);
            printf(" | %-20s", cell);
        }
        printf("\n");
    }
}

static void print_stress(void) {
    printf("\nStress conditions at %.2f s (all floors pooled): softer/louder talker, talkers as loud as the room floor.\n"
           "Then, over core clips in rooms at -38 dBFS or quieter: lowest sentence and word speech seconds, highest\n"
           "no-speech seconds, and the cutoff with the fewest errors there (missed speech weighted 3x).\n", CUTOFF);
    printf("%-6s | %-9s %-9s %-9s %-9s %-9s | %-6s %-6s %-6s %-16s\n", "method", "q-6 miss", "r+6 miss", "loud miss", "loud hold", "loud tap",
           "minSnt", "minWrd", "maxNo", "best cutoff");
    for (int m = 0; m < NMETHODS; m++) {
        double minS = 1e9, minW = 1e9, maxNo = -1e9;
        for (int i = 0; i < nrows; i++) {
            Row *r = &rows[i];
            if (!row_core(r) || r->floor_db > -38) continue;
            if (r->kind == K_SENTENCE) minS = fmin(minS, r->v[m]); else if (r->kind == K_WORD) minW = fmin(minW, r->v[m]); else maxNo = fmax(maxNo, r->v[m]);
        }
        double best = 0, bestCost = 1e18;
        for (int c = 1; c <= 60; c++) {
            double cut = c * 0.02 - 1e-9, cost = 0;
            for (int i = 0; i < nrows; i++) if (row_core(&rows[i]) && rows[i].floor_db <= -38) cost += is_error(&rows[i], m, cut) * (kind_has_speech(rows[i].kind) ? 3 : 1);
            if (cost < bestCost - 1e-9) { bestCost = cost; best = cut; }
        }
        int c;
        double q = rate(m, CUTOFF, K_QUIET, 0, -1, &c), rs = rate(m, CUTOFF, K_RAISED, 0, -1, &c);
        int loud_speech = 0, loud_speech_err = 0;
        for (int i = 0; i < nrows; i++) if (rows[i].noise == N_BABBLE_LOUD && (rows[i].kind == K_SENTENCE || rows[i].kind == K_WORD)) { loud_speech++; loud_speech_err += is_error(&rows[i], m, CUTOFF); }
        double lh = rate(m, CUTOFF, K_HOLD, 0, 0, &c), lt = rate(m, CUTOFF, K_TAP, 0, 0, &c);
        char bc[32]; snprintf(bc, sizeof bc, "%.2f (cost %.0f)", best + 1e-9, bestCost);
        printf("%-6s | %7.1f%%  %7.1f%%  %7.1f%%  %7.1f%%  %7.1f%%  | %-6.2f %-6.2f %-6.2f %-16s\n", method_name[m], q, rs,
               100.0 * loud_speech_err / loud_speech, lh, lt, minS, minW, maxNo, bc);
    }
}

static void print_takes(void) {
    printf("\nSpeech takes: lowest speech seconds per method, sentence|word, at the recorded floor (-43 rows) and at -38\n"
           "(pink, brown, distant babble; no cue on speech clips). level = active speech level (dBFS); onset = word clip\n"
           "start, seconds after the touch.\n");
    printf("%-4s %6s %6s %5s %-30s %4s", "take", "floor", "level", "onset", "text", "flr");
    for (int m = 0; m < NMETHODS; m++) printf(" %-10s", method_name[m]);
    printf("\n");
    for (int t = 0; t < ntakes; t++) for (int fl = -43; fl <= -38; fl += 5) {
        char txt[31]; snprintf(txt, sizeof txt, "%s", takes[t].text);
        if (fl == -43) printf("%-4s %6.1f %6.1f %5.2f %-30s %4d", takes[t].name, takes[t].floor_db, takes[t].speech_db, (double)(takes[t].onset - TOUCH) / RATE, txt, fl);
        else printf("%-4s %6s %6s %5s %-30s %4d", "", "", "", "", "", fl);
        for (int m = 0; m < NMETHODS; m++) {
            double s = 1e9, w = 1e9;
            for (int i = 0; i < nrows; i++) {
                Row *r = &rows[i]; if (r->take != t || !row_core(r) || r->floor_db != fl) continue;
                if (r->kind == K_SENTENCE) s = fmin(s, r->v[m]); else if (r->kind == K_WORD) w = fmin(w, r->v[m]);
            }
            char cell[16]; snprintf(cell, sizeof cell, "%.2f|%.2f", s, w);
            printf(" %-10s", cell);
        }
        printf("\n");
    }
}

// Does whisper_vad_detect_speech_no_reset stream? Feed one clip in 96 ms chunks and compare.
static void streaming_check(void) {
    int n; float *x = mix(K_SENTENCE, N_PINK, -38, 0, 0, &n);
    if (!whisper_vad_detect_speech(vad, x, n)) return;
    int np = whisper_vad_n_probs(vad);
    float *batch = malloc(np * sizeof(float)); memcpy(batch, whisper_vad_probs(vad), np * sizeof(float));
    whisper_vad_reset_state(vad);
    int chunk = 512 * 3, got = 0, per_call = -1; double maxdiff = 0;
    for (int off = 0; off + chunk <= n; off += chunk) {
        if (!whisper_vad_detect_speech_no_reset(vad, x + off, chunk)) break;
        int k = whisper_vad_n_probs(vad); float *p = whisper_vad_probs(vad);
        if (per_call < 0) per_call = k;
        for (int i = 0; i < k && got + i < np; i++) maxdiff = fmax(maxdiff, fabs(p[i] - batch[got + i]));
        got += k;
    }
    printf("Streaming: 96 ms chunks through whisper_vad_detect_speech_no_reset return %d probs per call (only the new\n"
           "windows); %d of %d windows match the one-shot run within %.4f\n", per_call, got < np ? got : np, np, maxdiff);
    free(batch); free(x);
}

static void cb_log(enum ggml_log_level level, const char *text, void *user) { (void)user; if (level >= GGML_LOG_LEVEL_ERROR) fputs(text, stderr); }

int main(int argc, char **argv) {
    const char *home = getenv("HOME");
    char dir[1024], model[1024];
    if (argc > 1) snprintf(dir, sizeof dir, "%s", argv[1]);
    else snprintf(dir, sizeof dir, "%s/Library/Application Support/BudDial/bench/2026-10-15-144714", home);
    snprintf(model, sizeof model, "%s/Library/Application Support/BudDial/models/ggml-silero-v6.2.0.bin", home);
    rng_state = 7;
    for (int t = 1; t < 100 && ntakes < MAXTAKES; t++) ntakes += load_take(&takes[ntakes], dir, t);
    if (ntakes < 5) { fprintf(stderr, "need at least 5 takes in %s\n", dir); return 1; }

    // The real start cue as the built-in mic heard it in the saved takes.
    printf("Bench: %d takes from %s\nReal start cue in the saved takes (touch = 100 ms into each file, analyzeTake's cut):\n", ntakes, dir);
    double lat[MAXTAKES], lev[MAXTAKES]; int ncue = 0;
    for (int t = 0; t < ntakes; t++) {
        Take *k = &takes[t];
        if (!k->cue_found) { printf("  %s  no cue found\n", k->name); continue; }
        printf("  %s  starts %3.0f ms after the touch, %3.0f ms long, peak %5.1f dBFS (%4.1f dB over the floor), cue-band share %.2f, %0.f frames above A's threshold\n",
               k->name, k->cue_ms, k->cue_len_ms, k->cue_peak_db, k->cue_peak_db - k->floor_db, k->cue_share, k->cue_a_frames);
        lat[ncue] = k->cue_ms; lev[ncue++] = k->cue_peak_db;
    }
    if (ncue) { cue_latency_ms = median(lat, ncue); cue_level_db = median(lev, ncue); }
    printf("Synthetic cue: Feedback.m glide, %.0f ms after the touch, steady part at %.1f dBFS%s\n", cue_latency_ms, cue_level_db,
           ncue ? " (medians of the real cues)" : " (no real cue found: defaults)");
    // On the saved files as recorded (real cue still in them): what A and Ac report.
    printf("Saved files as recorded, speech seconds A / Ac:");
    for (int t = 0; t < ntakes; t++) {
        char path[1200]; snprintf(path, sizeof path, "%s/%s.wav", dir, takes[t].name);
        int n; float *raw = read_wav(path, &n);
        if (!raw) continue;
        int16_t *q = quantize(raw, n);
        printf("%s %s %.2f/%.2f", t % 6 ? "," : "\n ", takes[t].name, analyze_take(q, n, FILE_TOUCH), energy_speech(raw, n, FILE_TOUCH, &variants[0]));
        free(q); free(raw);
    }
    printf("\n");
    // Speech frames that look like the cue: in the window cue rejection uses, and anywhere in the takes.
    {
        int speech = 0, cueish = 0, all = 0, all_cueish = 0;
        for (int t = 0; t < ntakes; t++) {
            int frames = takes[t].n / FRAME; double *db = malloc(frames * sizeof(double)), *sh = malloc(frames * sizeof(double));
            frame_features(takes[t].x, takes[t].n, db, sh);
            for (int f = TOUCH / FRAME; f < frames; f++) {
                if (db[f] <= fmax(fmin(takes[t].floor_db, -45) + 10, -52)) continue;
                all++; all_cueish += sh[f] >= CUE_SHARE;
                if (f < (TOUCH + CUE_WINDOW) / FRAME) { speech++; cueish += sh[f] >= CUE_SHARE; }
            }
            free(db); free(sh);
        }
        printf("Cue rejection on real speech (cue removed): %d of %d counted frames in the first 0.6 s after the touch look like\n"
               "the cue; %d of %d counted frames anywhere in the takes do\n", cueish, speech, all_cueish, all);
    }

    whisper_log_set(cb_log, NULL);
    ggml_backend_load_all();   // Homebrew's ggml ships its CPU/Metal backends as plugins
    if (!ggml_backend_dev_count()) ggml_backend_load_all_from_path("/opt/homebrew/opt/ggml/libexec");
    struct whisper_vad_context_params cp = whisper_vad_default_context_params();
    struct whisper_vad_params vp = whisper_vad_default_params();
    printf("\nwhisper.cpp %s, %s; VAD context defaults: n_threads %d, use_gpu %d\n", whisper_version(), strrchr(model, '/') + 1, cp.n_threads, cp.use_gpu);
    printf("VAD segment defaults: threshold %.2f, min_speech %d ms, min_silence %d ms, speech_pad %d ms\n",
           vp.threshold, vp.min_speech_duration_ms, vp.min_silence_duration_ms, vp.speech_pad_ms);
    int n; float *probe = mix(K_SENTENCE, N_PINK, -38, 0, 0, &n);
    for (int pass = 0; pass < 2; pass++) {
        cp = whisper_vad_default_context_params();
        if (pass == 0) { cp.n_threads = 1; cp.use_gpu = 0; }
        double t0 = now_s();
        struct whisper_vad_context *v = whisper_vad_init_from_file_with_params(model, cp);
        if (!v) { fprintf(stderr, "cannot load %s\n", model); return 1; }
        double init = now_s() - t0;
        whisper_vad_detect_speech(v, probe, n);
        t0 = now_s();
        for (int r = 0; r < 20; r++) whisper_vad_detect_speech(v, probe, n);
        double per = (now_s() - t0) / 20;
        printf("Silero cost (%s): load %.0f ms, %.2f ms per %.2f s take = %.2f ms per audio second; %d windows of %.0f ms\n",
               pass == 0 ? "CPU, 1 thread" : "context defaults", init * 1000, per * 1000, (double)n / RATE, per * 1000 / ((double)n / RATE),
               whisper_vad_n_probs(v), 1000.0 * n / RATE / whisper_vad_n_probs(v));
        if (pass == 0) vad = v; else whisper_vad_free(v);
    }
    {
        int16_t *q = quantize(probe, n);
        double t0 = now_s(), sink = 0;
        for (int r = 0; r < 200; r++) sink += analyze_take(q, n, TOUCH);
        double a = (now_s() - t0) / 200;
        t0 = now_s();
        for (int r = 0; r < 200; r++) sink += energy_speech(probe, n, TOUCH, &variants[0]);
        printf("Energy cost: analyzeTake %.3f ms, Ac %.3f ms per %.2f s take (checksum %.0f)\n", a * 1000, (now_s() - t0) / 200 * 1000, (double)n / RATE, sink);
        free(q);
    }
    free(probe);
    streaming_check();

    printf("\nMethods:\n  A   analyzeTake as shipped: threshold = max(min(p20, -45) + 10, -52)\n");
    for (int k = 0; k < NVARIANTS; k++) printf("  %-3s %s\n", variants[k].name, variants[k].desc);
    printf("  S.5 S.6 S.7  Silero window probability >= 0.5 / 0.6 / 0.7, counted after the same pre-roll cut\n"
           "  Sg  Silero segments with whisper.cpp default VAD params, seconds from 0.1 s before the touch\n"
           "  S.5+12  Silero at 0.5 on the same clip made 12 dB louder (clipped to full scale)\n");

    rng_state = 20261016;
    const int speech_floors[] = {-43, -38, -36, -34}, silent_floors[] = {-55, -43, -38, -36, -34}, per_condition = 24;
    for (int k = K_SENTENCE; k <= K_RAISED; k++)
        for (int nz = 0; nz < N_COUNT; nz++) for (int f = 0; f < 4; f++)
            for (int t = 0; t < ntakes; t++) measure(k, nz, speech_floors[f], 0, t);
    for (int k = K_HOLD; k <= K_TAP; k++)
        for (int nz = 0; nz < N_COUNT; nz++) for (int f = 0; f < 5; f++) for (int c = 0; c < 2; c++)
            for (int i = 0; i < per_condition; i++) measure(k, nz, silent_floors[f], c, -1);
    printf("Silero over all %d clips: %.0f s of audio in %.2f s = %.2f ms per audio second (CPU, 1 thread)\n",
           nrows, vad_audio_seconds, vad_seconds, vad_seconds * 1000 / vad_audio_seconds);

    print_conditions();
    print_summary(CUTOFF);
    print_sweep();
    print_stress();
    print_takes();
    whisper_vad_free(vad);
    for (int t = 0; t < ntakes; t++) free(takes[t].x);
    free(rows);
    return 0;
}

/*
 * oscillator.c -- the voice core of the Halcyon Instruments "Tern" mono synth,
 * reduced to a command-line tool that renders a short phrase to a WAV file.
 *
 * One voice is a band-limited oscillator (PolyBLEP saw and square, plus a
 * sine and a triangle), a two-pole state-variable filter and an ADSR
 * envelope. Everything is single precision and allocation-free once the
 * output buffer exists, which is how it runs on the instrument itself.
 *
 *     cc -std=c11 -O2 -Wall -Wextra oscillator.c -lm -o tern && ./tern out.wav
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAMPLE_RATE 48000.0f
#define TWO_PI      6.28318530717958647692f

typedef enum { WAVE_SINE, WAVE_TRIANGLE, WAVE_SAW, WAVE_SQUARE } waveform_t;

typedef enum { ENV_IDLE, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE } env_stage_t;

typedef struct {
    waveform_t wave;
    float phase;       /* 0..1 */
    float increment;   /* cycles per sample */
    float pulse_width; /* square only, 0..1 */
    float tri_state;   /* leaky integrator for the triangle */
} oscillator_t;

typedef struct {
    float attack_s, decay_s, sustain, release_s;
    env_stage_t stage;
    float level;
} envelope_t;

typedef struct {
    float cutoff_hz;
    float resonance; /* 0 = gentle, approaching 1 = self-oscillation */
    float low, band;
} svf_t;

typedef struct {
    oscillator_t osc;
    envelope_t env;
    svf_t filter;
    float filter_env_amount; /* in octaves */
} voice_t;

/* ------------------------------------------------------------------ */
/* Oscillator                                                          */
/* ------------------------------------------------------------------ */

static float midi_to_hz(int note)
{
    return 440.0f * powf(2.0f, (float)(note - 69) / 12.0f);
}

/*
 * PolyBLEP: subtract a two-sample polynomial approximation of the band-
 * limited step at each discontinuity. Cheap, and it removes most of the
 * aliasing a naive saw folds back into the audible range.
 */
static float poly_blep(float t, float dt)
{
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0f;
    }
    if (t > 1.0f - dt) {
        t = (t - 1.0f) / dt;
        return t * t + t + t + 1.0f;
    }
    return 0.0f;
}

static void osc_set_note(oscillator_t *o, int note)
{
    o->increment = midi_to_hz(note) / SAMPLE_RATE;
}

static float osc_next(oscillator_t *o)
{
    const float t = o->phase;
    const float dt = o->increment;
    float out;

    switch (o->wave) {
    case WAVE_SINE:
        out = sinf(TWO_PI * t);
        break;

    case WAVE_SAW:
        out = 2.0f * t - 1.0f;
        out -= poly_blep(t, dt);
        break;

    case WAVE_SQUARE:
    case WAVE_TRIANGLE: {
        const float pw = o->wave == WAVE_TRIANGLE ? 0.5f : o->pulse_width;
        out = t < pw ? 1.0f : -1.0f;
        out += poly_blep(t, dt);
        out -= poly_blep(fmodf(t + 1.0f - pw, 1.0f), dt);
        if (o->wave == WAVE_TRIANGLE) {
            /* Integrate the band-limited square; the leak keeps DC away. */
            o->tri_state = dt * 4.0f * out + (1.0f - dt) * o->tri_state;
            out = o->tri_state;
        }
        break;
    }

    default:
        out = 0.0f;
    }

    o->phase += dt;
    if (o->phase >= 1.0f) {
        o->phase -= 1.0f;
    }
    return out;
}

/* ------------------------------------------------------------------ */
/* Envelope                                                            */
/* ------------------------------------------------------------------ */

static void env_gate(envelope_t *e, int on)
{
    e->stage = on ? ENV_ATTACK : ENV_RELEASE;
}

static float rate_for(float seconds)
{
    return seconds <= 0.0f ? 1.0f : 1.0f / (seconds * SAMPLE_RATE);
}

static float env_next(envelope_t *e)
{
    switch (e->stage) {
    case ENV_ATTACK:
        e->level += rate_for(e->attack_s);
        if (e->level >= 1.0f) {
            e->level = 1.0f;
            e->stage = ENV_DECAY;
        }
        break;
    case ENV_DECAY:
        e->level -= rate_for(e->decay_s) * (1.0f - e->sustain);
        if (e->level <= e->sustain) {
            e->level = e->sustain;
            e->stage = ENV_SUSTAIN;
        }
        break;
    case ENV_RELEASE:
        e->level -= rate_for(e->release_s);
        if (e->level <= 0.0f) {
            e->level = 0.0f;
            e->stage = ENV_IDLE;
        }
        break;
    case ENV_SUSTAIN:
    case ENV_IDLE:
        break;
    }
    return e->level;
}

/* ------------------------------------------------------------------ */
/* Filter (Chamberlin state-variable, low-pass tap)                    */
/* ------------------------------------------------------------------ */

static float svf_lowpass(svf_t *f, float in, float cutoff_hz)
{
    float fc = cutoff_hz < 20.0f ? 20.0f : cutoff_hz;
    if (fc > SAMPLE_RATE / 6.0f) {
        fc = SAMPLE_RATE / 6.0f; /* the topology goes unstable above ~fs/6 */
    }
    const float g = 2.0f * sinf((TWO_PI / 2.0f) * fc / SAMPLE_RATE);
    const float damping = 2.0f * (1.0f - f->resonance);

    const float high = in - f->low - damping * f->band;
    f->band += g * high;
    f->low += g * f->band;
    return f->low;
}

/* ------------------------------------------------------------------ */
/* Voice                                                               */
/* ------------------------------------------------------------------ */

static float voice_next(voice_t *v)
{
    const float amp = env_next(&v->env);
    const float sweep = powf(2.0f, v->filter_env_amount * amp);
    const float raw = osc_next(&v->osc);
    return svf_lowpass(&v->filter, raw, v->filter.cutoff_hz * sweep) * amp;
}

/* ------------------------------------------------------------------ */
/* WAV output (16-bit PCM, mono, little-endian)                        */
/* ------------------------------------------------------------------ */

static void put_u32(FILE *f, uint32_t v)
{
    const uint8_t b[4] = { v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24 };
    fwrite(b, 1, 4, f);
}

static void put_u16(FILE *f, uint16_t v)
{
    const uint8_t b[2] = { v & 0xff, v >> 8 };
    fwrite(b, 1, 2, f);
}

static int write_wav(const char *path, const float *samples, size_t count)
{
    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        perror(path);
        return -1;
    }
    const uint32_t data_bytes = (uint32_t)(count * 2);

    fwrite("RIFF", 1, 4, f);
    put_u32(f, 36 + data_bytes);
    fwrite("WAVEfmt ", 1, 8, f);
    put_u32(f, 16);
    put_u16(f, 1); /* PCM */
    put_u16(f, 1); /* mono */
    put_u32(f, (uint32_t)SAMPLE_RATE);
    put_u32(f, (uint32_t)SAMPLE_RATE * 2);
    put_u16(f, 2);
    put_u16(f, 16);
    fwrite("data", 1, 4, f);
    put_u32(f, data_bytes);

    for (size_t i = 0; i < count; i++) {
        float s = samples[i];
        s = s > 1.0f ? 1.0f : (s < -1.0f ? -1.0f : s);
        put_u16(f, (uint16_t)(int16_t)lrintf(s * 32767.0f));
    }
    return fclose(f);
}

/* ------------------------------------------------------------------ */
/* A short phrase                                                      */
/* ------------------------------------------------------------------ */

typedef struct {
    int note;        /* MIDI note number, or -1 for a rest */
    float beats;
    waveform_t wave;
} step_t;

static const step_t PHRASE[] = {
    { 45, 0.5f, WAVE_SAW },    { 57, 0.5f, WAVE_SAW },  { 52, 0.5f, WAVE_SQUARE },
    { 55, 0.5f, WAVE_SQUARE }, { -1, 0.25f, WAVE_SAW }, { 48, 0.75f, WAVE_SAW },
    { 60, 0.5f, WAVE_TRIANGLE }, { 59, 0.5f, WAVE_TRIANGLE }, { 57, 1.0f, WAVE_SINE },
};

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "tern.wav";
    const float bpm = 112.0f;
    const float samples_per_beat = SAMPLE_RATE * 60.0f / bpm;

    size_t total = 0;
    for (size_t i = 0; i < sizeof PHRASE / sizeof PHRASE[0]; i++) {
        total += (size_t)(PHRASE[i].beats * samples_per_beat);
    }
    total += (size_t)SAMPLE_RATE; /* one second of release tail */

    float *out = calloc(total, sizeof *out);
    if (out == NULL) {
        return EXIT_FAILURE;
    }

    voice_t v = {
        .osc = { .wave = WAVE_SAW, .pulse_width = 0.35f },
        .env = { .attack_s = 0.005f, .decay_s = 0.18f, .sustain = 0.55f, .release_s = 0.25f },
        .filter = { .cutoff_hz = 380.0f, .resonance = 0.72f },
        .filter_env_amount = 3.5f,
    };

    size_t cursor = 0;
    for (size_t i = 0; i < sizeof PHRASE / sizeof PHRASE[0]; i++) {
        const step_t *s = &PHRASE[i];
        const size_t len = (size_t)(s->beats * samples_per_beat);
        const size_t gate_len = len * 7 / 8; /* slightly detached */

        if (s->note >= 0) {
            v.osc.wave = s->wave;
            osc_set_note(&v.osc, s->note);
            env_gate(&v.env, 1);
        }
        for (size_t n = 0; n < len; n++) {
            if (n == gate_len) {
                env_gate(&v.env, 0);
            }
            out[cursor++] = 0.6f * voice_next(&v);
        }
    }
    while (cursor < total) {
        out[cursor++] = 0.6f * voice_next(&v);
    }

    const int rc = write_wav(path, out, total);
    free(out);
    if (rc == 0) {
        printf("wrote %zu samples (%.2f s) to %s\n", total, total / SAMPLE_RATE, path);
    }
    return rc == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

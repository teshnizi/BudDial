#pragma once
#include <stdbool.h>

// Touch classification. AirPods report only "in ear" / "out of ear", debounced in the bud,
// so tap counts are unreliable (two quick taps arrive as one touch). The only distinctions
// that survive are: a short touch (tap) and a held touch (dictation).
typedef enum { APNone, APBeginTouch, APStartDictation, APStopDictation, APTap, APDiscardTouch } APAction;
typedef struct {
    bool initialized, covered, ready, tracking, dictating;
    double pressedAt, holdSeconds, minimumTapSeconds, maximumHoldSeconds;
} APGesture;

static inline APAction APCancel(APGesture *g) {
    bool active = g->dictating;
    g->initialized = g->covered = g->ready = g->tracking = g->dictating = false;
    return active ? APStopDictation : APNone;
}

static inline APAction APObserve(APGesture *g, bool covered, double now) {
    if (!g->initialized) {
        g->initialized = true;
        g->covered = covered;
        g->ready = !covered;
        return APNone;
    }
    if (g->covered == covered) return APNone;
    g->covered = covered;
    if (covered) {
        if (!g->ready) return APNone;
        g->ready = false;
        g->tracking = true;
        g->pressedAt = now;
        return APBeginTouch;
    }
    g->ready = true;
    bool wasTracking = g->tracking;
    g->tracking = false;
    if (g->dictating) {
        g->dictating = false;
        return APStopDictation;
    }
    // Released before the hold was confirmed (including a release that beats the hold timer).
    if (wasTracking && now - g->pressedAt >= g->minimumTapSeconds) return APTap;
    return wasTracking ? APDiscardTouch : APNone;
}

static inline APAction APTick(APGesture *g, double now) {
    if (!g->tracking || !g->covered) return APNone;
    double duration = now - g->pressedAt;
    if (duration >= g->maximumHoldSeconds) {
        bool active = g->dictating;
        g->tracking = g->dictating = false;
        return active ? APStopDictation : APNone;
    }
    if (!g->dictating && duration >= g->holdSeconds) {
        g->dictating = true;
        return APStartDictation;
    }
    return APNone;
}

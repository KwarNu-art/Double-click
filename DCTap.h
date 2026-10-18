// Pure C double tap detector (no UIKit), so it can be tested on any machine.
#ifndef DCTAP_H
#define DCTAP_H

#include <math.h>

typedef enum { DCTapBegan, DCTapMoved, DCTapEnded, DCTapCancelled } DCTapPhase;

typedef struct {
    int state;                         // 0 = idle, 1 = finger down, 2 = not a tap (moved, cancelled, two fingers)
    double beganX, beganY, beganTime;
    double lastTime, lastX, lastY;     // the previous completed tap
} DCTapState;

static inline void DCTapInvalidate(DCTapState *s) {
    s->state = 2;
    s->lastTime = 0;
}

// Feed every phase of a single finger. Returns 1 when this touch completes a double tap.
// A tap is a short touch that barely moves. Two taps count when they follow within maxGap seconds
// and land close together. Missing the "began" phase never blocks a tap, it only skips the checks.
static inline int DCTapFeed(DCTapState *s, DCTapPhase phase, double x, double y, double time, double maxGap) {
    switch (phase) {
        case DCTapBegan:
            s->state = 1;
            s->beganX = x; s->beganY = y; s->beganTime = time;
            return 0;
        case DCTapMoved:
            if (s->state == 1 && hypot(x - s->beganX, y - s->beganY) > 14.0) s->state = 2;
            return 0;
        case DCTapCancelled:
            s->state = 2;
            s->lastTime = 0;
            return 0;
        case DCTapEnded:
            break;
    }

    int wasTap = 1;
    if (s->state == 2) wasTap = 0;
    if (s->state == 1 && ((time - s->beganTime) > 0.4 || hypot(x - s->beganX, y - s->beganY) > 14.0)) wasTap = 0;
    s->state = 0;
    if (!wasTap) { s->lastTime = 0; return 0; }

    if (s->lastTime > 0 && (time - s->lastTime) >= 0 && (time - s->lastTime) <= maxGap &&
        hypot(x - s->lastX, y - s->lastY) <= 60.0) {
        s->lastTime = 0;   // a third tap starts a new count
        return 1;
    }
    s->lastTime = time; s->lastX = x; s->lastY = y;
    return 0;
}

#endif

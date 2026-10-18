#include <stdio.h>
#include "../DCTap.h"

static int fails = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } else printf("ok:   %s\n", msg); } while (0)

// One tap: began at t, ended at t+dur.
static int tap(DCTapState *s, double t, double x, double y, double dur, double gap) {
    DCTapFeed(s, DCTapBegan, x, y, t, gap);
    return DCTapFeed(s, DCTapEnded, x, y, t + dur, gap);
}

int main(void) {
    DCTapState s = {0};
    double gap = 0.35;

    CHECK(tap(&s, 1.00, 100, 300, 0.08, gap) == 0, "first tap is not a double tap");
    CHECK(tap(&s, 1.22, 104, 302, 0.08, gap) == 1, "second tap 0.14s after the first ends = double tap");
    CHECK(tap(&s, 1.45, 104, 302, 0.08, gap) == 0, "third tap starts a new count");
    CHECK(tap(&s, 1.60, 104, 302, 0.08, gap) == 1, "fourth tap completes the next double tap");

    s = (DCTapState){0};
    tap(&s, 1.0, 100, 300, 0.08, gap);
    CHECK(tap(&s, 2.0, 100, 300, 0.08, gap) == 0, "taps 1 second apart are not a double tap");

    s = (DCTapState){0};
    tap(&s, 1.0, 100, 300, 0.08, gap);
    CHECK(tap(&s, 1.2, 300, 600, 0.08, gap) == 0, "taps far apart are not a double tap");

    s = (DCTapState){0};
    tap(&s, 1.0, 100, 300, 0.08, gap);
    DCTapFeed(&s, DCTapBegan, 100, 300, 1.2, gap);
    DCTapFeed(&s, DCTapMoved, 100, 360, 1.25, gap);
    CHECK(DCTapFeed(&s, DCTapEnded, 100, 380, 1.3, gap) == 0, "a swipe is not a tap");
    CHECK(tap(&s, 1.4, 100, 300, 0.08, gap) == 0, "a swipe resets the count");

    s = (DCTapState){0};
    tap(&s, 1.0, 100, 300, 0.08, gap);
    CHECK(tap(&s, 1.2, 100, 300, 0.9, gap) == 0, "a long press is not a tap");

    s = (DCTapState){0};
    DCTapFeed(&s, DCTapEnded, 100, 300, 1.0, gap);                 // began phase was missed
    CHECK(DCTapFeed(&s, DCTapEnded, 102, 300, 1.2, gap) == 1, "missing began phase does not block a double tap");

    s = (DCTapState){0};
    tap(&s, 1.0, 100, 300, 0.08, gap);
    DCTapInvalidate(&s);                                           // second finger touched
    CHECK(tap(&s, 1.2, 100, 300, 0.08, gap) == 0, "a two finger touch resets the count");

    s = (DCTapState){0};
    tap(&s, 1.0, 100, 300, 0.08, 0.25);
    CHECK(tap(&s, 1.45, 100, 300, 0.08, 0.25) == 0, "Fast speed rejects a 0.37s gap");
    s = (DCTapState){0};
    tap(&s, 1.0, 100, 300, 0.08, 0.5);
    CHECK(tap(&s, 1.45, 100, 300, 0.08, 0.5) == 1, "Relaxed speed accepts a 0.37s gap");

    printf(fails ? "\n%d FAILED\n" : "\nall passed\n", fails);
    return fails ? 1 : 0;
}

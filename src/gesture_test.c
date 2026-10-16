#include "Gesture.h"
#include <assert.h>
#include <stdio.h>
static APGesture fresh(void) {
    return (APGesture){.holdSeconds=.55, .minimumTapSeconds=.08, .maximumHoldSeconds=90};
}
int main(void) {
    APGesture g = fresh();
    // Starts covered: nothing until the sensor has been seen uncovered.
    assert(APObserve(&g,true,0)==APNone);
    assert(APTick(&g,10)==APNone);
    assert(APObserve(&g,false,11)==APNone);
    // Hold: dictation starts at the threshold and stops on release.
    assert(APObserve(&g,true,12)==APBeginTouch);
    assert(APTick(&g,12.4)==APNone);
    assert(APTick(&g,12.6)==APStartDictation);
    assert(APTick(&g,13)==APNone);
    assert(APObserve(&g,false,14)==APStopDictation);
    // Short touch: a tap. Two quick taps are just taps; the app decides what a tap does.
    assert(APObserve(&g,true,15)==APBeginTouch);
    assert(APObserve(&g,false,15.2)==APTap);
    assert(APObserve(&g,true,15.3)==APBeginTouch);
    assert(APObserve(&g,false,15.5)==APTap);
    // A glitch shorter than the minimum is discarded.
    assert(APObserve(&g,true,17)==APBeginTouch);
    assert(APObserve(&g,false,17.02)==APDiscardTouch);
    // Released past the hold threshold before the hold timer fired: still a tap, never dropped.
    assert(APObserve(&g,true,18)==APBeginTouch);
    assert(APObserve(&g,false,18.554)==APTap);
    // Connection loss resets; a stuck hold stops once at the maximum.
    assert(APObserve(&g,true,19)==APBeginTouch);
    assert(APCancel(&g)==APNone);
    assert(APObserve(&g,false,19.5)==APNone);
    assert(APObserve(&g,true,20)==APBeginTouch);
    assert(APTick(&g,21)==APStartDictation);
    assert(APTick(&g,111)==APStopDictation);
    assert(APTick(&g,112)==APNone);
    assert(APObserve(&g,false,113)==APNone);
    puts("Gesture checks passed: holds, taps, quick taps, glitches, release before the hold timer, loss, timeout.");
}

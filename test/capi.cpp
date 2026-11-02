// capi.cpp — C entry points into ik::VirtualCard + MockHw for diff_x86.py (ctypes).
#include "mock_hw.h"

#include <string.h>

using namespace iktest;

namespace {
struct Handle {
    explicit Handle(int s) : hw(scenario(s)) {}
    MockHw hw;
    ik::VirtualCard card;
};
} // namespace

extern "C" {

int ikt_scenario_count(void) {
    return scenarioCount();
}

void *ikt_open(int s) {
    if (s < 0 || s >= scenarioCount()) {
        return nullptr;
    }
    Handle *h = new Handle(s);
    if (h->card.init(&h->hw) != 0) {
        delete h;
        return nullptr;
    }
    return h;
}

void ikt_close(void *h) {
    delete (Handle *)h;
}

unsigned long long ikt_sector_count(void *h) {
    return ((Handle *)h)->card.sectorCount();
}

int ikt_read(void *h, unsigned long long lba, unsigned count, unsigned char *dst) {
    return ((Handle *)h)->card.readSectors(lba, count, dst);
}

void ikt_eeprom(int s, unsigned char *dst) {
    buildEeprom(scenario(s), dst);
}

unsigned ikt_reg(int s, unsigned offset) {
    MockHw hw(scenario(s));
    return hw.readReg(offset);
}

void ikt_frame(int s, unsigned page, unsigned char *dst) {
    buildFrame(scenario(s), page, dst);
}

unsigned ikt_frame_count(int s) {
    return expectedFrameCount(scenario(s));
}
}

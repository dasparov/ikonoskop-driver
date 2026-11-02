// mock_hw.h — userspace stand-in for the card reader hardware behind ik::HwOps.
//
// Serves a synthetic card-metadata EEPROM in the layout read by IkonoskopCardReader v1.2
// (and written by the camera's acamapp, metadata version 3) and synthetic frame DMA data
// with a recognizable per-flash-page pattern.
#ifndef IK_TEST_MOCK_HW_H
#define IK_TEST_MOCK_HW_H

#include "../core/ik_core.h"

#include <stdint.h>

namespace iktest {

struct TakeSpec {
    uint16_t firstBlock;     // erase block of the take's first frame
    uint16_t frames;         // frames recorded
    uint8_t fps;             // 0x1d = 29.97, 0x17 = 23.976, else integer fps
    bool tungsten;           // white balance bit
    uint8_t timecodeBase;    // primary timecode base (fps)
    uint32_t absTimecode;    // primary timecode of the first frame, in frames (24 bit)
    uint32_t absTimecodeAux; // aux timecode of the first frame, in `fps` frames (24 bit)
    uint8_t tcSwap;
    uint16_t sensorWord;     // low 4 bits = sensor type (0xe = monochrome)
    uint16_t fatTime;        // FAT time of creation
    uint16_t fatDate;        // FAT date of creation
    bool dense;              // frame pages carry a full pseudo-random payload
};

struct Scenario {
    const char *name;
    uint16_t cardNo;
    uint32_t eraseBlockSize;   // card geometry (4 KiB pages), reported by FPGA reg 0x30
    uint32_t flashSize;        // card geometry (4 KiB pages), reported by FPGA reg 0x2c
    bool geometryUnreported;   // FPGA regs 0x2c/0x30 read 0 (as right after a hot-plug)
    uint32_t takeCount;
    TakeSpec takes[8];
};

const Scenario &scenario(int index);
int scenarioCount();

// Fills the 0x2000-byte EEPROM image of a scenario.
void buildEeprom(const Scenario &sc, uint8_t *eeprom);

// Fills kFrameDmaBytes of synthetic DMA data for a flash page of a scenario.
void buildFrame(const Scenario &sc, uint32_t page, uint8_t *dst);

// Flash page of global frame index `frame` as the card stores it (independent of the core):
// returns false if the frame does not exist. `take` receives the take index.
bool expectedFramePage(const Scenario &sc, uint32_t frame, uint32_t *page, uint32_t *take);
// Frames listed in the IMAGE folder (corrupt takes count as one frame).
uint32_t expectedFrameCount(const Scenario &sc);

class MockHw : public ik::HwOps {
public:
    explicit MockHw(const Scenario &sc);
    ~MockHw() override;
    int readEeprom(uint32_t addr, uint8_t *dst, uint32_t len) override;
    const uint8_t *readFrame(uint32_t flashPage) override;
    uint32_t readReg(uint32_t offset) override;
    void log(const char *fmt, ...) override __attribute__((format(printf, 2, 3)));

    const Scenario &sc;
    uint8_t eeprom[0x2000];
    uint8_t *frame;
    uint32_t frameReads;      // readFrame calls
    uint32_t failPage;        // readFrame(failPage) fails while failPage != ~0u
    bool quiet;
};

} // namespace iktest

#endif // IK_TEST_MOCK_HW_H

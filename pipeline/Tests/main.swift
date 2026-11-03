import Foundation

exit(runTests([
    TestSuite(name: "xxhash64", run: xxhash64Tests),
    TestSuite(name: "timecode", run: timecodeTests),
    TestSuite(name: "eeprom", run: eepromTests),
    TestSuite(name: "ascmhl", run: ascmhlTests),
    TestSuite(name: "offload-verified", run: offloadVerifiedTests),
    TestSuite(name: "offload-corrupt-copy", run: offloadCorruptCopyTests),
    TestSuite(name: "offload-flaky-source", run: offloadFlakySourceTests),
    TestSuite(name: "offload-bad-first-read", run: offloadRereadReplacesBadCopyTests),
    TestSuite(name: "offload-first-frames", run: offloadFirstFrameTests),
    TestSuite(name: "offload-take-table", run: offloadTakeTableTests),
    TestSuite(name: "offload-kernel-log", run: offloadKernelLogTests),
    TestSuite(name: "offload-refuses-existing", run: offloadRefusesExistingTests),
    TestSuite(name: "losslessJPEG", run: losslessJPEGTests),
    TestSuite(name: "clean-dng", run: cleanDNGTests),
    TestSuite(name: "audio", run: audioTests),
    TestSuite(name: "colour-profile", run: colourProfileTests),
    TestSuite(name: "prores", run: proResTests),
]))

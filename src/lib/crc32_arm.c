// Hardware CRC32 for ARM (standard polynomial, NOT CRC32-C)
// Compiled with CRC extension enabled via build.zig target features.

#ifdef __aarch64__
#include <arm_acle.h>

unsigned int crc32_arm_hw(const unsigned char *data, unsigned long len) {
    unsigned int crc = 0xFFFFFFFF;
    unsigned long pos = 0;

    // Process 8 bytes at a time
    while (pos + 8 <= len) {
        unsigned long long val;
        __builtin_memcpy(&val, data + pos, 8);
        crc = __crc32d(crc, val);
        pos += 8;
    }

    // Process 4 bytes if remaining
    if (pos + 4 <= len) {
        unsigned int val;
        __builtin_memcpy(&val, data + pos, 4);
        crc = __crc32w(crc, val);
        pos += 4;
    }

    // Process remaining bytes
    while (pos < len) {
        crc = __crc32b(crc, data[pos]);
        pos++;
    }

    return crc ^ 0xFFFFFFFF;
}
#endif

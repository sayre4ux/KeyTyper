// Fuzz test for the helper's packet check. Compares valid() with a separate reading of the
// protocol table on exhaustive and random packets, under AddressSanitizer and UBSan.
// Built and run by test.sh; needs no driver and sends nothing.
#include <cstdio>
#include "protocol.hpp"

static bool expected(const uint8_t* p) {
    if (p[0] != 1 || p[1] > 1) return false;
    if (p[1] == 0) return true;
    bool usage = (p[2] >= 4 && p[2] <= 56) || p[2] == 100;
    bool modifier = p[3] == 0 || p[3] == 2;
    unsigned hold = p[4] + 256u * p[5], gap = p[6] + 256u * p[7];
    return usage && modifier && hold >= 10 && hold <= 200 && gap <= 500;
}

static unsigned long long state = 0x5459504554485255ull; // fixed seed: failures reproduce
static uint64_t next() { // splitmix64
    uint64_t z = (state += 0x9e3779b97f4a7c15ull);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

static long checked = 0, accepted = 0;
static bool same(const uint8_t* p) {
    // A heap copy of exactly 8 bytes, so AddressSanitizer catches any read past the packet.
    uint8_t* packet = new uint8_t[8];
    for (int i = 0; i < 8; i++) packet[i] = p[i];
    bool result = valid(packet);
    delete[] packet;
    checked++; accepted += result;
    if (result == expected(p)) return true;
    std::fprintf(stderr, "FAIL: valid() = %d for %u,%u,%u,%u,%u,%u,%u,%u\n", result,
                 p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    return false;
}

int main() {
    uint8_t p[8] = {1, 1, 4, 0, 80, 0, 0, 0};
    // Every version, type, usage, and modifier byte, with typical timing.
    for (int a = 0; a < 256; a++) for (int b = 0; b < 256; b++) for (int c = 0; c < 256; c++) {
        p[0] = 1; p[1] = a; p[2] = b; p[3] = c; if (!same(p)) return 1;
        p[0] = a; p[1] = 1; p[2] = b; p[3] = c; if (!same(p)) return 1;
    }
    // Every hold and every gap value.
    for (int v = 0; v < 65536; v++) {
        uint8_t q[8] = {1, 1, 4, 0, uint8_t(v), uint8_t(v >> 8), 0, 0};
        if (!same(q)) return 1;
        uint8_t r[8] = {1, 1, 4, 2, 80, 0, uint8_t(v), uint8_t(v >> 8)};
        if (!same(r)) return 1;
    }
    // Random packets, and random packets that start as a valid key press.
    for (int i = 0; i < 4000000; i++) {
        uint64_t x = next();
        for (int k = 0; k < 8; k++) p[k] = uint8_t(x >> (8 * k));
        if (!same(p)) return 1;
        uint8_t q[8] = {1, 1, uint8_t(4 + x % 53), uint8_t((x >> 8) % 2 * 2), uint8_t(10 + (x >> 16) % 191), 0,
                        uint8_t((x >> 24) % 250), uint8_t((x >> 32) % 2)};
        q[(x >> 40) % 8] ^= uint8_t(x >> 48); // flip bits in one byte, sometimes none
        if (!same(q)) return 1;
    }
    std::printf("ok  Helper packet fuzz (%ld packets, %ld accepted, AddressSanitizer + UBSan)\n", checked, accepted);
    return 0;
}

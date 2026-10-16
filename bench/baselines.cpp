// C entry points for the third party libraries the benchmark compares against.
//
// simdutf is a C++ library, so this file gives the C benchmark a plain
// function to call. google/crc32c already has a C interface but is wrapped here
// too so both libraries are reached the same way and appear in one place.
//
// Built only by make bench-full, after bench/fetch-baselines.sh.

#include <cstddef>
#include <cstdint>
#include <string>

#include "simdutf.h"
#include "crc32c/crc32c.h"

extern "C" int hp_bench_simdutf_is_ascii(const void *buf, size_t len)
{
    return simdutf::validate_ascii(static_cast<const char *>(buf), len) ? 1 : 0;
}

extern "C" uint32_t hp_bench_google_crc32c(uint32_t crc, const void *buf, size_t len)
{
    return crc32c::Extend(crc, static_cast<const uint8_t *>(buf), len);
}

extern "C" const char *hp_bench_simdutf_kernel(void)
{
    static const std::string name(simdutf::get_active_implementation()->name());
    return name.c_str();
}

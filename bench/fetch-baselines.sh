#!/bin/sh
#
# Fetch and build the third party libraries that make bench-full compares
# against. Versions and checksums are pinned so a rerun measures the same code.
#
#   simdutf 9.2.1   validate_ascii, the usual answer to "is this buffer ASCII"
#   google/crc32c   1.1.2, the CRC-32C library used by LevelDB and RocksDB
#
# Usage: sh bench/fetch-baselines.sh [dest]     (default build/third_party)
#
# Needs curl, a C++ compiler and cmake. Nothing is installed system wide.

set -eu

DEST="${1:-build/third_party}"
CXX="${CXX:-g++}"

SIMDUTF_VERSION=9.2.1
SIMDUTF_CPP_SHA256=9d99344ce132040987d11841b1d69900a90ab902efcda61b6552fc6c4515589d
SIMDUTF_H_SHA256=27cbcc731b268c36932fabeccd8b7a940804cc51b1325e2221a76b26c5bfab23

CRC32C_VERSION=1.1.2
CRC32C_SHA256=ac07840513072b7fcebda6e821068aa04889018f24e10e46181068fb214d7e56

mkdir -p "$DEST"
cd "$DEST"

fetch() {
    url="$1"
    out="$2"
    want="$3"
    if [ ! -f "$out" ]; then
        curl -sSfL --retry 3 -o "$out.part" "$url"
        mv "$out.part" "$out"
    fi
    got=$(sha256sum "$out" | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
        echo "checksum mismatch for $out: got $got, want $want" >&2
        rm -f "$out"
        exit 1
    fi
}

# simdutf ships a single header and a single source file per release.
mkdir -p simdutf
fetch "https://github.com/simdutf/simdutf/releases/download/v$SIMDUTF_VERSION/simdutf.cpp" \
    simdutf/simdutf.cpp "$SIMDUTF_CPP_SHA256"
fetch "https://github.com/simdutf/simdutf/releases/download/v$SIMDUTF_VERSION/simdutf.h" \
    simdutf/simdutf.h "$SIMDUTF_H_SHA256"
if [ ! -f simdutf/simdutf.o ]; then
    echo "building simdutf $SIMDUTF_VERSION"
    "$CXX" -std=c++17 -O3 -c simdutf/simdutf.cpp -o simdutf/simdutf.o
fi

# google/crc32c builds with cmake. Its own tests and benchmarks need
# submodules that the release tarball does not carry, so they are switched
# off. CMAKE_POLICY_VERSION_MINIMUM lets cmake 4 accept the project's old
# minimum version line; older cmake ignores it.
fetch "https://github.com/google/crc32c/archive/refs/tags/$CRC32C_VERSION.tar.gz" \
    crc32c.tar.gz "$CRC32C_SHA256"
if [ ! -f crc32c/install/lib/libcrc32c.a ] && [ ! -f crc32c/install/lib64/libcrc32c.a ]; then
    echo "building google/crc32c $CRC32C_VERSION"
    rm -rf crc32c
    mkdir -p crc32c
    tar -xzf crc32c.tar.gz -C crc32c --strip-components=1
    cmake -S crc32c -B crc32c/build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCRC32C_BUILD_TESTS=OFF -DCRC32C_BUILD_BENCHMARKS=OFF \
        -DCRC32C_USE_GLOG=OFF -DCRC32C_INSTALL=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_INSTALL_PREFIX="$(pwd)/crc32c/install" > crc32c-cmake.log
    cmake --build crc32c/build --parallel > crc32c-build.log
    cmake --install crc32c/build > crc32c-install.log
    if [ -d crc32c/install/lib64 ] && [ ! -d crc32c/install/lib ]; then
        ln -s lib64 crc32c/install/lib
    fi
fi

echo "baselines ready in $DEST"

# hotpath build rules.
#
# The assembler is GNU as. The kernels are .S files in Intel syntax, which gcc
# hands to GNU as after running the C preprocessor over them, and which clang
# assembles with its integrated assembler, so a plain toolchain is enough to
# build this. CI pins both: see .github/workflows/ci.yml.
#
# Two targets are supported:
#   x86-64 Linux, System V ABI, ELF: static and shared library
#   x86-64 Windows, Microsoft x64 ABI, PE/COFF via MinGW-w64: static library
# The target is read from the compiler, so a cross build is just
#   make CC=x86_64-w64-mingw32-gcc AR=x86_64-w64-mingw32-ar RUNNER=wine
#
# Useful overrides:
#   make CC=clang
#   make OPT=-O0
#   make BUILD=build-asan EXTRA_CFLAGS="-fsanitize=address" ...
#   make RUNNER="sde64 -skx --" test    run every test binary under a wrapper
#   make TIERS="baseline avx512" test-tiers
#
# Targets: all, test, test-tiers, bench, bench-full, sanitize, check, clean.

# make predefines CC as cc, so ?= would never fire. Only replace the default.
ifeq ($(origin CC),default)
CC = gcc
endif

AR       ?= ar
NM       ?= nm
OBJDUMP  ?= objdump
BUILD    ?= build
OPT      ?= -O2
CSTD     ?= -std=c11
PYTHON   ?= python3
RUNNER   ?=

# Read the target from the compiler rather than the host, so cross builds work.
# MinGW-w64 gcc reports x86_64-w64-mingw32, clang x86_64-w64-windows-gnu.
TARGET_TRIPLE := $(shell $(CC) -dumpmachine)
ifneq (,$(findstring mingw,$(TARGET_TRIPLE))$(findstring windows,$(TARGET_TRIPLE)))
WINDOWS  := 1
EXE      := .exe
else
WINDOWS  :=
EXE      :=
endif

WARNINGS  = -Wall -Wextra -Wpedantic -Wstrict-prototypes -Wshadow -Wvla \
            -Wcast-qual -Wpointer-arith -Wwrite-strings
INCLUDES  = -Iinclude -Isrc
DEFINES   = -D_DEFAULT_SOURCE
ifdef WINDOWS
# C99 printf formats such as %zu, whichever C runtime the toolchain targets.
DEFINES  += -D__USE_MINGW_ANSI_STDIO=1
endif

ALL_CFLAGS  = $(CSTD) $(OPT) -g $(WARNINGS) $(INCLUDES) $(DEFINES) $(CFLAGS) $(EXTRA_CFLAGS)
# The assembler does not know the C warning or standard flags, so .S files get
# a deliberately smaller set.
ALL_ASFLAGS = $(OPT) -g $(INCLUDES) $(EXTRA_CFLAGS)
ALL_LDFLAGS = $(LDFLAGS) $(EXTRA_LDFLAGS)

LIB_C_SRC = src/cpu.c \
            src/crc32c_tables.c \
            src/ref/crc32c_ref.c \
            src/ref/bytes_ref.c
LIB_S_SRC = src/asm/cpuid.S \
            src/asm/crc32c.S \
            src/asm/bytes_avx2.S \
            src/asm/bytes_avx512.S \
            src/asm/hex_ssse3.S
ASM_HDR   = src/asm/hp_asm.h

LIB_OBJ = $(LIB_C_SRC:%.c=$(BUILD)/%.o) $(LIB_S_SRC:%.S=$(BUILD)/%.o)
PIC_OBJ = $(LIB_C_SRC:%.c=$(BUILD)/pic/%.o) $(LIB_S_SRC:%.S=$(BUILD)/pic/%.o)

STATIC = $(BUILD)/libhotpath.a
ifdef WINDOWS
SHARED =
else
SHARED = $(BUILD)/libhotpath.so
endif

TEST_NAMES = test_vectors test_differential test_overread test_abi
TEST_BIN   = $(TEST_NAMES:%=$(BUILD)/%$(EXE))

TOOL_BIN = $(BUILD)/hpscan$(EXE) $(BUILD)/bench$(EXE)

.PHONY: all test test-tiers bench bench-full sanitize check check-generated \
        check-noexecstack check-asm check-exports demo clean

all: $(STATIC) $(SHARED) $(TOOL_BIN)

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S $(ASM_HDR)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_ASFLAGS) -c $< -o $@

$(BUILD)/pic/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -fPIC -c $< -o $@

$(BUILD)/pic/%.o: %.S $(ASM_HDR)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_ASFLAGS) -fPIC -c $< -o $@

$(STATIC): $(LIB_OBJ)
	@mkdir -p $(dir $@)
	rm -f $@
	$(AR) rcs $@ $(LIB_OBJ)

VERSION_SCRIPT = scripts/hotpath.map

$(BUILD)/libhotpath.so: $(PIC_OBJ) $(VERSION_SCRIPT)
	@mkdir -p $(dir $@)
	$(CC) -shared -Wl,-z,noexecstack \
	    -Wl,--version-script=$(VERSION_SCRIPT) \
	    -o $@ $(PIC_OBJ) $(ALL_LDFLAGS)

# test_abi carries its own assembly: the register checker it calls through.
$(BUILD)/test_abi$(EXE): tests/test_abi.c $(BUILD)/tests/abi_check.o $(STATIC) tests/testutil.h
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) $< $(BUILD)/tests/abi_check.o $(STATIC) -o $@ $(ALL_LDFLAGS)

$(BUILD)/%$(EXE): tests/%.c $(STATIC) tests/testutil.h
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) $< $(STATIC) -o $@ $(ALL_LDFLAGS)

$(BUILD)/hpscan$(EXE): tools/hpscan.c $(STATIC)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) $< $(STATIC) -o $@ $(ALL_LDFLAGS)

# ------------------------------------------------------------- benchmarks --
#
# The benchmark compares against the portable C references twice: as built
# for the library, and rebuilt here with NATIVE_OPT under different symbol
# names, so the compiler may auto-vectorise them for the exact host CPU.
NATIVE_OPT ?= -O3 -march=native
NATIVE_RENAME = -Dhp_crc32c_ref=hp_crc32c_native \
                -Dhp_crc32c_bitwise=hp_crc32c_bitwise_native \
                -Dhp_count_byte_ref=hp_count_byte_native \
                -Dhp_find_byte_ref=hp_find_byte_native \
                -Dhp_is_ascii_ref=hp_is_ascii_native \
                -Dhp_hex_encode_ref=hp_hex_encode_native
NATIVE_OBJ = $(BUILD)/native/bytes_ref.o $(BUILD)/native/crc32c_ref.o
BENCH_DEFS = -DHP_NATIVE_FLAGS='"$(NATIVE_OPT)"'

$(BUILD)/native/%.o: src/ref/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CSTD) $(NATIVE_OPT) -g $(WARNINGS) $(INCLUDES) $(DEFINES) \
	    $(NATIVE_RENAME) $(CFLAGS) $(EXTRA_CFLAGS) -c $< -o $@

$(BUILD)/bench$(EXE): bench/bench.c $(NATIVE_OBJ) $(STATIC)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) $(BENCH_DEFS) $< $(NATIVE_OBJ) $(STATIC) -o $@ $(ALL_LDFLAGS)

bench: $(BUILD)/bench$(EXE)
	@$(BUILD)/bench$(EXE) $(BENCH_ARGS)

# bench-full adds third party libraries that do the same jobs: simdutf and
# google/crc32c, fetched at pinned versions by bench/fetch-baselines.sh.
CXX ?= g++
THIRD_PARTY = $(BUILD)/third_party
TP_SIMDUTF  = $(THIRD_PARTY)/simdutf
TP_CRC32C   = $(THIRD_PARTY)/crc32c/install

$(TP_SIMDUTF)/simdutf.o:
	CXX="$(CXX)" sh bench/fetch-baselines.sh $(THIRD_PARTY)

$(BUILD)/bench-full$(EXE): bench/bench.c bench/baselines.cpp $(NATIVE_OBJ) $(STATIC) $(TP_SIMDUTF)/simdutf.o
	@mkdir -p $(BUILD)/benchfull
	$(CXX) -std=c++17 -O2 -I$(TP_SIMDUTF) -I$(TP_CRC32C)/include \
	    -c bench/baselines.cpp -o $(BUILD)/benchfull/baselines.o
	$(CC) $(ALL_CFLAGS) $(BENCH_DEFS) -DHP_BENCH_LIBS -c bench/bench.c \
	    -o $(BUILD)/benchfull/bench.o
	$(CXX) -o $@ $(BUILD)/benchfull/bench.o $(BUILD)/benchfull/baselines.o \
	    $(TP_SIMDUTF)/simdutf.o $(NATIVE_OBJ) $(STATIC) $(TP_CRC32C)/lib/libcrc32c.a \
	    $(ALL_LDFLAGS)

bench-full: $(BUILD)/bench-full$(EXE)
	@$(BUILD)/bench-full$(EXE) $(BENCH_ARGS)

# ------------------------------------------------------------------ tests --

# Each test binary walks every dispatch tier the host supports, so one run
# covers the scalar paths as well as the vector ones. RUNNER wraps each one,
# which is how CI runs the suite under Intel SDE.
test: $(TEST_BIN)
	@set -e; for t in $(TEST_BIN); do echo "== $$t"; $(RUNNER) $$t; done
	@echo "all tests passed"

# The same suite once per tier, each run restricted to that tier and failing
# if the CPU cannot run it. TIERS defaults to every tier this CPU supports.
test-tiers: $(TEST_BIN) $(BUILD)/hpscan$(EXE)
	@set -e; tiers="$(TIERS)"; \
	if [ -z "$$tiers" ]; then \
	    tiers=$$($(RUNNER) $(BUILD)/hpscan$(EXE) --cpu | tr -d '\r' \
	        | sed -n 's/^tiers *: //p' | tr ' ' '\n' | sed -n 's/=yes$$//p'); \
	fi; \
	for tier in $$tiers; do \
	    for t in $(TEST_BIN); do \
	        echo "== $$t [$$tier only]"; \
	        HOTPATH_TEST_TIERS=$$tier $(RUNNER) $$t; \
	    done; \
	done; \
	echo "every tier passed on its own: $$(echo $$tiers)"

sanitize:
	@$(MAKE) --no-print-directory BUILD=$(BUILD)-asan \
	    EXTRA_CFLAGS="-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer" \
	    EXTRA_LDFLAGS="-fsanitize=address,undefined" \
	    test

# The generated table file must match what the generator produces today.
check-generated:
	$(PYTHON) tools/gen_crc32c_tables.py --output src/crc32c_tables.c --check

# Hand written assembly is the usual reason a shared object ends up asking for
# an executable stack, which is why every .S file carries a .note.GNU-stack
# marker. This proves the marker survived into the linked object.
check-noexecstack: $(SHARED)
	@readelf -lW $(SHARED) | grep -q 'GNU_STACK.*RW ' \
	    && echo "stack is non executable" \
	    || { echo "FAIL: $(SHARED) requests an executable stack"; exit 1; }

# A build that quietly lost the assembly would still pass every functional
# test, because the portable references would answer for it. Reading the
# instructions back out of the archive is what rules that out.
CHECK_INSNS = cpuid xgetbv crc32 vpcmpeqb vpsadbw vpmovmskb vpbroadcastb \
              vpsubb vpor pshufb punpcklbw punpckhbw vzeroupper \
              kmovq kortestq korq popcnt bzhi vmovdqu8 vpord vpmovb2m

check-asm: $(STATIC)
	@$(OBJDUMP) -d $(STATIC) > $(BUILD)/disasm.txt
	@for insn in $(CHECK_INSNS); do \
	    grep -qE "[[:space:]]$$insn[a-z]?([[:space:]]|$$)" $(BUILD)/disasm.txt \
	        || { echo "FAIL: $$insn is missing from $(STATIC)"; exit 1; }; \
	done
	@echo "every expected instruction is present in the archive"

# End to end: build a log file, scan it, and check the answers against tools
# that know nothing about this library.
demo: $(BUILD)/hpscan$(EXE)
	@HPSCAN_RUNNER="$(RUNNER)" sh scripts/demo.sh $(BUILD)/hpscan$(EXE)

# A public function that nobody added to the version script would still link
# and still pass every test, and would then be missing for anyone using the
# shared library. Comparing the two lists is what catches that.
check-exports: $(SHARED)
	@$(NM) -D --defined-only $(SHARED) \
	    | awk '$$2 ~ /^[TDBR]$$/ {print $$3}' | sed 's/@@.*//' | sort -u > $(BUILD)/exports.actual
	@sed -n '/global:/,/local:/p' $(VERSION_SCRIPT) \
	    | tr -d ' 	' | grep ';' | grep -v 'global:' | grep -v 'local:' \
	    | tr -d ';' | sort -u > $(BUILD)/exports.expected
	@diff -u $(BUILD)/exports.expected $(BUILD)/exports.actual \
	    && echo "the shared library exports exactly the documented interface"

ifdef WINDOWS
# No shared library is built for Windows, so the ELF specific checks do not
# apply there.
check: test check-asm demo
else
check: check-generated test check-noexecstack check-asm check-exports demo
endif

clean:
	rm -rf $(BUILD) $(BUILD)-asan

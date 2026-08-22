# hotpath build rules.
#
# There is no external assembler dependency. The kernels are .S files in Intel
# syntax, which gcc and clang both hand to their own assembler after running
# the C preprocessor over them, so a plain toolchain is enough to build this.
#
# Useful overrides:
#   make CC=clang
#   make OPT=-O0
#   make BUILD=build-asan EXTRA_CFLAGS="-fsanitize=address" ...
#
# Targets: all, test, bench, sanitize, check, clean.

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

WARNINGS  = -Wall -Wextra -Wpedantic -Wstrict-prototypes -Wshadow -Wvla \
            -Wcast-qual -Wpointer-arith -Wwrite-strings
INCLUDES  = -Iinclude -Isrc
DEFINES   = -D_DEFAULT_SOURCE

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
            src/asm/hex_ssse3.S

LIB_OBJ = $(LIB_C_SRC:%.c=$(BUILD)/%.o) $(LIB_S_SRC:%.S=$(BUILD)/%.o)
PIC_OBJ = $(LIB_C_SRC:%.c=$(BUILD)/pic/%.o) $(LIB_S_SRC:%.S=$(BUILD)/pic/%.o)

STATIC = $(BUILD)/libhotpath.a
SHARED = $(BUILD)/libhotpath.so

TEST_SRC = tests/test_vectors.c tests/test_differential.c tests/test_overread.c
TEST_BIN = $(TEST_SRC:tests/%.c=$(BUILD)/%)

TOOL_BIN = $(BUILD)/hpscan $(BUILD)/bench

.PHONY: all test bench sanitize check check-generated check-noexecstack check-asm check-exports demo clean

all: $(STATIC) $(SHARED) $(TOOL_BIN)

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S
	@mkdir -p $(dir $@)
	$(CC) $(ALL_ASFLAGS) -c $< -o $@

$(BUILD)/pic/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -fPIC -c $< -o $@

$(BUILD)/pic/%.o: %.S
	@mkdir -p $(dir $@)
	$(CC) $(ALL_ASFLAGS) -fPIC -c $< -o $@

$(STATIC): $(LIB_OBJ)
	@mkdir -p $(dir $@)
	$(AR) rcs $@ $(LIB_OBJ)

VERSION_SCRIPT = scripts/hotpath.map

$(SHARED): $(PIC_OBJ) $(VERSION_SCRIPT)
	@mkdir -p $(dir $@)
	$(CC) -shared -Wl,-z,noexecstack \
	    -Wl,--version-script=$(VERSION_SCRIPT) \
	    -o $@ $(PIC_OBJ) $(ALL_LDFLAGS)

$(BUILD)/%: tests/%.c $(STATIC)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) $< $(STATIC) -o $@ $(ALL_LDFLAGS)

$(BUILD)/hpscan: tools/hpscan.c $(STATIC)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) $< $(STATIC) -o $@ $(ALL_LDFLAGS)

$(BUILD)/bench: bench/bench.c $(STATIC)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) $< $(STATIC) -o $@ $(ALL_LDFLAGS)

# Each test binary walks every dispatch tier the host supports, so one run
# covers the scalar paths as well as the vector ones.
test: $(TEST_BIN)
	@set -e; for t in $(TEST_BIN); do echo "== $$t"; $$t; done
	@echo "all tests passed"

bench: $(BUILD)/bench
	@$(BUILD)/bench

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
check-asm: $(STATIC)
	@$(OBJDUMP) -d $(STATIC) > $(BUILD)/disasm.txt
	@for insn in cpuid xgetbv crc32 vpcmpeqb vpsadbw vpmovmskb vpbroadcastb \
	            vpsubb vpor pshufb punpcklbw punpckhbw vzeroupper; do \
	    grep -qE "[[:space:]]$$insn[a-z]?([[:space:]]|$$)" $(BUILD)/disasm.txt \
	        || { echo "FAIL: $$insn is missing from $(STATIC)"; exit 1; }; \
	done
	@echo "every expected instruction is present in the archive"

# End to end: build a log file, scan it, and check the answers against tools
# that know nothing about this library.
demo: $(BUILD)/hpscan
	@sh scripts/demo.sh $(BUILD)/hpscan

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

check: check-generated test check-noexecstack check-asm check-exports demo

clean:
	rm -rf $(BUILD) $(BUILD)-asan

CC      ?= cc
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -g
BUILD   := build
# wl_wasm.c is the freestanding WebAssembly wrapper (built by build_wasm.sh with
# clang --target=wasm32); it is not part of the native sim_oracle.
SRC     := $(filter-out src/wl_wasm.c,$(wildcard src/*.c))

$(BUILD)/sim_oracle: $(SRC) | $(BUILD)
	$(CC) $(CFLAGS) $(SRC) -o $@ -lm

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

.PHONY: clean

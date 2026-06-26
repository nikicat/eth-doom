CC      ?= cc
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -g
BUILD   := build
SRC     := $(wildcard src/*.c)

$(BUILD)/sim_oracle: $(SRC) | $(BUILD)
	$(CC) $(CFLAGS) $(SRC) -o $@ -lm

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

.PHONY: clean

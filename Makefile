# verilog-alu -- Icarus Verilog + Yosys + Surfer
#
#   make test    exhaustive at small widths, then random at 8/16/32   (default)
#   make quick   just the exhaustive widths -- a few seconds
#   make synth   push through Yosys and print gate count vs WIDTH
#   make wave    run once at WIDTH=8 and open the VCD in Surfer
#   make lint    Verible style lint (local only; not part of CI)
#   make clean   delete build/

IVFLAGS := -g2012 -Wall
BUILD   := build
RTL     := rtl/alu.v
TB      := tb/tb_alu.v

# Widths small enough to prove every (op, a, b) triple by brute force.
# 1..3 are here on purpose: non-power-of-two widths are where a masked shift
# amount goes wrong, and WIDTH=1 is where $clog2 returns 0.
EXH_WIDTHS  := 1 2 3 4 5
# Too large to enumerate, so: corner cross-product + 10k random vectors.
RAND_WIDTHS := 8 16 32
# Widths reported by `make synth`.
SYN_WIDTHS  := 4 8 16 32

.PHONY: test quick exhaustive random synth wave lint clean

test: exhaustive random
	@echo "all widths passed"

quick: exhaustive

$(BUILD):
	@mkdir -p $(BUILD)

exhaustive: | $(BUILD)
	@for w in $(EXH_WIDTHS); do \
	  iverilog $(IVFLAGS) -s tb_alu -Ptb_alu.WIDTH=$$w \
	    -o $(BUILD)/tb_w$$w.out $(RTL) $(TB) || exit 1; \
	  vvp -n $(BUILD)/tb_w$$w.out | grep -E '^(===|  FAIL)' || exit 1; \
	done

random: | $(BUILD)
	@for w in $(RAND_WIDTHS); do \
	  iverilog $(IVFLAGS) -s tb_alu -Ptb_alu.WIDTH=$$w -Ptb_alu.EXHAUSTIVE=0 \
	    -o $(BUILD)/tb_w$$w.out $(RTL) $(TB) || exit 1; \
	  vvp -n $(BUILD)/tb_w$$w.out | grep -E '^(===|  FAIL)' || exit 1; \
	done

# Proves the RTL is synthesisable, not merely simulatable, and shows what
# parameterising actually costs: gate count against WIDTH.
synth: | $(BUILD)
	@printf "%8s %10s %11s\n" WIDTH cells cells/bit
	@for w in $(SYN_WIDTHS); do \
	  yosys -p "read_verilog -sv $(RTL); chparam -set WIDTH $$w alu; \
	            synth -top alu -flatten; stat" > $(BUILD)/synth_w$$w.log 2>&1 \
	    || { echo "yosys failed at WIDTH=$$w:"; tail -20 $(BUILD)/synth_w$$w.log; exit 1; }; \
	  awk -v w=$$w '/Number of cells:/ {c=$$NF} \
	                /^[[:space:]]*[0-9]+[[:space:]]+cells$$/ {c=$$1} \
	       END {if (c == "") exit 1; printf "%8d %10d %11.1f\n", w, c, c/w}' \
	       $(BUILD)/synth_w$$w.log \
	    || { echo "no cell count at WIDTH=$$w; yosys said:"; \
	         tail -20 $(BUILD)/synth_w$$w.log; exit 1; }; \
	done

wave: | $(BUILD)
	@iverilog $(IVFLAGS) -s tb_alu -Ptb_alu.WIDTH=8 -Ptb_alu.EXHAUSTIVE=0 \
	  -Ptb_alu.RANDOM_N=64 -o $(BUILD)/tb_wave.out $(RTL) $(TB)
	@vvp -n $(BUILD)/tb_wave.out +dump | tail -3
	@surfer $(BUILD)/alu.vcd

lint:
	@verible-verilog-lint --rules_config .rules.verible_lint $(RTL) $(TB) \
	  && echo "lint clean"

clean:
	@rm -rf $(BUILD)

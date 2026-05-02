## Run every FuseSoC sim target in the library. Fails on the first target whose
## testbench hits `$fatal` (or any other nonzero exit from iverilog/vvp).

FUSESOC ?= fusesoc
VERIBLE_VERILOG_LINT ?= verible-verilog-lint

TARGETS = \
	zubax:kulibin:nco::sim \
	zubax:kulibin:counter::sim \
	zubax:kulibin:numeric::sim_cast_signed \
	zubax:kulibin:numeric::sim_cast_signed_p \
	zubax:kulibin:numeric::sim_q_cast_p \
	zubax:kulibin:numeric::sim_round_signed \
	zubax:kulibin:freqdiv::sim_freqdivc \
	zubax:kulibin:deadtime::sim_deadtime_complementer \
	zubax:kulibin:deadtime::sim_deadtime_complementer_var \
	zubax:kulibin:async_parallel_bus_slave::sim_unit \
	zubax:kulibin:async_parallel_bus_slave::sim_integration \
	zubax:kulibin:cdc_sync::sim \
	zubax:kulibin:iir::sim_lpf \
	zubax:kulibin:iir::sim_hpf \
	zubax:kulibin:fir::sim \
	zubax:kulibin:cic_decimator::sim_comb_m1 \
	zubax:kulibin:cic_decimator::sim_cic_decimator \
	zubax:kulibin:cic_decimator::sim_cic_decimator_stagger \
	zubax:kulibin:cic_decimator::sim_cic_decimator_impulse \
	zubax:kulibin:cic_decimator::sim_cic_decimator_response \
	zubax:kulibin:cic_decimator::sim_cic_decimator_min_width \
	zubax:kulibin:cic_decimator::sim_cic_decimator_input_stagger \
	zubax:kulibin:cic_decimator::sim_cic_decimator_fir \
	zubax:kulibin:cic_decimator::sim_cic_decimator_fir_impulse \
	zubax:kulibin:cic_decimator::sim_cic_decimator_fir_phase \
	zubax:kulibin:cic_decimator::sim_cic_decimator_fir_scale_delay \
	zubax:kulibin:online_integrator::sim \
	zubax:kulibin:pwm::sim_up_down_pwm \
	zubax:kulibin:sdadc_to_pwm::sim

.PHONY: verify lint library clean

verify: library
	@set -e; \
	for t in $(TARGETS); do \
	  core="$${t%::*}"; target="$${t##*::}"; \
	  echo "=== $$core :: $$target ==="; \
	  $(FUSESOC) run --target=$$target $$core; \
	done; \
	echo "All testbenches passed."

lint:
	@find . -name '*.v' -not -path './build/*' -print0 | \
		xargs -0 $(VERIBLE_VERILOG_LINT) --rules_config .rules.verible_lint

library:
	@$(FUSESOC) library add kulibin . 2>/dev/null || true

clean:
	rm -rf build

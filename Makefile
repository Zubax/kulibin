## Run every FuseSoC sim target in the library. Fails on the first target whose
## testbench hits `$fatal` (or any other nonzero exit from iverilog/vvp).

FUSESOC ?= fusesoc

TARGETS = \
	zubax:kulibin:nco::sim \
	zubax:kulibin:numeric::sim_cast_signed \
	zubax:kulibin:numeric::sim_cast_signed_p \
	zubax:kulibin:numeric::sim_cast_signed_p2 \
	zubax:kulibin:numeric::sim_q_cast_p \
	zubax:kulibin:numeric::sim_round_signed \
	zubax:kulibin:numeric::sim_sine_lookup \
	zubax:kulibin:logic::sim_freqdivc \
	zubax:kulibin:logic::sim_deadtime_complementer \
	zubax:kulibin:async_parallel_bus_slave::sim_unit \
	zubax:kulibin:async_parallel_bus_slave::sim_integration \
	zubax:kulibin:iir::sim \
	zubax:kulibin:fir::sim \
	zubax:kulibin:cic_decimator::sim_comb_m1 \
	zubax:kulibin:cic_decimator::sim_cic_decimator \
	zubax:kulibin:cic_decimator::sim_cic_decimator_fir \
	zubax:kulibin:online_integrator::sim \
	zubax:kulibin:pwm::sim_up_down_pwm \
	zubax:kulibin:sdadc_to_pwm::sim

.PHONY: verify library clean

verify: library
	@set -e; \
	for t in $(TARGETS); do \
	  core="$${t%::*}"; target="$${t##*::}"; \
	  echo "=== $$core :: $$target ==="; \
	  $(FUSESOC) run --target=$$target $$core; \
	done; \
	echo "All testbenches passed."

library:
	@$(FUSESOC) library add kulibin . 2>/dev/null || true

clean:
	rm -rf build

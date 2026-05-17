## Run every FuseSoC sim target in the library and the synthesis checks. Fails
## on the first nonzero exit from a simulator or synthesis flow.

FUSESOC ?= fusesoc
VERIBLE_VERILOG_LINT ?= verible-verilog-lint
PYTHON ?= python3
FLOAT_SEED ?= 0x9e3779b97f4a7c15

FLOAT_CORE = zubax:kulibin:float
FLOAT_PYTHONPATH = $(CURDIR)/float/tb$(if $(PYTHONPATH),:$(PYTHONPATH))

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

FLOAT_PACK_MATRIX = \
	w2_m4_u4_exhaustive:2:4:4:exhaustive:0 \
	w3_m4_u5_exhaustive:3:4:5:exhaustive:0 \
	w5_m8_u8_random:5:8:8:random:768 \
	w8_m24_u12_random:8:24:12:random:2048

FLOAT_BINARY_MATRIX = \
	w2_m4_exhaustive:2:4:exhaustive:0 \
	w3_m4_exhaustive:3:4:exhaustive:0 \
	w3_m5_random:3:5:random:512 \
	w4_m6_random:4:6:random:512 \
	w5_m11_random:5:11:random:768 \
	w6_m18_random:6:18:random:768 \
	w7_m17_random:7:17:random:768 \
	w8_m24_random:8:24:random:1024 \
	w11_m53_random:11:53:random:384

FLOAT_UNARY_MATRIX = \
	w2_m4_exhaustive:2:4:exhaustive:0 \
	w3_m4_exhaustive:3:4:exhaustive:0 \
	w5_m11_random:5:11:random:512 \
	w8_m24_random:8:24:random:1024 \
	w11_m53_random:11:53:random:384

FLOAT_PIPE_MATRIX = \
	w8_n0:8:0:64 \
	w8_n4:8:4:96 \
	w24_n2:24:2:96

.PHONY: \
	verify verify-float verify-float-model verify-float-icarus verify-float-verilator verify-synth \
	coverage-float-report coverage-float-gate lint library synth-float synth-float-yosys \
	synth-float-diamond clean

verify: library
	@set -e; \
	for t in $(TARGETS); do \
	  core="$${t%::*}"; target="$${t##*::}"; \
	  echo "=== $$core :: $$target ==="; \
	  $(FUSESOC) run --target=$$target $$core; \
	done
	@$(MAKE) verify-float
	@$(MAKE) verify-synth
	@echo "All verification checks passed."

verify-float: library
	@$(MAKE) verify-float-model
	@$(MAKE) verify-float-icarus
	@$(MAKE) verify-float-verilator
	@$(MAKE) coverage-float-gate

verify-float-model:
	@PYTHONPATH="$(FLOAT_PYTHONPATH)" $(PYTHON) float/tb/test_zkf_model_layout.py

verify-float-icarus: library
	@set -e; \
	export PYTHONPATH="$(FLOAT_PYTHONPATH)"; \
	export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1; \
	export COCOTB_REWRITE_ASSERTION_FILES=; \
	run_pack() { \
	  sim="$$1"; config="$$2"; wexp="$$3"; wman="$$4"; wunbiased="$$5"; kind="$$6"; count="$$7"; \
	  root="build/float/$${sim}/pack/$${config}"; \
	  echo "=== $(FLOAT_CORE) :: sim_pack_$${sim} :: $${config} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_pack_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --WEXP_UNBIASED "$$wunbiased" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_WEXP_UNBIASED "$$wunbiased" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$config"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_binary() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; \
	  root="build/float/$${sim}/$${op}/$${config}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${config} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$config"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_unary() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; \
	  root="build/float/$${sim}/$${op}/$${config}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${config} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$config"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_pipe() { \
	  sim="$$1"; config="$$2"; width="$$3"; stages="$$4"; count="$$5"; \
	  root="build/float/$${sim}/pipe/$${config}"; \
	  echo "=== $(FLOAT_CORE) :: sim_pipe_$${sim} :: $${config} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_pipe_$${sim} \
	    $(FLOAT_CORE) --W "$$width" --N "$$stages" --ZKF_PIPE_W "$$width" --ZKF_PIPE_N "$$stages" \
	    --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$config"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	for spec in $(FLOAT_PACK_MATRIX); do \
	  old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	  run_pack icarus "$$1" "$$2" "$$3" "$$4" "$$5" "$$6"; \
	done; \
	for op in mul add div addsub cmp sort; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_binary icarus "$$op" "$$1" "$$2" "$$3" "$$4" "$$5"; \
	  done; \
	done; \
	for op in abs neg is_finite saturate; do \
	  for spec in $(FLOAT_UNARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_unary icarus "$$op" "$$1" "$$2" "$$3" "$$4" "$$5"; \
	  done; \
	done; \
	run_binary icarus add w6_m100_directed 6 100 directed 0; \
	for spec in $(FLOAT_PIPE_MATRIX); do \
	  old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	  run_pipe icarus "$$1" "$$2" "$$3" "$$4"; \
	done

verify-float-verilator: library
	@rm -rf build/float/verilator
	@set -e; \
	export PYTHONPATH="$(FLOAT_PYTHONPATH)"; \
	export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1; \
	export COCOTB_REWRITE_ASSERTION_FILES=; \
	run_pack() { \
	  sim="$$1"; config="$$2"; wexp="$$3"; wman="$$4"; wunbiased="$$5"; kind="$$6"; count="$$7"; \
	  root="build/float/$${sim}/pack/$${config}"; \
	  echo "=== $(FLOAT_CORE) :: sim_pack_$${sim} :: $${config} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_pack_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --WEXP_UNBIASED "$$wunbiased" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_WEXP_UNBIASED "$$wunbiased" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$config"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_binary() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; \
	  root="build/float/$${sim}/$${op}/$${config}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${config} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$config"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_unary() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; \
	  root="build/float/$${sim}/$${op}/$${config}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${config} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$config"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_pipe() { \
	  sim="$$1"; config="$$2"; width="$$3"; stages="$$4"; count="$$5"; \
	  root="build/float/$${sim}/pipe/$${config}"; \
	  echo "=== $(FLOAT_CORE) :: sim_pipe_$${sim} :: $${config} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_pipe_$${sim} \
	    $(FLOAT_CORE) --W "$$width" --N "$$stages" --ZKF_PIPE_W "$$width" --ZKF_PIPE_N "$$stages" \
	    --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$config"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	for spec in $(FLOAT_PACK_MATRIX); do \
	  old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	  run_pack verilator "$$1" "$$2" "$$3" "$$4" "$$5" "$$6"; \
	done; \
	for op in mul add div addsub cmp sort; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_binary verilator "$$op" "$$1" "$$2" "$$3" "$$4" "$$5"; \
	  done; \
	done; \
	for op in abs neg is_finite saturate; do \
	  for spec in $(FLOAT_UNARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_unary verilator "$$op" "$$1" "$$2" "$$3" "$$4" "$$5"; \
	  done; \
	done; \
	run_binary verilator add w6_m100_directed 6 100 directed 0; \
	for spec in $(FLOAT_PIPE_MATRIX); do \
	  old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	  run_pipe verilator "$$1" "$$2" "$$3" "$$4"; \
	done

coverage-float-report:
	$(PYTHON) float/tb/zkf_coverage.py --build-dir build/float/verilator --output-dir build/float/coverage

coverage-float-gate:
	$(PYTHON) float/tb/zkf_coverage.py --build-dir build/float/verilator --output-dir build/float/coverage --gate

verify-synth: library
	@$(MAKE) synth-float-yosys

lint:
	@find . -name '*.v' -not -path './build/*' -print0 | \
		xargs -0 $(VERIBLE_VERILOG_LINT) --rules_config .rules.verible_lint

library:
	@$(FUSESOC) library add kulibin . 2>/dev/null || true

synth-float:
	$(PYTHON) float/synth_float.py

synth-float-yosys:
	$(PYTHON) float/synth_float.py --flow yosys

synth-float-diamond:
	$(PYTHON) float/synth_float.py --flow diamond

clean:
	rm -rf build

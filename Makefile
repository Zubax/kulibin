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

# The const wrap requires WEXP>=3 to fit 1/3 and a 4-bit mantissa is the minimum accepted by the format. Vectors
# are hardcoded, so kind/count/seed are unused (passed for plusarg uniformity).
FLOAT_CONST_MATRIX = \
	w3_m4:3:4 \
	w6_m18:6:18 \
	w8_m24:8:24 \
	w11_m53:11:53

# Signed-int <-> float cast matrices share the same shape: wexp:wman:wint:kind:count.
FLOAT_FROM_INT_MATRIX = \
	w2_m4_int4_exhaustive:2:4:4:exhaustive:0 \
	w3_m4_int8_exhaustive:3:4:8:exhaustive:0 \
	w3_m5_int8_exhaustive:3:5:8:exhaustive:0 \
	w5_m11_int16_random:5:11:16:random:512 \
	w6_m18_int32_random:6:18:32:random:768 \
	w8_m24_int32_random:8:24:32:random:1024

FLOAT_TO_INT_MATRIX = \
	w2_m4_int4_exhaustive:2:4:4:exhaustive:0 \
	w3_m4_int8_exhaustive:3:4:8:exhaustive:0 \
	w3_m5_int8_exhaustive:3:5:8:exhaustive:0 \
	w5_m11_int16_random:5:11:16:random:512 \
	w6_m18_int32_random:6:18:32:random:768 \
	w8_m24_int32_random:8:24:32:random:1024 \
	w11_m53_int32_random:11:53:32:random:384

# Resize matrix shape: wexp_in:wman_in:wexp_out:wman_out:kind:count. The matrix covers all four
# (WMAN, WEXP) relation quadrants so every elaboration-time branch in zkf_resize is exercised:
#   * widen-only fast path: 3/4->3/4 (same), 3/4->4/4 (WEXP widens, WMAN same), 3/4->4/6 (both
#     widen), 3/4->3/6 (WMAN widens, WEXP same), 5/11->6/18 (both widen, wide reference).
#   * pack/g_widen slow path (WMAN_OUT >= WMAN_IN, WEXP_OUT < WEXP_IN): 5/4->3/4 (g_same_width),
#     5/4->3/6 (g_zero_pad).
#   * pack/g_narrow slow path (WMAN_OUT < WMAN_IN): 3/5->3/4 (DROP=1, g_round_zero,
#     g_sticky_zero), 4/6->3/4 (DROP=2, g_round_real, g_sticky_zero), 6/18->5/11 (DROP=7, all
#     real), 8/24->6/18 and 11/53->8/24 (deep narrowings under random).
FLOAT_RESIZE_MATRIX = \
	w3_m4_to_w3_m4_exhaustive:3:4:3:4:exhaustive:0 \
	w3_m4_to_w4_m4_exhaustive:3:4:4:4:exhaustive:0 \
	w3_m4_to_w3_m6_exhaustive:3:4:3:6:exhaustive:0 \
	w3_m5_to_w3_m4_exhaustive:3:5:3:4:exhaustive:0 \
	w3_m4_to_w4_m6_exhaustive:3:4:4:6:exhaustive:0 \
	w4_m6_to_w3_m4_exhaustive:4:6:3:4:exhaustive:0 \
	w5_m4_to_w3_m4_exhaustive:5:4:3:4:exhaustive:0 \
	w5_m4_to_w3_m6_exhaustive:5:4:3:6:exhaustive:0 \
	w6_m18_to_w5_m11_random:6:18:5:11:random:768 \
	w5_m11_to_w6_m18_random:5:11:6:18:random:768 \
	w8_m24_to_w6_m18_random:8:24:6:18:random:512 \
	w11_m53_to_w8_m24_random:11:53:8:24:random:384

.PHONY: \
	verify verify-deep verify-float verify-float-fast verify-float-deep verify-float-extended \
	verify-float-model verify-float-icarus verify-float-verilator verify-float-properties \
	verify-synth coverage-float-report coverage-float-gate coverage-float-gate-full formal-float formal-float-clean \
	lint library synth-float synth-float-yosys-ecp5 synth-float-yosys-spartan7 synth-float-diamond-ecp5 clean

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
	run_binary_sp() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; sp="$$8"; \
	  cfg="$${config}_sp$${sp}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_PRODUCT "$$sp" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_PRODUCT "$$sp" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_binary_si() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; si="$$8"; \
	  cfg="$${config}_si$${si}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_INPUT "$$si" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_INPUT "$$si" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_binary_sad() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; sd="$$8"; sa="$$9"; \
	  cfg="$${config}_sd$${sd}_sa$${sa}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_DECODE "$$sd" --STAGE_ALIGN "$$sa" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_DECODE "$$sd" --ZKF_STAGE_ALIGN "$$sa" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
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
	run_unary_sd() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; sd="$$8"; \
	  cfg="$${config}_sd$${sd}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_DECODE "$$sd" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_DECODE "$$sd" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
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
	run_cast_si() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; wint="$$6"; kind="$$7"; count="$$8"; si="$$9"; \
	  cfg="$${config}_si$${si}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --WINT "$$wint" --STAGE_INPUT "$$si" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_WINT "$$wint" --ZKF_STAGE_INPUT "$$si" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_resize_si() { \
	  sim="$$1"; config="$$2"; wexp_in="$$3"; wman_in="$$4"; wexp_out="$$5"; wman_out="$$6"; kind="$$7"; count="$$8"; si="$$9"; \
	  cfg="$${config}_si$${si}"; root="build/float/$${sim}/resize/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_resize_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_resize_$${sim} \
	    $(FLOAT_CORE) --WEXP_IN "$$wexp_in" --WMAN_IN "$$wman_in" --WEXP_OUT "$$wexp_out" --WMAN_OUT "$$wman_out" \
	    --STAGE_INPUT "$$si" \
	    --ZKF_WEXP_IN "$$wexp_in" --ZKF_WMAN_IN "$$wman_in" --ZKF_WEXP_OUT "$$wexp_out" --ZKF_WMAN_OUT "$$wman_out" \
	    --ZKF_STAGE_INPUT "$$si" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	for spec in $(FLOAT_PACK_MATRIX); do \
	  old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	  run_pack icarus "$$1" "$$2" "$$3" "$$4" "$$5" "$$6"; \
	done; \
	for op in cmp sort; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_binary icarus "$$op" "$$1" "$$2" "$$3" "$$4" "$$5"; \
	  done; \
	done; \
	for op in add addsub; do \
	  for sd in 0 1; do \
	    for sa in 0 1; do \
	      for spec in $(FLOAT_BINARY_MATRIX); do \
	        old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	        run_binary_sad icarus "$$op" "$$1" "$$2" "$$3" "$$4" "$$5" "$$sd" "$$sa"; \
	      done; \
	    done; \
	  done; \
	done; \
	for sp in 0 1; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_binary_sp icarus mul "$$1" "$$2" "$$3" "$$4" "$$5" "$$sp"; \
	  done; \
	done; \
	for si in 0 1; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_binary_si icarus div "$$1" "$$2" "$$3" "$$4" "$$5" "$$si"; \
	  done; \
	done; \
	for op in abs neg is_finite saturate; do \
	  for spec in $(FLOAT_UNARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_unary icarus "$$op" "$$1" "$$2" "$$3" "$$4" "$$5"; \
	  done; \
	done; \
	for spec in $(FLOAT_CONST_MATRIX); do \
	  old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	  run_unary icarus const "$$1" "$$2" "$$3" directed 0; \
	done; \
	for sd in 0 1; do \
	  for spec in $(FLOAT_UNARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_unary_sd icarus mul_ilog2_const "$$1" "$$2" "$$3" "$$4" "$$5" "$$sd"; \
	  done; \
	done; \
	for si in 0 1; do \
	  for spec in $(FLOAT_FROM_INT_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_cast_si icarus from_int "$$1" "$$2" "$$3" "$$4" "$$5" "$$6" "$$si"; \
	  done; \
	done; \
	for si in 0 1; do \
	  for spec in $(FLOAT_TO_INT_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_cast_si icarus to_int "$$1" "$$2" "$$3" "$$4" "$$5" "$$6" "$$si"; \
	  done; \
	done; \
	for si in 0 1; do \
	  for spec in $(FLOAT_RESIZE_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_resize_si icarus "$$1" "$$2" "$$3" "$$4" "$$5" "$$6" "$$7" "$$si"; \
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
	run_binary_sp() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; sp="$$8"; \
	  cfg="$${config}_sp$${sp}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_PRODUCT "$$sp" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_PRODUCT "$$sp" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_binary_si() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; si="$$8"; \
	  cfg="$${config}_si$${si}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_INPUT "$$si" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_INPUT "$$si" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_binary_sad() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; sd="$$8"; sa="$$9"; \
	  cfg="$${config}_sd$${sd}_sa$${sa}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_DECODE "$$sd" --STAGE_ALIGN "$$sa" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_DECODE "$$sd" --ZKF_STAGE_ALIGN "$$sa" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
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
	run_unary_sd() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; kind="$$6"; count="$$7"; sd="$$8"; \
	  cfg="$${config}_sd$${sd}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_DECODE "$$sd" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_DECODE "$$sd" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
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
	run_cast_si() { \
	  sim="$$1"; op="$$2"; config="$$3"; wexp="$$4"; wman="$$5"; wint="$$6"; kind="$$7"; count="$$8"; si="$$9"; \
	  cfg="$${config}_si$${si}"; root="build/float/$${sim}/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_$${op}_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_$${op}_$${sim} \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --WINT "$$wint" --STAGE_INPUT "$$si" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_WINT "$$wint" --ZKF_STAGE_INPUT "$$si" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_resize_si() { \
	  sim="$$1"; config="$$2"; wexp_in="$$3"; wman_in="$$4"; wexp_out="$$5"; wman_out="$$6"; kind="$$7"; count="$$8"; si="$$9"; \
	  cfg="$${config}_si$${si}"; root="build/float/$${sim}/resize/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_resize_$${sim} :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_resize_$${sim} \
	    $(FLOAT_CORE) --WEXP_IN "$$wexp_in" --WMAN_IN "$$wman_in" --WEXP_OUT "$$wexp_out" --WMAN_OUT "$$wman_out" \
	    --STAGE_INPUT "$$si" \
	    --ZKF_WEXP_IN "$$wexp_in" --ZKF_WMAN_IN "$$wman_in" --ZKF_WEXP_OUT "$$wexp_out" --ZKF_WMAN_OUT "$$wman_out" \
	    --ZKF_STAGE_INPUT "$$si" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	for spec in $(FLOAT_PACK_MATRIX); do \
	  old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	  run_pack verilator "$$1" "$$2" "$$3" "$$4" "$$5" "$$6"; \
	done; \
	for op in cmp sort; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_binary verilator "$$op" "$$1" "$$2" "$$3" "$$4" "$$5"; \
	  done; \
	done; \
	for op in add addsub; do \
	  for sd in 0 1; do \
	    for sa in 0 1; do \
	      for spec in $(FLOAT_BINARY_MATRIX); do \
	        old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	        run_binary_sad verilator "$$op" "$$1" "$$2" "$$3" "$$4" "$$5" "$$sd" "$$sa"; \
	      done; \
	    done; \
	  done; \
	done; \
	for sp in 0 1; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_binary_sp verilator mul "$$1" "$$2" "$$3" "$$4" "$$5" "$$sp"; \
	  done; \
	done; \
	for si in 0 1; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_binary_si verilator div "$$1" "$$2" "$$3" "$$4" "$$5" "$$si"; \
	  done; \
	done; \
	for op in abs neg is_finite saturate; do \
	  for spec in $(FLOAT_UNARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_unary verilator "$$op" "$$1" "$$2" "$$3" "$$4" "$$5"; \
	  done; \
	done; \
	for spec in $(FLOAT_CONST_MATRIX); do \
	  old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	  run_unary verilator const "$$1" "$$2" "$$3" directed 0; \
	done; \
	for sd in 0 1; do \
	  for spec in $(FLOAT_UNARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_unary_sd verilator mul_ilog2_const "$$1" "$$2" "$$3" "$$4" "$$5" "$$sd"; \
	  done; \
	done; \
	for si in 0 1; do \
	  for spec in $(FLOAT_FROM_INT_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_cast_si verilator from_int "$$1" "$$2" "$$3" "$$4" "$$5" "$$6" "$$si"; \
	  done; \
	done; \
	for si in 0 1; do \
	  for spec in $(FLOAT_TO_INT_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_cast_si verilator to_int "$$1" "$$2" "$$3" "$$4" "$$5" "$$6" "$$si"; \
	  done; \
	done; \
	for si in 0 1; do \
	  for spec in $(FLOAT_RESIZE_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_resize_si verilator "$$1" "$$2" "$$3" "$$4" "$$5" "$$6" "$$7" "$$si"; \
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

## Deep-tier-only extended sweep: fills the parity/relation/WINT parameter gaps (correctness, Icarus) and
## drives a curated set of exhaustive small-format Verilator runs into build/float/verilator-toggle for
## full line+branch+toggle coverage closure. Per-PR verify/verify-float never invoke this.
verify-float-extended: library
	@FUSESOC="$(FUSESOC)" PYTHON="$(PYTHON)" FLOAT_SEED="$(FLOAT_SEED)" PYTHONPATH="$(FLOAT_PYTHONPATH)" \
		bash float/tb/run_extended.sh

## Full coverage gate over the exhaustive coverage set: every line, branch, and toggle must be covered.
## Genuinely-unreachable points are suppressed in the RTL with `// verilator coverage_off`/`coverage_on`
## (no external waiver list). Deep-tier only.
coverage-float-gate-full:
	$(PYTHON) float/tb/zkf_coverage.py --build-dir build/float/verilator-toggle \
		--output-dir build/float/coverage-full --full

## Minimal smoke suite intended for interactive use between edits. Runs in well under a minute on a workstation.
## Compiles every public module under Icarus at its smallest exhaustive configuration; modules with a pipeline knob
## also run the same configuration with their knob set (STAGE_PRODUCT=1 for mul, STAGE_INPUT=1 for div/cast/resize)
## to catch breakage of the optional split. Skips Verilator, coverage gating, algebraic-property tests, formal proofs,
## all random sweeps, and the wide-WMAN configs.
## Use verify-float (medium) or verify-float-deep (full) for anything past quick regression checks.
verify-float-fast: library
	@$(MAKE) verify-float-model
	@set -e; \
	export PYTHONPATH="$(FLOAT_PYTHONPATH)"; \
	export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1; \
	export COCOTB_REWRITE_ASSERTION_FILES=; \
	smoke() { \
	  name="$$1"; target="$$2"; shift 2; \
	  root="build/float/fast/$${name}"; \
	  echo "=== $(FLOAT_CORE) :: $${target} :: $${name} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=$${target} \
	    $(FLOAT_CORE) "$$@" \
	    --ZKF_KIND exhaustive --ZKF_COUNT 0 --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$name"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	smoke pack          sim_pack_icarus               --WEXP 2 --WMAN 4 --WEXP_UNBIASED 4 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_WEXP_UNBIASED 4; \
	smoke cmp           sim_cmp_icarus                --WEXP 2 --WMAN 4 --ZKF_WEXP 2 --ZKF_WMAN 4; \
	smoke sort          sim_sort_icarus               --WEXP 2 --WMAN 4 --ZKF_WEXP 2 --ZKF_WMAN 4; \
	smoke abs           sim_abs_icarus                --WEXP 2 --WMAN 4 --ZKF_WEXP 2 --ZKF_WMAN 4; \
	smoke neg           sim_neg_icarus                --WEXP 2 --WMAN 4 --ZKF_WEXP 2 --ZKF_WMAN 4; \
	smoke is_finite     sim_is_finite_icarus          --WEXP 2 --WMAN 4 --ZKF_WEXP 2 --ZKF_WMAN 4; \
	smoke saturate      sim_saturate_icarus           --WEXP 2 --WMAN 4 --ZKF_WEXP 2 --ZKF_WMAN 4; \
	smoke const         sim_const_icarus              --WEXP 3 --WMAN 4 --ZKF_WEXP 3 --ZKF_WMAN 4; \
	smoke add_sd0_sa0   sim_add_icarus                --WEXP 2 --WMAN 4 --STAGE_DECODE 0 --STAGE_ALIGN 0 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_DECODE 0 --ZKF_STAGE_ALIGN 0; \
	smoke add_sd1_sa1   sim_add_icarus                --WEXP 2 --WMAN 4 --STAGE_DECODE 1 --STAGE_ALIGN 1 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_DECODE 1 --ZKF_STAGE_ALIGN 1; \
	smoke addsub_sd0_sa0 sim_addsub_icarus            --WEXP 2 --WMAN 4 --STAGE_DECODE 0 --STAGE_ALIGN 0 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_DECODE 0 --ZKF_STAGE_ALIGN 0; \
	smoke addsub_sd1_sa1 sim_addsub_icarus            --WEXP 2 --WMAN 4 --STAGE_DECODE 1 --STAGE_ALIGN 1 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_DECODE 1 --ZKF_STAGE_ALIGN 1; \
	smoke ilog2_sd0     sim_mul_ilog2_const_icarus    --WEXP 2 --WMAN 4 --STAGE_DECODE 0  --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_DECODE 0; \
	smoke ilog2_sd1     sim_mul_ilog2_const_icarus    --WEXP 2 --WMAN 4 --STAGE_DECODE 1  --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_DECODE 1; \
	smoke mul_sp0       sim_mul_icarus                --WEXP 2 --WMAN 4 --STAGE_PRODUCT 0 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_PRODUCT 0; \
	smoke mul_sp1       sim_mul_icarus                --WEXP 2 --WMAN 4 --STAGE_PRODUCT 1 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_PRODUCT 1; \
	smoke div_si0       sim_div_icarus                --WEXP 2 --WMAN 4 --STAGE_INPUT 0   --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_INPUT 0; \
	smoke div_si1       sim_div_icarus                --WEXP 2 --WMAN 4 --STAGE_INPUT 1   --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_STAGE_INPUT 1; \
	smoke from_int_si0  sim_from_int_icarus           --WEXP 2 --WMAN 4 --WINT 4 --STAGE_INPUT 0 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_WINT 4 --ZKF_STAGE_INPUT 0; \
	smoke from_int_si1  sim_from_int_icarus           --WEXP 2 --WMAN 4 --WINT 4 --STAGE_INPUT 1 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_WINT 4 --ZKF_STAGE_INPUT 1; \
	smoke to_int_si0    sim_to_int_icarus             --WEXP 2 --WMAN 4 --WINT 4 --STAGE_INPUT 0 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_WINT 4 --ZKF_STAGE_INPUT 0; \
	smoke to_int_si1    sim_to_int_icarus             --WEXP 2 --WMAN 4 --WINT 4 --STAGE_INPUT 1 --ZKF_WEXP 2 --ZKF_WMAN 4 --ZKF_WINT 4 --ZKF_STAGE_INPUT 1; \
	smoke resize_si0    sim_resize_icarus             --WEXP_IN 3 --WMAN_IN 4 --WEXP_OUT 3 --WMAN_OUT 4 --STAGE_INPUT 0 --ZKF_WEXP_IN 3 --ZKF_WMAN_IN 4 --ZKF_WEXP_OUT 3 --ZKF_WMAN_OUT 4 --ZKF_STAGE_INPUT 0; \
	smoke resize_si1    sim_resize_icarus             --WEXP_IN 3 --WMAN_IN 4 --WEXP_OUT 3 --WMAN_OUT 4 --STAGE_INPUT 1 --ZKF_WEXP_IN 3 --ZKF_WMAN_IN 4 --ZKF_WEXP_OUT 3 --ZKF_WMAN_OUT 4 --ZKF_STAGE_INPUT 1

verify-float-deep: library
	@$(MAKE) verify-float
	@$(MAKE) verify-float-extended
	@$(MAKE) coverage-float-gate-full
	@$(MAKE) verify-float-properties
	@$(MAKE) formal-float

## Maximum verification: every module simulation, every float algebraic property, and every formal proof.
## This is what runs in CI on the main branch and on commits whose message contains "#ci-float".
verify-deep: library
	@$(MAKE) verify
	@$(MAKE) verify-float-extended
	@$(MAKE) coverage-float-gate-full
	@$(MAKE) verify-float-properties
	@$(MAKE) formal-float
	@echo "Maximum-verification suite (project + float-properties + float-formal) passed."

verify-float-properties: library
	@set -e; \
	export PYTHONPATH="$(FLOAT_PYTHONPATH)"; \
	export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1; \
	export COCOTB_REWRITE_ASSERTION_FILES=; \
	run_props_sp() { \
	  op="$$1"; config="$$2"; wexp="$$3"; wman="$$4"; kind="$$5"; count="$$6"; sp="$$7"; \
	  cfg="$${config}_sp$${sp}"; root="build/float/properties/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_properties_$${op}_icarus :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_properties_$${op}_icarus \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_PRODUCT "$$sp" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_PRODUCT "$$sp" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	run_props_sad() { \
	  op="$$1"; config="$$2"; wexp="$$3"; wman="$$4"; kind="$$5"; count="$$6"; sd="$$7"; sa="$$8"; \
	  cfg="$${config}_sd$${sd}_sa$${sa}"; root="build/float/properties/$${op}/$${cfg}"; \
	  echo "=== $(FLOAT_CORE) :: sim_properties_$${op}_icarus :: $${cfg} ==="; \
	  rm -rf "$$root"; \
	  $(FUSESOC) run --build-root="$$root" --target=sim_properties_$${op}_icarus \
	    $(FLOAT_CORE) --WEXP "$$wexp" --WMAN "$$wman" --STAGE_DECODE "$$sd" --STAGE_ALIGN "$$sa" \
	    --ZKF_WEXP "$$wexp" --ZKF_WMAN "$$wman" --ZKF_STAGE_DECODE "$$sd" --ZKF_STAGE_ALIGN "$$sa" \
	    --ZKF_KIND "$$kind" --ZKF_COUNT "$$count" --ZKF_SEED "$(FLOAT_SEED)" --ZKF_CONFIG "$$cfg"; \
	  $(PYTHON) float/tb/zkf_results.py "$$root"; \
	}; \
	for op in add addsub; do \
	  for sd in 0 1; do \
	    for sa in 0 1; do \
	      for spec in $(FLOAT_BINARY_MATRIX); do \
	        old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	        run_props_sad "$$op" "$$1" "$$2" "$$3" "$$4" "$$5" "$$sd" "$$sa"; \
	      done; \
	    done; \
	  done; \
	done; \
	for sp in 0 1; do \
	  for spec in $(FLOAT_BINARY_MATRIX); do \
	    old_ifs="$$IFS"; IFS=:; set -- $$spec; IFS="$$old_ifs"; \
	    run_props_sp mul "$$1" "$$2" "$$3" "$$4" "$$5" "$$sp"; \
	  done; \
	done

formal-float: library
	@$(PYTHON) float/proof/run_proofs.py \
	    --sby-dir float/proof/sby \
	    --build-dir build/float/formal \
	    --report build/float/formal/report.html

formal-float-clean:
	rm -rf build/float/formal

verify-synth: library
	@$(MAKE) synth-float-yosys-ecp5

lint:
	@find . -name '*.v' -not -path './build/*' -print0 | \
		xargs -0 $(VERIBLE_VERILOG_LINT) --rules_config .rules.verible_lint

library:
	@$(FUSESOC) library add kulibin . 2>/dev/null || true

synth-float:
	@$(MAKE) synth-float-yosys-ecp5
	@$(MAKE) synth-float-yosys-spartan7
	@$(MAKE) synth-float-diamond-ecp5

synth-float-yosys-ecp5:
	$(PYTHON) float/synth/yosys_ecp5.py

synth-float-yosys-spartan7:
	$(PYTHON) float/synth/yosys_spartan.py

synth-float-diamond-ecp5:
	$(PYTHON) float/synth/diamond_ecp5.py

clean:
	rm -rf build

## Run every FuseSoC sim target in the library and the synthesis checks. Fails
## on the first nonzero exit from a simulator or synthesis flow.

FUSESOC ?= fusesoc
VERIBLE_VERILOG_LINT ?= verible-verilog-lint
PYTHON ?= python3
FLOAT_SEED ?= 0x9e3779b97f4a7c15

FLOAT_CORE = zubax:kulibin:float
FLOAT_PYTHONPATH = $(CURDIR)/float/tb$(if $(PYTHONPATH),:$(PYTHONPATH))
# Matrix parallelism: the per-config FuseSoC runs are independent (each builds into its own root and writes its own
# coverage.dat), so pytest-xdist fans them across cores. FLOAT_JOBS=auto uses every core; set FLOAT_JOBS=1 to serialize.
# xdist is loaded explicitly with -p; if not installed the run silently falls back to serial.
FLOAT_JOBS ?= auto
# Set to 1 in disk-constrained CI to remove successful per-config build roots after preserving coverage data.
FLOAT_PRUNE_BUILDS ?= 0
ifeq ($(filter 0 1,$(FLOAT_JOBS)),)
  FLOAT_XDIST := $(shell $(PYTHON) -c "import xdist" >/dev/null 2>&1 && echo "-p xdist -n $(FLOAT_JOBS)")
else
  FLOAT_XDIST :=
endif

# Hermetic pytest invocation for the float matrix (float/tb/test_float_matrix.py drives FuseSoC).
# Invoked as `$(PYTHON) -m pytest` so it uses the same interpreter as the rest of the suite (robust
# against PATH / missing console-script in the CI image). No plugin autoload / external addopts - the
# orchestrator needs only core pytest. -x stops on the first failing config (fail-fast, matching the
# rest of `verify`); append -m to pick a tier (see float/pytest.ini).
FLOAT_PYTEST = PYTHONPATH="$(FLOAT_PYTHONPATH)" PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 PYTEST_ADDOPTS= \
	FUSESOC="$(FUSESOC)" PYTHON="$(PYTHON)" FLOAT_SEED="$(FLOAT_SEED)" \
	FLOAT_PRUNE_BUILDS="$(FLOAT_PRUNE_BUILDS)" \
	$(PYTHON) -m pytest -c float/pytest.ini float/tb/test_float_matrix.py -x -v $(FLOAT_XDIST)

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

.PHONY: \
	verify verify-deep verify-float verify-float-fast verify-float-deep verify-float-extended \
	verify-float-extended-icarus verify-float-extended-verilator \
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
	@$(FLOAT_PYTEST) -m "pr and icarus"

verify-float-verilator: library
	@rm -rf build/float/verilator
	@$(FLOAT_PYTEST) -m "pr and verilator"

coverage-float-report:
	$(PYTHON) float/tb/zkf_coverage.py --build-dir build/float/verilator --output-dir build/float/coverage

coverage-float-gate:
	$(PYTHON) float/tb/zkf_coverage.py --build-dir build/float/verilator --output-dir build/float/coverage --gate

## Deep-tier-only extended sweep: fills the parity/relation/WINT parameter gaps (correctness, Icarus) and
## drives a curated set of exhaustive small-format Verilator runs into build/float/verilator-toggle for
## line+branch coverage closure (toggle reported advisory). Per-PR verify/verify-float never invoke this.
verify-float-extended: library
	@rm -rf build/float/icarus-ext build/float/verilator-toggle
	@$(FLOAT_PYTEST) -m deep

verify-float-extended-icarus: library
	@rm -rf build/float/icarus-ext
	@$(FLOAT_PYTEST) -m "deep and icarus"

verify-float-extended-verilator: library
	@rm -rf build/float/verilator-toggle
	@$(FLOAT_PYTEST) -m "deep and verilator"

## Deep coverage gate over the exhaustive coverage set: every LINE and BRANCH must be covered (mandatory).
## TOGGLE coverage is ADVISORY -- reported for RTL development but never fatal. The few genuinely-unreachable
## line/branch points are suppressed in the RTL with `// verilator coverage_off`/`coverage_on` (no external
## waiver list). Deep-tier only.
coverage-float-gate-full:
	$(PYTHON) float/tb/zkf_coverage.py --build-dir build/float/verilator-toggle \
		--output-dir build/float/coverage-full --full

## Independent transcendental/trig accuracy gate: sweeps the fixed-point references (exp2/log2/sincos/atan2) against the
## mpmath *_true oracle and asserts the <= 1 ULP faithful-rounding contract. The per-PR cocotb suite only checks
## RTL == reference (a shared oracle), so a shared algorithmic regression would pass it silently; this is the only
## target that closes that gap. Heavy (exhaustive small formats + 1M random samples at high precision) -> deep tier
## only. Override ZKF_CHECK_SAMPLES to scale the random portion.
verify-float-accuracy:
	@PYTHONPATH="$(FLOAT_PYTHONPATH)" $(PYTHON) float/zkf_transcendental.py --check
	@PYTHONPATH="$(FLOAT_PYTHONPATH)" $(PYTHON) float/zkf_trig.py --check

## Minimal smoke suite intended for interactive use between edits. Runs in well under a minute on a workstation.
## Compiles every public module under Icarus at its smallest exhaustive configuration; modules with a pipeline knob
## also run the same configuration with their knob set (STAGE_PRODUCT=1 for mul, STAGE_INPUT=1 for div/cast/resize)
## to catch breakage of the optional split. Skips Verilator, coverage gating, algebraic-property tests, formal proofs,
## all random sweeps, and the wide-WMAN configs.
## Use verify-float (medium) or verify-float-deep (full) for anything past quick regression checks.
verify-float-fast: library
	@$(MAKE) verify-float-model
	@$(FLOAT_PYTEST) -m fast

verify-float-deep: library
	@$(MAKE) verify-float
	@$(MAKE) verify-float-extended
	@$(MAKE) coverage-float-gate-full
	@$(MAKE) verify-float-properties
	@$(MAKE) verify-float-accuracy
	@$(MAKE) formal-float

## Maximum verification: every module simulation, every float algebraic property, the transcendental/trig accuracy
## contract, and every formal proof. Mirrors the deep CI (verify-deep.yml), which runs these as parallel jobs on the
## main branch and on commits whose message contains "#ci-float" (there the accuracy gate is the float-accuracy job).
verify-deep: library
	@$(MAKE) verify
	@$(MAKE) verify-float-extended
	@$(MAKE) coverage-float-gate-full
	@$(MAKE) verify-float-properties
	@$(MAKE) verify-float-accuracy
	@$(MAKE) formal-float
	@echo "Maximum-verification suite (project + float-properties + float-accuracy + float-formal) passed."

verify-float-properties: library
	@$(FLOAT_PYTEST) -m properties

# FORMAL_JOBS controls sby proof parallelism (0 = all cores); each proof runs in its own build subdir.
FORMAL_JOBS ?= 0
formal-float: library
	@$(PYTHON) float/proof/run_proofs.py \
	    --sby-dir float/proof/sby \
	    --build-dir build/float/formal \
	    --report build/float/formal/report.html \
	    --jobs $(FORMAL_JOBS)

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

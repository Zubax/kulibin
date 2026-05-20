#!/usr/bin/env bash
# Deep-tier-only extended float verification (invoked by `make verify-float-extended`).
#
# Two purposes, kept separate:
#   1. CORRECTNESS breadth on Icarus - fills the (even WEXP, odd WMAN) parity gap, the missing
#      (odd, even) cases, odd WINT casts, and resize parity/relation combinations that the per-PR
#      matrices skip. Every entry runs DUT-vs-model with the standard stage-knob sweeps.
#   2. COVERAGE closure on Verilator - a curated set of EXHAUSTIVE small-format runs (spanning all
#      four (WEXP,WMAN) parity classes and every parameter-relationship class so all generate
#      branches elaborate) written into build/float/verilator-toggle. Because an exhaustive run
#      visits every reachable input, it visits every reachable internal state, so 100% line + branch
#      + toggle there is both achievable and a strong proof; any structurally-unreachable residue is
#      suppressed in the RTL with `// verilator coverage_off`/`coverage_on` (no external waiver file).
#
# Per-PR `make verify` / `verify-float` do NOT call this; the heavy sweep is deep-tier only.
set -eu
MODE="${1:-all}"   # all | correctness | coverage
cd "$(dirname "$0")/../.."
FUSESOC="${FUSESOC:-fusesoc}"
PYTHON="${PYTHON:-python3}"
FLOAT_SEED="${FLOAT_SEED:-0x9e3779b97f4a7c15}"
FLOAT_CORE="zubax:kulibin:float"
export PYTHONPATH="$PWD/float/tb${PYTHONPATH:+:$PYTHONPATH}"
export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1
export COCOTB_REWRITE_ASSERTION_FILES=
TOGGLE_DIR="build/float/verilator-toggle"

# ---- helpers: all take the sim flavour (icarus|verilator) as $1 so one definition serves both -----
emit() { echo "=== ${FLOAT_CORE} :: $1 :: $2 ==="; }
finish() { "$PYTHON" float/tb/zkf_results.py "$1"; }

cov_root() {  # echo the build root for sim=$1 op=$2 cfg=$3 (verilator coverage -> TOGGLE_DIR)
  if [ "$1" = verilator ]; then echo "$TOGGLE_DIR/$2/$3"; else echo "build/float/$1-ext/$2/$3"; fi; }

run_pack() {
  local sim=$1 cfg=$2 w=$3 m=$4 u=$5 kind=$6 cnt=$7
  local root; root=$(cov_root "$sim" pack "$cfg"); emit "sim_pack_$sim" "$cfg"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_pack_$sim $FLOAT_CORE --WEXP $w --WMAN $m --WEXP_UNBIASED $u \
    --ZKF_WEXP $w --ZKF_WMAN $m --ZKF_WEXP_UNBIASED $u --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$cfg"; finish "$root"; }

run_bin() {
  local sim=$1 op=$2 cfg=$3 w=$4 m=$5 kind=$6 cnt=$7
  local root; root=$(cov_root "$sim" "$op" "$cfg"); emit "sim_${op}_$sim" "$cfg"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_${op}_$sim $FLOAT_CORE --WEXP $w --WMAN $m \
    --ZKF_WEXP $w --ZKF_WMAN $m --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$cfg"; finish "$root"; }

run_bin_sad() {
  local sim=$1 op=$2 cfg=$3 w=$4 m=$5 kind=$6 cnt=$7 sd=$8 sa=$9
  local c="${cfg}_sd${sd}_sa${sa}" root; root=$(cov_root "$sim" "$op" "$c"); emit "sim_${op}_$sim" "$c"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_${op}_$sim $FLOAT_CORE --WEXP $w --WMAN $m --STAGE_DECODE $sd --STAGE_ALIGN $sa \
    --ZKF_WEXP $w --ZKF_WMAN $m --ZKF_STAGE_DECODE $sd --ZKF_STAGE_ALIGN $sa --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$c"; finish "$root"; }

run_bin_sp() {
  local sim=$1 op=$2 cfg=$3 w=$4 m=$5 kind=$6 cnt=$7 sp=$8
  local c="${cfg}_sp${sp}" root; root=$(cov_root "$sim" "$op" "$c"); emit "sim_${op}_$sim" "$c"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_${op}_$sim $FLOAT_CORE --WEXP $w --WMAN $m --STAGE_PRODUCT $sp \
    --ZKF_WEXP $w --ZKF_WMAN $m --ZKF_STAGE_PRODUCT $sp --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$c"; finish "$root"; }

run_bin_si() {
  local sim=$1 op=$2 cfg=$3 w=$4 m=$5 kind=$6 cnt=$7 si=$8
  local c="${cfg}_si${si}" root; root=$(cov_root "$sim" "$op" "$c"); emit "sim_${op}_$sim" "$c"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_${op}_$sim $FLOAT_CORE --WEXP $w --WMAN $m --STAGE_INPUT $si \
    --ZKF_WEXP $w --ZKF_WMAN $m --ZKF_STAGE_INPUT $si --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$c"; finish "$root"; }

run_unary() {
  local sim=$1 op=$2 cfg=$3 w=$4 m=$5 kind=$6 cnt=$7
  local root; root=$(cov_root "$sim" "$op" "$cfg"); emit "sim_${op}_$sim" "$cfg"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_${op}_$sim $FLOAT_CORE --WEXP $w --WMAN $m \
    --ZKF_WEXP $w --ZKF_WMAN $m --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$cfg"; finish "$root"; }

run_unary_sd() {
  local sim=$1 op=$2 cfg=$3 w=$4 m=$5 kind=$6 cnt=$7 sd=$8
  local c="${cfg}_sd${sd}" root; root=$(cov_root "$sim" "$op" "$c"); emit "sim_${op}_$sim" "$c"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_${op}_$sim $FLOAT_CORE --WEXP $w --WMAN $m --STAGE_DECODE $sd \
    --ZKF_WEXP $w --ZKF_WMAN $m --ZKF_STAGE_DECODE $sd --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$c"; finish "$root"; }

run_cast() {
  local sim=$1 op=$2 cfg=$3 w=$4 m=$5 i=$6 kind=$7 cnt=$8 si=$9
  local c="${cfg}_si${si}" root; root=$(cov_root "$sim" "$op" "$c"); emit "sim_${op}_$sim" "$c"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_${op}_$sim $FLOAT_CORE --WEXP $w --WMAN $m --WINT $i --STAGE_INPUT $si \
    --ZKF_WEXP $w --ZKF_WMAN $m --ZKF_WINT $i --ZKF_STAGE_INPUT $si --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$c"; finish "$root"; }

run_resize() {
  local sim=$1 cfg=$2 wi=$3 mi=$4 wo=$5 mo=$6 kind=$7 cnt=$8 si=$9
  local c="${cfg}_si${si}" root; root=$(cov_root "$sim" resize "$c"); emit "sim_resize_$sim" "$c"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_resize_$sim $FLOAT_CORE --WEXP_IN $wi --WMAN_IN $mi --WEXP_OUT $wo --WMAN_OUT $mo --STAGE_INPUT $si \
    --ZKF_WEXP_IN $wi --ZKF_WMAN_IN $mi --ZKF_WEXP_OUT $wo --ZKF_WMAN_OUT $mo --ZKF_STAGE_INPUT $si --ZKF_KIND $kind --ZKF_COUNT $cnt --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$c"; finish "$root"; }

# format lists: "wexp:wman:kind:count"  (parity classes: ee/eo/oe/oo across wfull 6..10, plus wide odd/even mixes)
BIN_EXT="2:5:exhaustive:0 4:5:exhaustive:0 2:7:exhaustive:0 3:6:exhaustive:0 5:4:exhaustive:0 4:6:exhaustive:0 3:7:random:512 6:17:random:768 8:23:random:768 7:12:random:512 9:24:random:512 6:19:random:512"
DIV_EXT="2:5:exhaustive:0 4:5:exhaustive:0 3:6:exhaustive:0 5:4:exhaustive:0 6:17:random:512 8:23:random:512 7:12:random:512"
UNARY_EXT="2:5:exhaustive:0 4:5:exhaustive:0 3:6:exhaustive:0 6:17:random:512 8:23:random:512"

# ---------------------------------------------------------------------------------------------------
# 1. CORRECTNESS breadth on Icarus.
# ---------------------------------------------------------------------------------------------------
if [ "$MODE" != coverage ]; then
echo "########## EXTENDED CORRECTNESS (icarus) ##########"
for spec in $BIN_EXT; do IFS=: read -r w m k c <<<"$spec"
  run_bin_sp icarus mul "w${w}m${m}_${k}" $w $m $k $c 0
  run_bin_sp icarus mul "w${w}m${m}_${k}" $w $m $k $c 1
  for sd in 0 1; do for sa in 0 1; do
    run_bin_sad icarus add    "w${w}m${m}_${k}" $w $m $k $c $sd $sa
    run_bin_sad icarus addsub "w${w}m${m}_${k}" $w $m $k $c $sd $sa
  done; done
  run_bin icarus cmp  "w${w}m${m}_${k}" $w $m $k $c
  run_bin icarus sort "w${w}m${m}_${k}" $w $m $k $c
done
for spec in $DIV_EXT; do IFS=: read -r w m k c <<<"$spec"
  run_bin_si icarus div "w${w}m${m}_${k}" $w $m $k $c 0
  run_bin_si icarus div "w${w}m${m}_${k}" $w $m $k $c 1
done
for spec in $UNARY_EXT; do IFS=: read -r w m k c <<<"$spec"
  for op in abs neg is_finite saturate; do run_unary icarus $op "w${w}m${m}_${k}" $w $m $k $c; done
  run_unary_sd icarus mul_ilog2_const "w${w}m${m}_${k}" $w $m $k $c 0
  run_unary_sd icarus mul_ilog2_const "w${w}m${m}_${k}" $w $m $k $c 1
done
# pack: parity + WEXP_UNBIASED min/typ/wide   "wexp:wman:wunb:kind:count"
for spec in 2:5:3:exhaustive:0 2:5:5:exhaustive:0 3:5:5:exhaustive:0 4:5:6:random:768 6:17:8:random:1024 4:4:8:random:512; do
  IFS=: read -r w m u k c <<<"$spec"; run_pack icarus "w${w}m${m}u${u}_${k}" $w $m $u $k $c; done
# casts: odd WINT + WINT<,=,> WMAN   "wexp:wman:wint:kind:count"
for spec in 3:5:5:exhaustive:0 2:5:3:exhaustive:0 4:5:7:exhaustive:0 4:6:5:exhaustive:0 5:11:9:random:512 6:17:33:random:512 8:24:17:random:512; do
  IFS=: read -r w m i k c <<<"$spec"
  for si in 0 1; do run_cast icarus to_int   "w${w}m${m}i${i}_${k}" $w $m $i $k $c $si; done
  for si in 0 1; do run_cast icarus from_int "w${w}m${m}i${i}_${k}" $w $m $i $k $c $si; done
done
# resize: quadrants + parity in/out   "wei:wmi:weo:wmo:kind:count"
for spec in 4:5:4:4:exhaustive:0 4:4:4:5:exhaustive:0 2:5:4:7:exhaustive:0 4:7:2:5:exhaustive:0 5:5:3:4:exhaustive:0 3:4:5:5:exhaustive:0 6:17:4:11:random:512 5:11:6:17:random:512; do
  IFS=: read -r wi mi wo mo k c <<<"$spec"
  for si in 0 1; do run_resize icarus "w${wi}m${mi}_to_w${wo}m${mo}_${k}" $wi $mi $wo $mo $k $c $si; done
done

# ---------------------------------------------------------------------------------------------------
# 2. COVERAGE closure on Verilator (exhaustive small formats -> build/float/verilator-toggle).
#    Formats per module are chosen so (a) all four parity classes appear, (b) every generate branch
#    elaborates, and (c) the exponent range is wide enough to reach zero / min_normal / inf / normal
#    outputs (so the result-class toggles in _zkf_pack fire). Knob=1 variants cover the split stages.
# ---------------------------------------------------------------------------------------------------
fi  # end correctness

if [ "$MODE" != correctness ]; then
echo "########## COVERAGE CLOSURE (verilator, exhaustive) ##########"
rm -rf "$TOGGLE_DIR"
# binary cores: all four parity classes at wfull<=9 (exhaustive => every reachable state visited; toggle merges
# by net across the set). w5m4 (bias 15) gives wide exponent range so products reach inf/min_normal/zero.
for f in 4:5 3:6 5:4 3:5 2:6; do w=${f%:*}; m=${f#*:}
  run_bin_sp verilator mul "w${w}m${m}" $w $m exhaustive 0 0
  run_bin_sp verilator mul "w${w}m${m}" $w $m exhaustive 0 1
  run_bin_sad verilator add    "w${w}m${m}" $w $m exhaustive 0 0 0
  run_bin_sad verilator add    "w${w}m${m}" $w $m exhaustive 0 1 1
  run_bin_sad verilator addsub "w${w}m${m}" $w $m exhaustive 0 1 1
  run_bin verilator cmp  "w${w}m${m}" $w $m exhaustive 0
  run_bin verilator sort "w${w}m${m}" $w $m exhaustive 0
done
for f in 4:5 3:6 3:5 2:6; do w=${f%:*}; m=${f#*:}
  run_bin_si verilator div "w${w}m${m}" $w $m exhaustive 0 0
  run_bin_si verilator div "w${w}m${m}" $w $m exhaustive 0 1
done
for f in 4:5 3:6 2:6; do w=${f%:*}; m=${f#*:}
  for op in abs neg is_finite saturate; do run_unary verilator $op "w${w}m${m}" $w $m exhaustive 0; done
  run_unary_sd verilator mul_ilog2_const "w${w}m${m}" $w $m exhaustive 0 0
  run_unary_sd verilator mul_ilog2_const "w${w}m${m}" $w $m exhaustive 0 1
done
# pipe: the shared N-stage delay. Standalone runs with N>=2 exercise the multi-stage shift loop that
# embedded STAGE_INPUT=1 (N=1) instances leave degenerate. (run_pipe is defined inline here.)
run_pipe_cov() { local cfg=$1 w=$2 n=$3; local root="$TOGGLE_DIR/pipe/$cfg"; emit "sim_pipe_verilator" "$cfg"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_pipe_verilator $FLOAT_CORE --W $w --N $n \
    --ZKF_PIPE_W $w --ZKF_PIPE_N $n --ZKF_COUNT 96 --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$cfg"; finish "$root"; }
run_pipe_cov w8_n2 8 2; run_pipe_cov w8_n4 8 4; run_pipe_cov w24_n3 24 3
# lod / rshift: shared helpers that previously had no standalone bench. Small exhaustive covers the I/O
# toggles; the internal tree / cascade is structural (suppressed in-source). Wider directed runs add
# correctness at the widths the callers actually instantiate, and W=16 rshift exercises the over-range
# saturation path (WSHIFT > WPAIR).
run_lod_cov() { local cfg=$1 w=$2 k=$3; local root="$TOGGLE_DIR/lod/$cfg"; emit sim_lod_verilator "$cfg"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_lod_verilator $FLOAT_CORE --W $w --ZKF_LOD_W $w \
    --ZKF_KIND $k --ZKF_COUNT 0 --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$cfg"; finish "$root"; }
run_rsh_cov() { local cfg=$1 w=$2 s=$3 k=$4; local root="$TOGGLE_DIR/rshift/$cfg"; emit sim_rshift_verilator "$cfg"; rm -rf "$root"
  $FUSESOC run --build-root="$root" --target=sim_rshift_verilator $FLOAT_CORE --W $w --STAGE_SPLIT $s --ZKF_RSH_W $w \
    --ZKF_RSH_SPLIT $s --ZKF_KIND $k --ZKF_COUNT 0 --ZKF_SEED "$FLOAT_SEED" --ZKF_CONFIG "$cfg"; finish "$root"; }
run_lod_cov w8 8 exhaustive; run_lod_cov w9 9 exhaustive; run_lod_cov w32 32 directed
run_rsh_cov w8s0 8 0 exhaustive; run_rsh_cov w8s1 8 1 exhaustive; run_rsh_cov w16s0 16 0 directed; run_rsh_cov w16s1 16 1 directed
# pack: cover g_biased_overflow_wide and all result classes; small WMAN, varied WEXP_UNBIASED.
for spec in 4:5:6 4:5:7 3:6:5 4:4:6; do IFS=: read -r w m u <<<"$spec"; run_pack verilator "w${w}m${m}u${u}" $w $m $u exhaustive 0; done
# casts: span WINT < = > WMAN so g_lshift/g_lover/g_rover branches all elaborate; both STAGE_INPUT polarities.
for spec in 4:5:7 4:6:5 3:6:4 5:4:8; do IFS=: read -r w m i <<<"$spec"
  for si in 0 1; do run_cast verilator to_int   "w${w}m${m}i${i}" $w $m $i exhaustive 0 $si; done
  for si in 0 1; do run_cast verilator from_int "w${w}m${m}i${i}" $w $m $i exhaustive 0 $si; done
done
# resize: widen (fast path) and narrow (slow path), WEXP-only / WMAN-only / both; both STAGE_INPUT.
for spec in 3:4:5:6 5:6:3:4 4:5:4:4 4:4:4:5 5:4:3:6 3:6:5:4; do IFS=: read -r wi mi wo mo <<<"$spec"
  for si in 0 1; do run_resize verilator "w${wi}m${mi}_to_w${wo}m${mo}" $wi $mi $wo $mo exhaustive 0 $si; done
done
fi  # end coverage

echo "########## EXTENDED RUN COMPLETE (mode=$MODE) ##########"

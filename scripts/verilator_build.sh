#!/bin/bash
# usage: build.sh <objdir> <top> <extra verilator args...>
set -e
O=$1; T=$2; shift 2
S=$HOME/mnt/NOC_PQATTEST/NOC_PQATTEST.srcs/sources_1/new
F="NOC_PKG.sv NOC_FIFO.sv NOC_CROSSBAR.sv NOC_DATAPTAH.sv NOC_XY_ROUTING.sv NOC_arbiter.sv allocator.sv noc_credit_counter.sv noc_router.sv noc_mesh_3x2.sv"
cd $HOME/vb; rm -rf $O
$HOME/.local/bin/verilator-cli --cc --exe --main --timing -Wno-fatal -Wno-lint -Wno-style --assert --top-module $T -Mdir $O "$@" $(for f in $F; do echo $S/$f; done) $EXTRA_FILES > $O.vlog 2>&1
cd $O && make -f V$T.mk -j4 OPT_FAST=-O1 CFG_CXXFLAGS_PCH_I=-include USER_CPPFLAGS="-fcoroutines -std=c++20" > ../$O.mlog 2>&1
echo BUILD_OK $O

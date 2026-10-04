#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Unit checks that need no ROMs. Run in msys2 UCRT64 (see sim/build.sh).
set -e
cd "$(dirname "$0")/.."
verilator --binary -Wno-fatal -Wno-lint -CFLAGS "-O2 -std=c++17" -Mdir sim/obj_orient --top-module orientation_tb \
    sim/orientation_tb.sv rtl/taitob_orientation.sv > /dev/null
sim/obj_orient/Vorientation_tb

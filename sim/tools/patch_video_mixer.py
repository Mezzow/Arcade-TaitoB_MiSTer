#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Sim-only copy of sys/video_mixer.sv for Verilator. The framework declares R_in/G_in/B_in
# inside the branches of a generate-if and uses them after it; Quartus accepts that, but
# Verilator scopes them to the branch and turns the later uses into implicit 1-bit nets
# (a black picture). This copy keeps only the HALF_DEPTH=0 branch, at module scope - the
# configuration rtl/video_path.sv instantiates. Nothing else changes.
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
m = re.search(r"generate\s+if\s*\(GAMMA && HALF_DEPTH\)\s*begin.*?end\s+else\s+begin(.*?)end\s+endgenerate", s, re.S)
assert m, "video_mixer.sv layout changed"
s = s[:m.start()] + m.group(1).strip() + "\n" + s[m.end():]
open(dst, "w").write(s)

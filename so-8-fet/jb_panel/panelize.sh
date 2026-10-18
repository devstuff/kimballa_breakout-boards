#!/bin/bash
#
# Panelize the SO-8 FET breakout with V-cuts and generate JLCPCB Gerbers.
#
# Usage: ./panelize.sh
#
# Settings live in so-8-fet-vcut-panel.json (also loadable in the KiKit GUI).
# Outputs:
#   out/so-8-fet-panel.kicad_pcb  - panelized board
#   out/drc.json                  - KiCad DRC report for the panel
#   rtm/                          - Gerbers + drill files and gerbers.zip for upload
#
# V-cut lines go on Edge.Cuts (JLC's convention), so KiCad DRC always reports
# them as `invalid_outline`. We run DRC ourselves and fail on anything else.

set -euo pipefail;

readonly KIKIT="/usr/local/bin/kikit";
readonly KICAD_CLI="/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli";
readonly PY="/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3";

main() {
  local here;
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
  local src="${here}/../so-8-fet.kicad_pcb";
  local cfg="${here}/so-8-fet-vcut-panel.json";
  local panel="${here}/out/so-8-fet-panel.kicad_pcb";
  local drc="${here}/out/drc.json";
  local rtm="${here}/rtm";

  mkdir -p "${here}/out";
  rm -rf "${rtm}";

  echo "Panelizing ${src}";
  "${KIKIT}" panelize -p "${cfg}" "${src}" "${panel}";

  # KiKit always labels each V-cut with text on the cut layer. On Edge.Cuts that
  # text lands outside the panel and inflates the outline JLC measures, so strip
  # it. Then confirm the panel still fits JLC's 100x100mm price tier.
  "${PY}" - "${panel}" <<'EOF'
import sys, pcbnew
b = pcbnew.LoadBoard(sys.argv[1])
labels = [d for d in b.GetDrawings()
          if d.GetLayer() == pcbnew.Edge_Cuts and isinstance(d, pcbnew.PCB_TEXT)]
for d in labels:
    b.Remove(d)
pcbnew.SaveBoard(sys.argv[1], b)
b = pcbnew.LoadBoard(sys.argv[1])
left = sum(1 for d in b.GetDrawings()
           if d.GetLayer() == pcbnew.Edge_Cuts and isinstance(d, pcbnew.PCB_TEXT))
print(f"Removed {len(labels)} V-CUT labels from Edge.Cuts ({left} remain)")
if left:
    sys.exit("ERROR: text still on Edge.Cuts")
e = b.GetBoardEdgesBoundingBox()
w, h = e.GetWidth() / 1e6, e.GetHeight() / 1e6
print(f"Panel outline: {w:.2f} x {h:.2f} mm")
if w > 100 or h > 100:
    sys.exit("ERROR: panel exceeds 100x100mm")
EOF

  echo "Refilling zones and running DRC";
  "${KICAD_CLI}" pcb drc --refill-zones --save-board --severity-error --format json -o "${drc}" "${panel}" > /dev/null;
  "${PY}" - "${drc}" <<'EOF'
import sys, json
from collections import Counter
r = json.load(open(sys.argv[1]))
v = Counter(x["type"] for x in r["violations"] + r.get("unconnected_items", []))
print("DRC errors by type:", dict(v) or "none")
unexpected = {k: n for k, n in v.items() if k != "invalid_outline"}
if unexpected:
    sys.exit(f"ERROR: unexpected DRC errors: {unexpected}")
EOF

  echo "Generating Gerbers in ${rtm}";
  "${KIKIT}" fab jlcpcb --no-drc --no-assembly "${panel}" "${rtm}";
  ls -l "${rtm}";
}

main "$@";

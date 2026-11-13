#!/usr/bin/env bash
# Install gpuq for the current user: copies bin/ and lib/ to ~/.local/share/gpuq ($GPUQ_SHARE) and
# links gpuq and qtop into ~/.local/bin ($GPUQ_BIN_DIR). Nothing system-wide, no root.
#
#   ./install.sh               install (or update)
#   ./install.sh --force       also replace a gpuq/qtop in ~/.local/bin that this script didn't install
#                              (the old one is kept as <name>.bak-<date>)
#   ./install.sh --uninstall   remove the links and ~/.local/share/gpuq (your queue state in ~/.gpuq stays)
set -euo pipefail
cd "$(dirname "$0")"
SHARE="${GPUQ_SHARE:-$HOME/.local/share/gpuq}"
BIN="${GPUQ_BIN_DIR:-$HOME/.local/bin}"
force=0

case "${1:-}" in
  --force) force=1 ;;
  --uninstall)
    for n in gpuq qtop; do
      [ -L "$BIN/$n" ] && [ "$(readlink "$BIN/$n")" = "$SHARE/bin/$n" ] && rm "$BIN/$n" && echo "removed $BIN/$n"
    done
    if [ -d "$SHARE" ]; then rm -rf "$SHARE" && echo "removed $SHARE (queue state in ${GPUQ_DIR:-~/.gpuq} is untouched)"
    else echo "nothing installed in $SHARE"; fi
    exit 0 ;;
  "") ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

# Requirements: bash 4+, flock (util-linux), python3 (for qtop), nvidia-smi (for real use).
missing=()
for c in flock python3; do command -v "$c" >/dev/null || missing+=("$c"); done
[ ${#missing[@]} -eq 0 ] || { echo "gpuq needs: ${missing[*]}" >&2; exit 1; }
command -v nvidia-smi >/dev/null || echo "note: nvidia-smi isn't on PATH here; gpuq needs it to see the cards."

mkdir -p "$SHARE" "$BIN"
rm -rf "$SHARE/bin" "$SHARE/lib"
cp -R bin lib "$SHARE/"
chmod +x "$SHARE/bin/gpuq" "$SHARE/bin/qtop"

for n in gpuq qtop; do
  target="$SHARE/bin/$n"
  if [ -e "$BIN/$n" ] || [ -L "$BIN/$n" ]; then
    if [ -L "$BIN/$n" ] && [ "$(readlink "$BIN/$n")" = "$target" ]; then continue; fi
    if [ "$force" = 1 ]; then
      backup="$BIN/$n.bak-$(date +%Y%m%d-%H%M%S)"
      mv "$BIN/$n" "$backup" && echo "kept the old $n as $backup"
    else
      echo "$BIN/$n already exists and isn't from this installer; left it alone (use --force to replace it)" >&2
      continue
    fi
  fi
  ln -s "$target" "$BIN/$n" && echo "linked $BIN/$n"
done

case ":$PATH:" in *":$BIN:"*) ;; *) echo "add $BIN to your PATH, e.g.: echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.bashrc" ;; esac
echo "done. Try: gpuq status"

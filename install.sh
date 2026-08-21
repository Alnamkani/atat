#!/bin/bash
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
INIT_FILE="$HS_DIR/init.lua"

mkdir -p "$HS_DIR"

if [ ! -f "$INIT_FILE" ]; then
  touch "$INIT_FILE"
fi

LINK_TARGET="$HS_DIR/atat.lua"
if [ -L "$LINK_TARGET" ] || [ -e "$LINK_TARGET" ]; then
  if [ "$(readlink "$LINK_TARGET" 2>/dev/null)" = "$SRC/atat.lua" ]; then
    echo "atat.lua already linked"
  else
    echo "error: $LINK_TARGET already exists and is not managed by this installer" >&2
    exit 1
  fi
else
  ln -s "$SRC/atat.lua" "$LINK_TARGET"
  echo "linked $LINK_TARGET -> $SRC/atat.lua"
fi

if grep -q 'require("atat")' "$INIT_FILE" || grep -q "require('atat')" "$INIT_FILE"; then
  echo "require line already present in init.lua"
else
  printf '\nrequire("atat")\n' >> "$INIT_FILE"
  echo "added require(\"atat\") to $INIT_FILE"
fi

echo
echo "done. reload hammerspoon: menu bar icon -> Reload Config"

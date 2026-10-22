#!/usr/bin/env sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bin=${XDG_BIN_HOME:-"$HOME/.local/bin"}
mkdir -p "$bin"
for name in gitdark gitdarkive; do
  target="$bin/$name"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ "$(readlink "$target" 2>/dev/null || true)" = "$root/$name" ]; then continue; fi
    printf 'Refusing to replace %s\n' "$target" >&2
    exit 1
  fi
  ln -s "$root/$name" "$target"
done
printf 'Linked gitdark and gitdarkive in %s\nKeep this checkout in place. Add that directory to PATH if necessary.\n' "$bin"

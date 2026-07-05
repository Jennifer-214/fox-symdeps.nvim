#!/usr/bin/env bash
# Generate compile_commands.json for the sandbox fixture, portably (paths from THIS dir, not
# hardcoded). The plugin's compile-dependent features (sizeprobe / asmexplorer / branchtag) read
# compile_commands to get the file's flags; the fixture needs one to be analyzable. It's
# machine-specific (absolute paths) so it's gitignored — run this once after checkout.
#   bash tests/fixtures/sandbox/gen-cc.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
cat > "$here/compile_commands.json" <<EOF
[
  {
    "directory": "$here",
    "command": "clang++ -std=c++17 -I. -c sandbox.cpp",
    "file": "$here/sandbox.cpp"
  }
]
EOF
echo "wrote $here/compile_commands.json"

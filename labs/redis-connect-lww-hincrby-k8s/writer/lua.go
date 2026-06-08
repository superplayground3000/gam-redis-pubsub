package main

import _ "embed"

// hmaxScript is the source of hmax.lua (kept identical to
// chart/files/connect/hmax.lua; scripts/build-binaries.sh re-syncs it). go:embed
// requires the file inside the module dir, so a copy is vendored here.
//
//go:embed hmax.lua
var hmaxScript string

#!/bin/bash
set -e -u -o pipefail

export RUST_BACKTRACE=1
export CARGO_INCREMENTAL=0
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

cargo build --bin lalrpop --features pico-args

EXCLUDE_FILES=${1:-""}

if [ -n "${EXCLUDE_FILES}" ]; then
	cargo test --workspace --exclude "$EXCLUDE_FILES"
else
	cargo test --workspace
fi

# Check the documentation examples separately so that the `lexer` feature specified in tests do not
# leak into them
cargo check -p calculator
cargo check -p pascal
cargo check -p whitespace

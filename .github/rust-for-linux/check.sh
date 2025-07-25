#!/bin/bash

# modified from https://github.com/rust-lang/rust/blob/bc4376fa73b636eb6f2c7d48b1f731d70f022c4b/src/ci/docker/scripts/rfl-build.sh

set -exou pipefail

export SAFETY_TOOL_LOG=info
export SAFETY_TOOL_LOG_FILE=$PWD/tag-std.log

export DATA_SQLITE3=$PWD/linux/rust_safety.sqlite3
KCONFIG=$PWD/linux/kernel/configs/rfl-for-rust-ci.config

# Logger file will be only appended, meaning all logs are
# preserved during building in this script.
# And we'd better remove it and create a new one for new logs.
rm -rf $SAFETY_TOOL_LOG_FILE
touch $SAFETY_TOOL_LOG_FILE

# Rust toolchain
RUST_TOOLCHAIN=1.87

rustup default $RUST_TOOLCHAIN

# Set up dynamic link path for rustc driver.
export LD_LIBRARY_PATH=$(rustc --print sysroot)/lib

pushd safety-tool
# Must enter safety-tool folder to respect rust toolchain to compile code.
cargo install --path . --locked
# This should print `rustc 1.87.0 (17067e9ac 2025-05-09)`.
safety-tool --version
# generate bin and lib in target/safety-tool
safety-tool-rfl build-dev

# Copy safety-lib's safety.rs file to linux/rust
{
  printf '#![no_std]\n'
  cat safety-lib/src/safety.rs
} >../linux/rust/safety.rs
popd

# Add llvm to PATH, and set up libclang
llvm=llvm-20.1.7-rust-1.87.0-$(uname -m)
llvm_prefix=$PWD/$llvm
export PATH=$llvm_prefix/bin:$PATH
export LIBCLANG_PATH=$llvm_prefix/lib/libclang.so

# Install bindgen-cli which must be built from the same version of
# libclang and rustc required above.
cargo --version
cargo install --locked --root $llvm_prefix bindgen-cli

# Prepare Rust for Linux config
cat <<EOF >$KCONFIG
# CONFIG_WERROR is not set

CONFIG_RUST=y

CONFIG_SAMPLES=y
CONFIG_SAMPLES_RUST=y

CONFIG_SAMPLE_RUST_MINIMAL=y
CONFIG_SAMPLE_RUST_PRINT=y

CONFIG_RUST_PHYLIB_ABSTRACTIONS=y
CONFIG_AX88796B_PHY=y
CONFIG_AX88796B_RUST_PHY=y

CONFIG_KUNIT=y
CONFIG_RUST_KERNEL_DOCTESTS=n
EOF

pushd linux
make clean
rm rust/*.so rust/*.rmeta -f

# Merge linux config
make LLVM=1 -j$(($(nproc) + 1)) \
  rustavailable \
  defconfig \
  rfl-for-rust-ci.config

BUILD_TARGETS="
    samples/rust/rust_minimal.o
    samples/rust/rust_print_main.o
    drivers/net/phy/ax88796b_rust.o
    rustdoc
"

# Compile rust code by our tool to check it!
make LLVM=1 -j$(($(nproc) + 1)) \
  RUSTC=$(which safety-tool-rfl) \
  RUSTDOC=$(which safety-tool-rfl-rustdoc) \
  rustavailable \
  $BUILD_TARGETS

rm -rf $DATA_SQLITE3
rm -rf $KCONFIG

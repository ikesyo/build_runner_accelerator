# Invocation used for the recorded run; paths identify the original workspace.
export DART_BIN=/workspace/build_runner_accelerator/.toolchains/dart/dart-sdk/bin/dart-workspace
export CARGO_BIN=/workspace/build_runner_accelerator/.toolchains/cargo/bin/cargo
export PUB_CACHE=/workspace/build_runner_accelerator/.pub-cache
export RUSTUP_HOME=/workspace/build_runner_accelerator/.toolchains/rustup
export CARGO_HOME=/workspace/build_runner_accelerator/.toolchains/cargo
export PATH=/workspace/build_runner_accelerator/.toolchains/cargo/bin:$PATH
export PUB_OFFLINE=1
export PUB_GET_OFFLINE=1
export CARGO_NET_OFFLINE=true
export BUILD_RUNNER_ACCELERATOR_CACHE=/workspace/build_runner_accelerator/.toolchains/accelerator-cache
# The harness overrides the native cache and worker/metrics settings internally.
# Apply pause-before-timing.patch to the harness to obtain the temporary driver.
python3 /tmp/blocked-assets-benchmark-paused.py \
  --baseline-bin /tmp/blocked-assets-baseline-bin \
  --candidate-bin /tmp/blocked-assets-candidate-bin \
  --results /tmp/blocked-assets-benchmark \
  --profiles single-visibility --repeat 2 --diagnostics
# A newline was supplied on stdin after all other verification processes exited.

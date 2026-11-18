# Sourced by every compiling task. On a Mac with a `build` command installed
# (it admits builds by memory, records them, stops a silent idle one), each
# compile is a step of one run; on GitHub's hosted runners, and anywhere `build`
# is absent, the command runs as it is.
export BUILD_RUN="${BUILD_RUN:-chill-$(uuidgen)}"
build_step() {
  step=$1
  shift
  if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] || ! command -v build >/dev/null; then
    "$@"
  else
    build run --step "$step" -- "$@"
  fi
}

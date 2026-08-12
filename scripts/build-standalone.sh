#!/usr/bin/env bash
set -euo pipefail

version="$(sed -n 's/^[[:space:]]*version: "\([^"]*\)",/\1/p' mix.exs | head -n 1)"
readonly version
readonly all_targets=(linux_x86_64 linux_aarch64 windows_x86_64 macos_x86_64 macos_aarch64)
readonly requested_target="${BURRITO_TARGET:-}"

fail() { printf 'standalone build: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

case "${OSTYPE:-}" in
  linux*|darwin*) ;;
  msys*|cygwin*|win32*) fail "native Windows builds are unsupported; run this script from WSL, Linux, or macOS" ;;
  *) fail "unsupported build host: ${OSTYPE:-unknown}" ;;
esac

for command in elixir erl mix zig xz; do require "${command}"; done

elixir_version="$(elixir --version | sed -n 's/^Elixir //p' | head -n 1)"
otp_version="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)"
zig_version="$(zig version)"
[[ "${elixir_version}" == 1.20.* ]] || fail "Elixir 1.20.x is required, found ${elixir_version:-unknown}"
[[ "${otp_version}" == "29" ]] || fail "Erlang/OTP 29 is required, found ${otp_version:-unknown}"
[[ "${zig_version}" == "0.16.0" ]] || fail "Zig 0.16.0 is required by Burrito 1.6.0, found ${zig_version:-unknown}"
[[ -n "${version}" ]] || fail "could not read the project version from mix.exs"

targets=("${all_targets[@]}")
if [[ -n "${requested_target}" ]]; then
  [[ "${requested_target}" != *,* ]] || fail "BURRITO_TARGET accepts one target; omit it to build all targets"
  [[ " ${all_targets[*]} " == *" ${requested_target} "* ]] || fail "unknown BURRITO_TARGET: ${requested_target}"
  targets=("${requested_target}")
fi

if [[ " ${targets[*]} " == *" windows_x86_64 "* ]] &&
   ! command -v 7z >/dev/null 2>&1 && ! command -v 7zz >/dev/null 2>&1; then
  fail "7z or 7zz is required when building windows_x86_64"
fi

rm -rf burrito_out dist
mkdir -p dist
MIX_ENV=prod mix deps.get --only prod --check-locked
MIX_ENV=prod mix compile --warnings-as-errors
PASEO_RELAY_STANDALONE_BUILD=true MIX_ENV=prod mix release --overwrite

for target in "${targets[@]}"; do
  suffix=""
  [[ "${target}" == windows_x86_64 ]] && suffix=".exe"
  source="burrito_out/paseo_relay_${target}${suffix}"
  case "${target}" in
    linux_x86_64) artifact_target="linux-x86_64" ;;
    linux_aarch64) artifact_target="linux-aarch64" ;;
    windows_x86_64) artifact_target="windows-x86_64" ;;
    macos_x86_64) artifact_target="macos-x86_64" ;;
    macos_aarch64) artifact_target="macos-aarch64" ;;
  esac
  destination="dist/paseo-relay-v${version}-${artifact_target}${suffix}"
  [[ -f "${source}" ]] || fail "Burrito did not produce ${source}"
  mv "${source}" "${destination}"
  [[ "${suffix}" == ".exe" ]] || chmod 0755 "${destination}"
done

if command -v sha256sum >/dev/null 2>&1; then
  (cd dist && sha256sum paseo-relay-v*) > dist/SHA256SUMS.txt
else
  (cd dist && shasum -a 256 paseo-relay-v*) > dist/SHA256SUMS.txt
fi

printf 'Standalone artifacts:\n'
ls -1 dist

#!/usr/bin/env bash
# Copyright (c) 2026 Cohere Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Predicts MRTD and RTMR0 to RTMR2 of every shape in release.yaml from an
# assembled release, with cvm-measure kata-tdx.
#
# Usage: measure-release.sh <release dir> <cvm-measure checkout>
#
# <release dir> holds kata-release.tar.zst and release.json from
# assemble-release.sh; measurements.json is written next to them. MRCONFIGID
# and RTMR3 depend on each pod (its init-data and image pulls), so they are not
# release measurements.

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(dirname "$(readlink -f "$0")")"
pins="${script_dir}/release.yaml"
release="$(readlink -f "${1:?release dir}")"
cvm_measure="$(readlink -f "${2:?cvm-measure checkout}")"

pin() { yq -e "$1" "${pins}"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# The workflow checks out the pin, but this also runs locally, where another
# cvm-measure commit could predict different registers.
want_commit="$(pin .cvm_measure.commit)"
have_commit="$(git -C "${cvm_measure}" rev-parse HEAD)"
[[ "${have_commit}" == "${want_commit}" ]] || die "cvm-measure is at ${have_commit}, release.yaml pins ${want_commit}"

config_path="$(jq -er .config_path "${release}/release.json")"
platform="${cvm_measure}/$(pin .cvm_measure.platform)"

# Measure the bundle as a host installs it: extracted at a root, with the
# runtime config at the path release.json records.
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
tar --zstd --no-same-owner -xf "${release}/kata-release.tar.zst" -C "${work}"

shapes="{}"
for i in $(seq 0 $(( $(pin '.shapes | length') - 1 ))); do
	name="$(pin ".shapes[${i}].name")"
	gpus="$(pin ".shapes[${i}].gpus")"
	vcpus="$(pin ".shapes[${i}].vcpus")"
	memory_mib="$(pin ".shapes[${i}].memory_mib")"
	regs="$(cvm-measure kata-tdx --output-format json \
		--config "${work}${config_path}" --root "${work}" --platform "${platform}" \
		--vcpus "${vcpus}" --memory-mib "${memory_mib}" --gpus "${gpus}")"
	shapes="$(jq --arg n "${name}" \
		--argjson g "${gpus}" --argjson v "${vcpus}" --argjson m "${memory_mib}" \
		--argjson r "${regs}" \
		'. + {($n): {gpus: $g, vcpus: $v, memory_mib: $m,
			mrtd: $r.mrtd, rtmr0: $r.rtmr0, rtmr1: $r.rtmr1, rtmr2: $r.rtmr2}}' \
		<<< "${shapes}")"
done

# measurements.json embeds release.json, so the registers travel with the
# inputs that produced them.
jq --arg repo "$(pin .cvm_measure.repository)" --arg commit "${want_commit}" \
	--arg platform "$(pin .cvm_measure.platform)" \
	--argjson shapes "${shapes}" \
	'{schema_version: 1} + . + {
		cvm_measure: {repository: $repo, commit: $commit, platform: $platform},
		shapes: $shapes
	}' "${release}/release.json" > "${release}/measurements.json"

cat "${release}/measurements.json"

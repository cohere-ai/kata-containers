#!/usr/bin/env bash
# Copyright (c) 2026 Cohere Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Assembles the Cohere Kata release: the upstream kata-static tree with the
# guest kernel and images built from this commit, the CoCo extension pinned in
# release.yaml and the shim installed over it, plus a runtime config directory
# with a generated config.d/50-cohere.toml.
#
# Usage: assemble-release.sh <inputs dir> <output dir>
#
# <inputs dir> holds the workflow's kata-static-<asset>.tar.zst guest tarballs
# and containerd-shim-kata-v2. <output dir> receives kata-release.tar.zst (an
# /opt/kata tree to extract at /) and release.json (every input digest and the
# dm-verity parameters).
#
# Everything that ends up in a TD measurement is either built from this commit
# or pinned by digest in release.yaml, and the output is reproducible: the same
# inputs give the same bundle_sha256.

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(dirname "$(readlink -f "$0")")"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
pins="${script_dir}/release.yaml"
inputs="$(readlink -f "${1:?inputs dir}")"
out="$(readlink -f "${2:?output dir}")"

pin() { yq -e "$1" "${pins}"; }
die() { echo "ERROR: $*" >&2; exit 1; }
sha256() { sha256sum "$1" | cut -d' ' -f1; }

guest_assets=(kernel-nvidia-gpu rootfs-image-nvidia rootfs-image-nvidia-gpu-extension)
# The root image and the two extension images, by the suffix of their
# root_hash_<variant>.txt.
verity_variants=(nvidia nvidia-gpu-extension coco-extension)

runtime="$(pin .runtime.name)"
coco_image="$(pin .coco_extension.image)"
coco_digest="$(pin .coco_extension.digest)"
[[ "${coco_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "pin coco_extension.digest in ${pins}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
root="${work}/root"
share="${root}/opt/kata/share/kata-containers"
config_dir="${root}/opt/kata/share/defaults/kata-containers/runtimes/${runtime}"
mkdir -p "${root}" "${out}"

# Upstream's release is the base. The guest built here is extracted over it,
# replacing upstream's kernel and images.
curl -fsSL -o "${work}/kata-static.tar.zst" "$(pin .kata_static.url)"
echo "$(pin .kata_static.sha256)  ${work}/kata-static.tar.zst" | sha256sum -c -
tar --zstd --no-same-owner -xf "${work}/kata-static.tar.zst" -C "${root}"

for asset in "${guest_assets[@]}"; do
	tar --zstd --no-same-owner -xf "${inputs}/kata-static-${asset}.tar.zst" -C "${root}"
done

# Only an extension built by guest-components' own workflow is accepted.
gh attestation verify "oci://${coco_image}@${coco_digest}" \
	--repo "$(pin .coco_extension.source_repository)"
oras pull "${coco_image}@${coco_digest}" -o "${work}/coco"
install -m 0644 "${work}/coco/kata-containers-coco-extension.img" "${share}/"
install -m 0644 "${work}/coco/root_hash_coco-extension.txt" "${share}/"

install -m 0755 "${inputs}/containerd-shim-kata-v2" \
	"${root}/opt/kata/runtime-rs/bin/containerd-shim-kata-v2"

# Each image's dm-verity parameters, written by its build. The runtime puts
# them on the kernel command line, so they are measured into RTMR2.
declare -A verity
for variant in "${verity_variants[@]}"; do
	verity[${variant}]="$(tr -d '\n' < "${share}/root_hash_${variant}.txt")"
	[[ "${verity[${variant}]}" =~ ^root_hash=[0-9a-f]{64}, ]] || die "bad dm-verity parameters for ${variant}"
done

# The runtime reads config.d next to its config, so the release config gets a
# directory of its own instead of sharing runtime-rs/config.d.
mkdir -p "${config_dir}/config.d"
install -m 0644 \
	"${root}/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-nvidia-gpu-tdx-runtime-rs.toml" \
	"${config_dir}/configuration-${runtime}.toml"

# Drop-ins replace arrays, so both extension images are listed. The guest pulls
# images itself (force_guest_pull). The only annotation a pod can set is its
# init-data, measured into MRCONFIGID; a pod without one gets
# default-initdata.toml, whose policy denies every agent request.
cat > "${config_dir}/config.d/50-cohere.toml" <<EOF
[hypervisor.qemu]
kernel_params = "$(pin .runtime.kernel_params)"
kernel_verity_params = "${verity[nvidia]}"
tdx_quote_generation_service_socket_port = $(pin .runtime.qgs_port)
qmp_connect_timeout_ms = $(pin .runtime.qmp_connect_timeout_ms)
enable_annotations = ["^cc_init_data$"]
initdata = '''
$(cat "${script_dir}/default-initdata.toml")
'''

[[hypervisor.qemu.guest_extension_images]]
name = "gpu"
path = "/opt/kata/share/kata-containers/kata-containers-nvidia-gpu-extension.img"
verity_params = "${verity[nvidia-gpu-extension]}"

[[hypervisor.qemu.guest_extension_images]]
name = "coco"
path = "/opt/kata/share/kata-containers/kata-containers-coco-extension.img"
verity_params = "${verity[coco-extension]}"

[agent.kata]
image_registry_auth_file = "$(pin .runtime.registry_auth_file)"

[runtime]
experimental = ["force_guest_pull"]
EOF
chmod 0644 "${config_dir}/config.d/50-cohere.toml"

# A broken heredoc would ship a config whose pods have no default policy.
python3 - "${config_dir}/config.d/50-cohere.toml" <<'EOF'
import sys, tomllib
qemu = tomllib.load(open(sys.argv[1], "rb"))["hypervisor"]["qemu"]
assert "policy.rego" in tomllib.loads(qemu["initdata"])["data"]
EOF

# Fixed entry order, mtimes and owners, so a rebuild of the same commit can be
# compared byte for byte.
source_date_epoch="$(git -C "${repo_root}" log -1 --format=%ct)"
tar --sort=name --format=posix \
	--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
	--mtime="@${source_date_epoch}" --owner=0 --group=0 --numeric-owner \
	--zstd -cf "${out}/kata-release.tar.zst" -C "${root}" ./opt

# release.json is what consumers read instead of unpacking the bundle.
# oci-hpc-images checks bundle_sha256 and config_d_50_cohere_sha256 when it
# installs; integritee derives policy from the inputs and verity parameters.
guest_json="{}"
for asset in "${guest_assets[@]}"; do
	guest_json="$(jq --arg a "${asset}" --arg s "$(sha256 "${inputs}/kata-static-${asset}.tar.zst")" \
		'. + {($a): $s}' <<< "${guest_json}")"
done
verity_json="{}"
for variant in "${verity_variants[@]}"; do
	verity_json="$(jq --arg v "${variant}" --arg p "${verity[${variant}]}" \
		'. + {($v): $p}' <<< "${verity_json}")"
done

jq -n \
	--arg kata_version "$(pin .kata_static.version)" \
	--arg commit "$(git -C "${repo_root}" rev-parse HEAD)" \
	--arg driver "$(yq -e .externals.nvidia.driver.version "${repo_root}/versions.yaml")" \
	--arg runtime "${runtime}" \
	--arg kernel_params "$(pin .runtime.kernel_params)" \
	--arg kata_static_url "$(pin .kata_static.url)" \
	--arg kata_static_sha256 "$(pin .kata_static.sha256)" \
	--arg coco "${coco_image}@${coco_digest}" \
	--arg shim "$(sha256 "${inputs}/containerd-shim-kata-v2")" \
	--arg config_sha256 "$(sha256 "${config_dir}/config.d/50-cohere.toml")" \
	--arg bundle_sha256 "$(sha256 "${out}/kata-release.tar.zst")" \
	--argjson guest "${guest_json}" \
	--argjson verity "${verity_json}" \
	'{
		kata_version: $kata_version,
		commit: $commit,
		nvidia_driver_version: $driver,
		runtime: $runtime,
		config_path: ("/opt/kata/share/defaults/kata-containers/runtimes/" + $runtime + "/configuration-" + $runtime + ".toml"),
		kernel_params: $kernel_params,
		kernel_verity_params: $verity.nvidia,
		verity_params: $verity,
		inputs: {
			kata_static: {url: $kata_static_url, sha256: $kata_static_sha256},
			coco_extension: $coco,
			shim_sha256: $shim,
			guest_tarballs_sha256: $guest
		},
		config_d_50_cohere_sha256: $config_sha256,
		bundle_sha256: $bundle_sha256
	}' > "${out}/release.json"

cat "${out}/release.json"

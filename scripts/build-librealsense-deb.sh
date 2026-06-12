#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-librealsense-deb.sh [options]

Options:
  --ref REF            Build a specific git ref in a detached worktree
  --version VERSION    Override the package version from package.xml
  --output-dir DIR    Write the final .deb to DIR (default: dist)
  --build-dir DIR     Use DIR for the CMake build directory
  --skip-deps         Do not install system build dependencies
  -h, --help          Show this help text

The script must be run from inside a librealsense git checkout.
EOF
}

source_ref=""
package_version_override=""
output_dir="dist"
build_dir=""
install_deps=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      source_ref="${2:-}"
      shift 2
      ;;
    --version)
      package_version_override="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --build-dir)
      build_dir="${2:-}"
      shift 2
      ;;
    --skip-deps)
      install_deps=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

run_as_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Need root privileges for: $*" >&2
    exit 1
  fi
}

repo_root=$(git rev-parse --show-toplevel)
source_dir="$repo_root"
worktree_root=""
cleanup() {
  if [[ -n "$worktree_root" && -d "$worktree_root" ]]; then
    git -C "$repo_root" worktree remove --force "$source_dir" >/dev/null 2>&1 || true
    rm -rf "$worktree_root"
  fi
}
trap cleanup EXIT

if [[ -n "$source_ref" ]]; then
  worktree_root=$(mktemp -d)
  source_dir="$worktree_root/librealsense"
  git -C "$repo_root" worktree add --detach "$source_dir" "$source_ref"
fi

if [[ $install_deps -eq 1 ]]; then
  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    dpkg-dev \
    fakeroot \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    libglfw3-dev \
    libssl-dev \
    libudev-dev \
    libusb-1.0-0-dev \
    libx11-dev \
    pkg-config
fi

if [[ -z "$package_version_override" ]]; then
  package_version=$(sed -n 's#.*<version>\(.*\)</version>.*#\1#p' "$source_dir/package.xml" | head -n1)
else
  package_version="$package_version_override"
fi

if [[ -z "$package_version" ]]; then
  echo "Failed to determine package version" >&2
  exit 1
fi

architecture=$(dpkg --print-architecture)
build_dir=${build_dir:-"$source_dir/build-deb"}
stage_dir=$(mktemp -d)
pkg_dir="$repo_root/$output_dir"
pkg_path="$pkg_dir/librealsense2_${package_version}_${architecture}.deb"

mkdir -p "$pkg_dir"
rm -rf "$build_dir"

cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_GRAPHICAL_EXAMPLES=OFF \
  -DBUILD_TOOLS=OFF \
  -DBUILD_UNIT_TESTS=OFF \
  -DBUILD_PYTHON_BINDINGS=OFF \
  -DBUILD_CSHARP_BINDINGS=OFF \
  -DBUILD_MATLAB_BINDINGS=OFF \
  -DBUILD_UNITY_BINDINGS=OFF \
  -DBUILD_OPENNI2_BINDINGS=OFF \
  -DBUILD_OPEN3D_EXAMPLES=OFF \
  -DBUILD_WITH_DDS=OFF \
  -DBUILD_WITH_CUDA=OFF \
  -DBUILD_WITH_TM2=OFF \
  -DBUILD_GLSL_EXTENSIONS=OFF \
  -DBUILD_PC_STITCHING=OFF \
  -DBUILD_RS2_ALL=OFF \
  -DIMPORT_DEPTH_CAM_FW=OFF \
  -DCHECK_FOR_UPDATES=OFF

cmake --build "$build_dir" --parallel "$(nproc)"
DESTDIR="$stage_dir" cmake --install "$build_dir"

mkdir -p "$stage_dir/DEBIAN"
cat > "$stage_dir/DEBIAN/control" <<EOF
Package: librealsense2
Version: $package_version
Section: libs
Priority: optional
Architecture: $architecture
Maintainer: LibRealSense ROS Team <rsswsdk@realsensecloud.onmicrosoft.com>
Depends: libc6, libgcc-s1, libssl3, libstdc++6, libudev1, libusb-1.0-0, libx11-6
Description: Library for controlling and capturing data from Intel RealSense D400 devices.
EOF

run_as_root fakeroot dpkg-deb --build "$stage_dir" "$pkg_path"

echo "Built $pkg_path"

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
  --with-gl           Build and package librealsense2-gl variants
  --with-debug        Build and package debug symbol variants
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
with_gl=0
with_debug=0

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
    --with-gl)
      with_gl=1
      shift
      ;;
    --with-debug)
      with_debug=1
      shift
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

checkout_dir=$(pwd -P)
git config --global --add safe.directory "$checkout_dir"

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
pkg_roots_dir=$(mktemp -d)
pkg_dir="$repo_root/$output_dir"

if [[ $with_gl -eq 1 ]]; then
  glsl_extensions_flag="ON"
else
  glsl_extensions_flag="OFF"
fi

mkdir -p "$pkg_dir"
rm -rf "$build_dir"

cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_GRAPHICAL_EXAMPLES=OFF \
  -DBUILD_TOOLS=ON \
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
  -DBUILD_GLSL_EXTENSIONS=${glsl_extensions_flag} \
  -DBUILD_PC_STITCHING=OFF \
  -DBUILD_RS2_ALL=OFF \
  -DIMPORT_DEPTH_CAM_FW=OFF \
  -DCHECK_FOR_UPDATES=OFF

cmake --build "$build_dir" --parallel "$(nproc)"
DESTDIR="$stage_dir" cmake --install "$build_dir"

# Install udev rules into a distro-friendly location so they can be packaged separately.
mkdir -p "$stage_dir/lib/udev/rules.d"
cp "$source_dir/config/99-realsense-libusb.rules" \
  "$stage_dir/lib/udev/rules.d/60-librealsense2-udev-rules.rules"

runtime_root="$pkg_roots_dir/librealsense2"
dev_root="$pkg_roots_dir/librealsense2-dev"
utils_root="$pkg_roots_dir/librealsense2-utils"
udev_root="$pkg_roots_dir/librealsense2-udev-rules"
gl_root="$pkg_roots_dir/librealsense2-gl"
gl_dev_root="$pkg_roots_dir/librealsense2-gl-dev"
dbg_root="$pkg_roots_dir/librealsense2-dbg"
gl_dbg_root="$pkg_roots_dir/librealsense2-gl-dbg"

mkdir -p "$runtime_root" "$dev_root" "$utils_root" "$udev_root" "$gl_root" "$gl_dev_root" "$dbg_root" "$gl_dbg_root"

is_gl_artifact() {
  local rel_path="$1"
  [[ "$rel_path" == *realsense2-gl* ]]
}

add_path() {
  local pkg_root="$1"
  local rel_path="$2"
  local src_path="$stage_dir/$rel_path"
  local dst_path="$pkg_root/$rel_path"

  if [[ ! -e "$src_path" ]]; then
    return
  fi

  if [[ -d "$src_path" ]]; then
    mkdir -p "$dst_path"
    cp -a "$src_path/." "$dst_path/"
  else
    mkdir -p "$pkg_root/$(dirname "$rel_path")"
    cp -a "$src_path" "$dst_path"
  fi
}

for include_dir in "$stage_dir"/usr/include "$stage_dir"/usr/local/include; do
  if [[ -d "$include_dir" ]]; then
    rel="${include_dir#$stage_dir/}"
    add_path "$dev_root" "$rel"
  fi
done

for pkgconfig_dir in "$stage_dir"/usr/lib*/pkgconfig "$stage_dir"/usr/local/lib*/pkgconfig; do
  if [[ -d "$pkgconfig_dir" ]]; then
    rel="${pkgconfig_dir#$stage_dir/}"
    add_path "$dev_root" "$rel"
  fi
done

for cmake_dir in "$stage_dir"/usr/lib*/cmake; do
  if [[ -d "$cmake_dir" ]]; then
    rel="${cmake_dir#$stage_dir/}"
    add_path "$dev_root" "$rel"
  fi
done

while IFS= read -r -d '' lib_path; do
  rel="${lib_path#$stage_dir/}"
  base_name="$(basename "$lib_path")"
  if [[ "$base_name" == *.so.* ]]; then
    if is_gl_artifact "$rel"; then
      add_path "$gl_root" "$rel"
    else
      add_path "$runtime_root" "$rel"
    fi
  else
    if is_gl_artifact "$rel"; then
      add_path "$gl_dev_root" "$rel"
    else
      add_path "$dev_root" "$rel"
    fi
  fi
done < <(find "$stage_dir"/usr/lib* -type f \( -name 'librealsense*.so*' -o -name 'librs*.so*' -o -name '*.a' \) -print0 2>/dev/null)

while IFS= read -r -d '' lib_link; do
  rel="${lib_link#$stage_dir/}"
  if is_gl_artifact "$rel"; then
    add_path "$gl_dev_root" "$rel"
  else
    add_path "$dev_root" "$rel"
  fi
done < <(find "$stage_dir"/usr/lib* -type l \( -name 'librealsense*.so' -o -name 'librs*.so' \) -print0 2>/dev/null)

if [[ -e "$dev_root/usr/lib/pkgconfig/realsense2-gl.pc" ]]; then
  mkdir -p "$gl_dev_root/usr/lib/pkgconfig"
  mv "$dev_root/usr/lib/pkgconfig/realsense2-gl.pc" "$gl_dev_root/usr/lib/pkgconfig/realsense2-gl.pc"
fi

add_path "$utils_root" "usr/bin"
add_path "$utils_root" "usr/share"
add_path "$udev_root" "lib/udev/rules.d/60-librealsense2-udev-rules.rules"

extract_debug_symbols() {
  local src_root="$1"
  local dst_root="$2"

  while IFS= read -r -d '' binary_path; do
    # Prefer readelf over file(1) so --with-debug works in minimal CI images.
    if ! readelf -h "$binary_path" >/dev/null 2>&1; then
      continue
    fi

    local rel_path="${binary_path#$src_root/}"
    local dbg_rel="usr/lib/debug/${rel_path}.debug"
    local dbg_abs="$dst_root/$dbg_rel"

    mkdir -p "$(dirname "$dbg_abs")"
    objcopy --only-keep-debug "$binary_path" "$dbg_abs"
    strip --strip-unneeded "$binary_path" || true
    objcopy --add-gnu-debuglink="$dbg_abs" "$binary_path" || true
  done < <(find "$src_root" -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null)
}

if [[ $with_debug -eq 1 ]]; then
  if ! command -v objcopy >/dev/null 2>&1 || ! command -v strip >/dev/null 2>&1 || ! command -v readelf >/dev/null 2>&1; then
    echo "objcopy/strip/readelf are required for --with-debug" >&2
    exit 1
  fi

  extract_debug_symbols "$runtime_root" "$dbg_root"
  extract_debug_symbols "$utils_root" "$dbg_root"

  if [[ $with_gl -eq 1 ]]; then
    extract_debug_symbols "$gl_root" "$gl_dbg_root"
  fi
fi

has_payload() {
  local pkg_root="$1"
  local first_entry
  first_entry=$(find "$pkg_root" -mindepth 1 \
    -not -path "$pkg_root/DEBIAN" \
    -not -path "$pkg_root/DEBIAN/*" \
    -print -quit)
  [[ -n "$first_entry" ]]
}

build_deb() {
  local package_name="$1"
  local pkg_root="$2"
  local depends="$3"
  local description="$4"
  local output_path="$pkg_dir/${package_name}_${package_version}_${architecture}.deb"

  if ! has_payload "$pkg_root"; then
    echo "Skipping $package_name: no payload files found"
    return
  fi

  mkdir -p "$pkg_root/DEBIAN"
  {
    echo "Package: $package_name"
    echo "Version: $package_version"
    echo "Section: libs"
    echo "Priority: optional"
    echo "Architecture: $architecture"
    echo "Maintainer: LibRealSense ROS Team <rsswsdk@realsensecloud.onmicrosoft.com>"
    if [[ -n "$depends" ]]; then
      echo "Depends: $depends"
    fi
    echo "Description: $description"
  } > "$pkg_root/DEBIAN/control"

  fakeroot dpkg-deb --build "$pkg_root" "$output_path"
  echo "Built $output_path"
}

build_deb \
  "librealsense2-udev-rules" \
  "$udev_root" \
  "udev" \
  "RealSense udev rules for camera permissions."

build_deb \
  "librealsense2" \
  "$runtime_root" \
  "librealsense2-udev-rules, libc6, libgcc-s1, libssl3, libstdc++6, libudev1, libusb-1.0-0, libx11-6" \
  "RealSense SDK runtime shared libraries."

if ! has_payload "$dev_root"; then
  # Fallback: copy development payload directly from staged install roots.
  add_path "$dev_root" "usr/include"
  add_path "$dev_root" "usr/local/include"

  while IFS= read -r -d '' pc_file; do
    rel="${pc_file#$stage_dir/}"
    add_path "$dev_root" "$rel"
  done < <(find "$stage_dir" -type f -path '*/pkgconfig/*.pc' -print0 2>/dev/null)

  while IFS= read -r -d '' cmake_entry; do
    rel="${cmake_entry#$stage_dir/}"
    add_path "$dev_root" "$rel"
  done < <(find "$stage_dir" -path '*/cmake/realsense2*' -print0 2>/dev/null)
fi

if ! has_payload "$dev_root"; then
  echo "Diagnostics: librealsense2-dev payload is empty" >&2
  echo "Diagnostics: looking for installed headers under stage" >&2
  find "$stage_dir" -maxdepth 5 -type d -name include -o -name librealsense2 2>/dev/null | sed 's#^#  #g' >&2 || true
  echo "Diagnostics: installed pkgconfig files" >&2
  find "$stage_dir" -maxdepth 6 -type f -name '*.pc' 2>/dev/null | sed 's#^#  #g' >&2 || true
  echo "Diagnostics: current dev package tree" >&2
  find "$dev_root" -maxdepth 8 -mindepth 1 2>/dev/null | sed 's#^#  #g' >&2 || true
fi

build_deb \
  "librealsense2-dev" \
  "$dev_root" \
  "librealsense2 (= $package_version)" \
  "RealSense SDK development headers and CMake/pkg-config metadata."

build_deb \
  "librealsense2-utils" \
  "$utils_root" \
  "librealsense2 (= $package_version)" \
  "RealSense SDK utilities and command-line tools."

if [[ $with_gl -eq 1 ]]; then
  build_deb \
    "librealsense2-gl" \
    "$gl_root" \
    "librealsense2 (= $package_version)" \
    "RealSense SDK GLSL runtime module and related libraries."

  build_deb \
    "librealsense2-gl-dev" \
    "$gl_dev_root" \
    "librealsense2-gl (= $package_version), librealsense2 (= $package_version)" \
    "RealSense SDK GLSL development files."
fi

if [[ $with_debug -eq 1 ]]; then
  build_deb \
    "librealsense2-dbg" \
    "$dbg_root" \
    "librealsense2 (= $package_version)" \
    "RealSense SDK debug symbols for runtime and utilities."

  if [[ $with_gl -eq 1 ]]; then
    build_deb \
      "librealsense2-gl-dbg" \
      "$gl_dbg_root" \
      "librealsense2-gl (= $package_version), librealsense2 (= $package_version)" \
      "RealSense SDK GLSL debug symbols."
  fi
fi

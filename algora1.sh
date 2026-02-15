#!/usr/bin/env bash
set -euo pipefail

# Silence gcloud's "updates available" and other non-essential notices
export CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=1
export CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=1

# =========================
# FIXED DEFAULTS (no prompts)
# =========================
INSTANCE_NAME="algora1"
KEY_NAME="ssh_key1"

REGION_DEFAULT="us-central1"
ZONE_DEFAULT="us-central1-c"
MACHINE_TYPE_DEFAULT="e2-custom-1-3072"

IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"

ENGINE_NAMES=( "BEXP" "PMNY" "TSLA" "NVDA" )

zip_url_for_engine() {
  case "$1" in
    BEXP) echo "https://ce61ee09-0950-4d0d-b651-266705220b65.usrfiles.com/archives/ce61ee_c7d95081e6a44835911d55171c3721f4.zip" ;;
    PMNY) echo "https://ce61ee09-0950-4d0d-b651-266705220b65.usrfiles.com/archives/ce61ee_9599255c688e49d99381eeafae3bb8fe.zip" ;;
    TSLA) echo "https://ce61ee09-0950-4d0d-b651-266705220b65.usrfiles.com/archives/ce61ee_a19125ed34b2454fa50d7bd8075a9a72.zip" ;;
    NVDA) echo "https://ce61ee09-0950-4d0d-b651-266705220b65.usrfiles.com/archives/ce61ee_871af284fc2043db98c9864fd933b90e.zip" ;;
    *) echo "" ;;
  esac
}

# =========================
# LOCAL PERSISTED CONFIG
# =========================
CFG_DIR="${HOME}/.config/algora1_setup"
CFG_FILE="${CFG_DIR}/config.env"

QUIET="${QUIET:-1}"

log()  { printf "\033[1;32m[algora1]\033[0m %s\n" "$*" >&2; }
logq() { [ "${QUIET}" = "1" ] || log "$@"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[error]\033[0m %s\n" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      die "Unsupported OS: $os (only macOS/Linux supported)" ;;
  esac
}

# =========================
# TUI (gum) LAYER
# =========================
ui_has_gum() { need_cmd gum; }

ui_header() {
  if ui_has_gum; then
    gum style --border rounded --padding "1 2" --margin "0 0 1 0" \
      --border-foreground 212 \
      "$(printf "🚀 algora1 Installer\nAutomated investment engine deployment.\nmodern installer mode")" >&2
  else
    log "🚀 algora1 Installer"
    log "Automated investment engine deployment."
  fi
}

ui_step() {
  local label="$1"
  if ui_has_gum; then
    gum style --bold --foreground 212 "$label" >&2
  else
    log "$label"
  fi
}

ui_ok() {
  local msg="$1"
  if ui_has_gum; then
    printf "✓ %s\n" "$msg" >&2
  else
    log "✓ $msg"
  fi
}

ui_info() {
  local msg="$1"
  if ui_has_gum; then
    gum style --foreground 245 "INFO $msg" >&2
  else
    log "INFO $msg"
  fi
}

ui_warn() {
  local msg="$1"
  if ui_has_gum; then
    gum style --foreground 214 "WARN $msg" >&2
  else
    warn "$msg"
  fi
}

ui_die() {
  local msg="$1"
  if ui_has_gum; then
    gum style --foreground 196 --bold "ERROR $msg" >&2
  else
    die "$msg"
  fi
  exit 1
}

ui_spin() {
  local label="$1"
  shift
  if ui_has_gum; then
    gum spin --spinner dot --title "$label" -- "$@" >/dev/null 2>&1
  else
    ui_info "$label"
    "$@" >/dev/null 2>&1
  fi
}

ui_choose() {
  local title="$1"; shift
  if ui_has_gum; then
    gum choose --header "$title" "$@"
  else
    printf "%s\n" "$title" >&2
    local i=1
    for opt in "$@"; do
      printf "  %d) %s\n" "$i" "$opt" >&2
      i=$((i+1))
    done
    printf "Select [1-%d]: " "$(($#))" >&2
    local n; read -r n
    n="${n:-1}"
    echo "${@:n:1}"
  fi
}

ui_input() {
  local prompt="$1"
  if ui_has_gum; then
    gum input --prompt "$prompt " --placeholder ""
  else
    printf "%s " "$prompt" >&2
    local v; read -r v
    printf "%s\n" "$v"
  fi
}

ui_secret() {
  local prompt="$1"
  if ui_has_gum; then
    gum input --password --prompt "$prompt " --placeholder ""
  else
    printf "%s " "$prompt" >&2
    stty -echo || true
    local v; read -r v || true
    stty echo || true
    printf "\n" >&2
    printf "%s\n" "$v"
  fi
}

# NEW: list-style key/value (no box)
ui_kv_list() {
  # ui_kv_list "Key" "Val" ...
  while [ "$#" -ge 2 ]; do
    printf "  %-12s %s\n" "$1:" "$2" >&2
    shift 2
  done
}

ensure_gum() {
  if ui_has_gum; then return; fi

  ui_info "gum not found; installing for a nicer installer UI…"

  local os
  os="$(detect_os)"

  if [ "$os" = "macos" ] && need_cmd brew; then
    ui_spin "Installing gum via Homebrew…" brew install gum
  elif [ "$os" = "linux" ] && need_cmd apt-get; then
    ui_spin "Preparing Charm apt repo…" bash -c '
      set -e
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
      echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
      sudo apt-get update -y
    '
    ui_spin "Installing gum…" sudo apt-get install -y gum
  elif [ "$os" = "linux" ] && need_cmd yum; then
    ui_spin "Preparing Charm yum repo…" bash -c '
      set -e
      sudo tee /etc/yum.repos.d/charm.repo >/dev/null <<EOF
[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=0
EOF
      sudo yum makecache -y
    '
    ui_spin "Installing gum…" sudo yum install -y gum
  else
    ui_warn "Could not auto-install gum (no supported package manager). Continuing without TUI."
  fi
}

install_linux_desktop_shortcut() {
  local icon_url="$1"   # your Wix image URL (png recommended)
  local apps_dir="${HOME}/.local/share/applications"
  local icon_dir="${HOME}/.local/share/icons"
  local bin_path="${HOME}/.local/bin/algora1"

  mkdir -p "$apps_dir" "$icon_dir"

  local icon_path="$icon_dir/algora1.png"
  if [ -n "$icon_url" ]; then
    curl -fsSL "$icon_url" -o "$icon_path" || true
  fi

  cat > "$apps_dir/algora1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=algora1
Comment=algora1 control panel
Exec=$bin_path
Terminal=true
Icon=$icon_path
Categories=Finance;Utility;
EOF

  chmod +x "$apps_dir/algora1.desktop"
  ui_ok "Linux shortcut created: $apps_dir/algora1.desktop"
}

install_local_cli() {
  local target_dir="${HOME}/.local/bin"
  mkdir -p "$target_dir"
  chmod 755 "$target_dir"

  local target="$target_dir/algora1"

  # If we're running from a pipe (stdin), we can't cp "$0".
  # Download installer content to the target instead.
  if [ "${0##*/}" = "bash" ] || [ "${0##*/}" = "sh" ] || [ ! -f "${0}" ]; then
    : "${ALGORA1_INSTALL_URL:=https://raw.githubusercontent.com/Yohannes22-ops/algora1-installer/main/algora1.sh}"
    need_cmd curl || ui_die "curl is required to install the local command."

    ui_info "Installing local command by downloading from ${ALGORA1_INSTALL_URL}"
    curl -fsSL "${ALGORA1_INSTALL_URL}" -o "${target}" || ui_die "Failed to download installer."
    chmod +x "${target}"
    ui_ok "Installed local command: ${target}"
  else
    # Normal case: script is a real file on disk
    local self
    self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    if [ "$self" != "$target" ]; then
      cp -f "$self" "$target"
      chmod +x "$target"
      ui_ok "Installed local command: $target"
    else
      ui_ok "Local command already installed: $target"
    fi
  fi

  ui_info "Add this to your shell profile if needed:"
  ui_info "  export PATH=\"$target_dir:\$PATH\""

  if [ "$(detect_os)" = "macos" ]; then
    local zshrc="${HOME}/.zshrc"
    local line='export PATH="$HOME/.local/bin:$PATH"'
    touch "$zshrc"
    if ! grep -Fqx "$line" "$zshrc"; then
      printf "\n# algora1\n%s\n" "$line" >> "$zshrc"
      ui_ok "Added ~/.local/bin to PATH in ~/.zshrc"
      ui_info "Restart Terminal or run: source ~/.zshrc"
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

# =========================
# macOS icon helpers (.png -> .icns) + optional Drive download
# =========================
WIX_ICON_PNG_URL="https://static.wixstatic.com/media/ce61ee_00cd47ee0f9c48f69f0f7546f4298188~mv2.png"
GDRIVE_ICNS_FILE_ID="111ErBsF_zrgT6_jpuQERAFCXYPsSgMap"

download_public_gdrive_file() {
  # Best-effort downloader for *publicly shared* Drive files.
  # Works for small files; includes fallback for larger/confirm flows. :contentReference[oaicite:2]{index=2}
  local file_id="$1"
  local out="$2"

  need_cmd curl || return 1

  # Fast path (often works)
  if curl -fsSL -o "$out" "https://drive.google.com/uc?export=download&id=${file_id}"; then
    [ -s "$out" ] && return 0
  fi

  # Fallback confirm-token flow (more reliable for larger files)
  local cookie
  cookie="$(mktemp)"
  local html
  html="$(curl -c "$cookie" -s -L "https://drive.google.com/uc?export=download&id=${file_id}" || true)"
  local confirm
  confirm="$(printf "%s" "$html" | grep -Eo 'confirm=[a-zA-Z0-9_-]+' | head -n 1 || true)"
  if [ -n "$confirm" ]; then
    curl -Lb "$cookie" -L "https://drive.google.com/uc?export=download&${confirm}&id=${file_id}" -o "$out" || true
  fi
  rm -f "$cookie"
  [ -s "$out" ]
}

png_to_icns_macos() {
  # Requires macOS: sips + iconutil
  local png="$1"
  local out_icns="$2"

  need_cmd sips     || ui_die "macOS 'sips' not found (unexpected)."
  need_cmd iconutil || ui_die "macOS 'iconutil' not found (unexpected)."  # :contentReference[oaicite:3]{index=3}

  local tmp
  tmp="$(mktemp -d)"
  local iconset="${tmp}/algora1.iconset"
  mkdir -p "$iconset"

  # Generate required sizes
  sips -z 16 16     "$png" --out "${iconset}/icon_16x16.png" >/dev/null
  sips -z 32 32     "$png" --out "${iconset}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$png" --out "${iconset}/icon_32x32.png" >/dev/null
  sips -z 64 64     "$png" --out "${iconset}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$png" --out "${iconset}/icon_128x128.png" >/dev/null
  sips -z 256 256   "$png" --out "${iconset}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$png" --out "${iconset}/icon_256x256.png" >/dev/null
  sips -z 512 512   "$png" --out "${iconset}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$png" --out "${iconset}/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$png" --out "${iconset}/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset" -o "$out_icns" >/dev/null  # :contentReference[oaicite:4]{index=4}
  rm -rf "$tmp"
  [ -s "$out_icns" ]
}

ensure_algora1_icns() {
  # Returns path to an icns (prints it), best-effort.
  # Priority:
  # 1) explicit path arg
  # 2) ~/.config/algora1_setup/algora1.icns
  # 3) ~/Desktop/algora1.icns
  # 4) download from Drive (if publicly shared)
  # 5) download Wix PNG + convert to icns
  local provided="${1:-}"
  local cfg_icns="${HOME}/.config/algora1_setup/algora1.icns"
  local desktop_icns="${HOME}/Desktop/algora1.icns"

  mkdir -p "${HOME}/.config/algora1_setup" || true

  if [ -n "$provided" ] && [ -f "$provided" ]; then
    echo "$provided"; return 0
  fi
  if [ -f "$cfg_icns" ]; then
    echo "$cfg_icns"; return 0
  fi
  if [ -f "$desktop_icns" ]; then
    echo "$desktop_icns"; return 0
  fi

  # Try Drive (only if publicly shared)
  if [ -n "${GDRIVE_ICNS_FILE_ID:-}" ]; then
    if download_public_gdrive_file "$GDRIVE_ICNS_FILE_ID" "$cfg_icns"; then
      echo "$cfg_icns"; return 0
    fi
  fi

  # Build from Wix PNG
  local tmp_png
  tmp_png="$(mktemp -t algora1_icon.XXXXXX).png"
  if curl -fsSL "$WIX_ICON_PNG_URL" -o "$tmp_png"; then
    if png_to_icns_macos "$tmp_png" "$cfg_icns"; then
      rm -f "$tmp_png" || true
      echo "$cfg_icns"; return 0
    fi
  fi
  rm -f "$tmp_png" || true

  # Nothing worked
  echo ""
  return 1
}

ALGORA1_BUNDLE_ID="com.algora1.launcher"

is_trusted_algora1_app_bundle() {
  # Returns 0 if the app exists AND matches what we generate
  local app_root="$1"
  local plist="${app_root}/Contents/Info.plist"
  local exe="${app_root}/Contents/MacOS/algora1"
  local marker="${app_root}/Contents/Resources/.algora1_generated"

  [ -d "$app_root" ] || return 1
  [ -f "$plist" ] || return 1
  [ -x "$exe" ] || return 1
  [ -f "$marker" ] || return 1

  # Verify bundle id
  local bid
  bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  [ "$bid" = "$ALGORA1_BUNDLE_ID" ] || return 1

  # Verify executable name
  local bexe
  bexe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
  [ "$bexe" = "algora1" ] || return 1

  # Verify our launcher contains the expected command (basic sanity)
  grep -q 'do script "algora1"' "$exe" 2>/dev/null || return 1

  return 0
}

ensure_macos_app_bundle_present() {
  # Create the app if missing OR not trusted
  local icns_path="${1:-}"
  local app_root="${HOME}/Applications/algora1.app"
  local desktop_app="${HOME}/Desktop/algora1.app"

  # Prefer ~/Applications location
  if is_trusted_algora1_app_bundle "$app_root"; then
    ui_ok "macOS app bundle already present: $app_root"
    return 0
  fi

  # Some users may have dragged it to Desktop; accept only if trusted
  if is_trusted_algora1_app_bundle "$desktop_app"; then
    ui_ok "macOS app bundle already present: $desktop_app"
    return 0
  fi

  ui_info "Creating macOS Dock app (algora1.app)…"
  install_macos_app_bundle "$icns_path"

  # Re-check to confirm creation worked
  if ! is_trusted_algora1_app_bundle "$app_root"; then
    ui_warn "App bundle creation ran, but bundle did not validate. Check permissions: ~/Applications"
    return 1
  fi

  # Optional: also place a copy on Desktop (only if Desktop doesn't already have a trusted one)
  if ! is_trusted_algora1_app_bundle "$desktop_app"; then
    cp -R "$app_root" "$desktop_app" >/dev/null 2>&1 || true
  fi

  return 0
}


install_macos_app_bundle() {
  # Creates ~/Applications/algora1.app that runs ~/.local/bin/algora1 in Terminal
  # Uses an .icns icon if provided (local path).

  local icns_path="${1:-}"   # optional local path to .icns
  local app_root="${HOME}/Applications/algora1.app"
  local contents="${app_root}/Contents"
  local macos_dir="${contents}/MacOS"
  local res_dir="${contents}/Resources"

  mkdir -p "${macos_dir}" "${res_dir}"

  # --- Launcher executable (opens Terminal and runs algora1) ---
  cat > "${macos_dir}/algora1" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Ensure user's local bin is available
export PATH="${HOME}/.local/bin:${PATH}"

# Open Terminal and run algora1
osascript >/dev/null <<OSA
tell application "Terminal"
  activate
  do script "algora1"
end tell
OSA
EOF
  chmod +x "${macos_dir}/algora1"

  # --- Info.plist (sets Dock icon + app metadata) ---
  cat > "${contents}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>algora1</string>
  <key>CFBundleIconFile</key><string>algora1</string>
  <key>CFBundleIdentifier</key><string>com.algora1.launcher</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>algora1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
</dict>
</plist>
EOF

  # PkgInfo is optional but harmless
  printf "APPL????" > "${contents}/PkgInfo" || true

  # --- Icon (auto) ---
  local resolved_icns=""
  resolved_icns="$(ensure_algora1_icns "${icns_path:-}" || true)"
  if [ -n "$resolved_icns" ] && [ -f "$resolved_icns" ]; then
    cp "$resolved_icns" "${res_dir}/algora1.icns"
  fi

  # Mark this bundle as generated by this installer (prevents trusting random same-named apps)
  printf "generated-by=algora1-installer\n" > "${res_dir}/.algora1_generated" || true

  ui_ok "macOS app created: ${app_root}"
  ui_info "Tip: drag 'algora1.app' into your Dock. First run may require right-click → Open."

  # Reveal in Finder so user can drag to Dock
  open -R "${app_root}" >/dev/null 2>&1 || true
}

# -------------------------
# CLI subcommands (run and exit)
# -------------------------
if [ "${1:-}" = "--install-local" ]; then
  ensure_gum || true
  ui_header
  install_local_cli

  if [ "$(detect_os)" = "linux" ]; then
    install_linux_desktop_shortcut "https://static.wixstatic.com/media/ce61ee_00cd47ee0f9c48f69f0f7546f4298188~mv2.png"
  fi

  # macOS Dock icon app bundle
  if [ "$(detect_os)" = "macos" ]; then
    # Provide your icon path via env var, e.g. ALGORA1_ICNS_PATH="$HOME/Desktop/algora1.icns"
    install_macos_app_bundle "${ALGORA1_ICNS_PATH:-}"
  fi

  exit 0
fi

# =========================
# FAST PATH: if instance exists, go straight to control panel
# =========================
fast_path_to_control_panel_if_ready() {
  # Only works after PROJECT_ID/ZONE are known and gcloud auth is ready
  instance_exists || return 1

  # If the VM isn't running yet, do normal flow
  local status
  status="$(gcloud compute instances describe "${INSTANCE_NAME}" --zone "${ZONE}" --format="get(status)" 2>/dev/null || true)"
  [ "$status" = "RUNNING" ] || return 1

  local ip
  ip="$(get_instance_ip)"
  [ -n "${ip}" ] || return 1

  ui_ok "Instance already exists & RUNNING: ${INSTANCE_NAME} (${ZONE})"
  ui_ok "Instance external IP: ${ip}"

  ssh-keygen -R "${ip}" >/dev/null 2>&1 || true
  wait_for_ssh_ready "${ip}"

  # If control panel not installed yet, install it (best-effort)
  local key_path="${HOME}/.ssh/${KEY_NAME}"
  ui_info "Updating control panel on VM…"
  install_control_panel_on_vm "${ip}"


  if [ "$(detect_os)" = "macos" ]; then
    ensure_macos_app_bundle_present "${ALGORA1_ICNS_PATH:-}" || true
  fi

  ui_info "Launching control panel…"
  ssh_into_instance_menu "${ip}"
}

# =========================
# ZIP TRANSFER
# =========================
ensure_local_tools_for_zip() {
  need_cmd curl || ui_die "curl is required but not found."
  need_cmd unzip || ui_die "unzip is required but not found. Install unzip and re-run."
}

download_and_extract_single_exe() {
  local name="$1"
  local url="$2"
  local workdir="$3"

  [ -n "${url}" ] || ui_die "Missing ZIP URL for ${name}"

  mkdir -p "${workdir}/${name}"
  local zip_path="${workdir}/${name}/${name}.zip"
  local extract_dir="${workdir}/${name}/extract"
  mkdir -p "${extract_dir}"

  ui_info "Downloading ${name}.zip"
  curl -fL --retry 3 --retry-delay 1 --progress-bar -o "${zip_path}" "${url}" \
    || ui_die "Failed to download ${name} from ${url}"

  ui_info "Unzipping ${name}.zip"
  rm -rf "${extract_dir:?}/"*
  unzip -q "${zip_path}" -d "${extract_dir}" || ui_die "Failed to unzip ${name}.zip"

  local candidates=()
  while IFS= read -r -d '' f; do candidates+=("$f"); done < <(
    find "${extract_dir}" -type f \( -name "${name}" -o -name "${name}.exe" \) -print0
  )

  if [ "${#candidates[@]}" -eq 0 ]; then
    while IFS= read -r -d '' f; do candidates+=("$f"); done < <(
      find "${extract_dir}" -type f -print0
    )
  fi

  if [ "${#candidates[@]}" -ne 1 ]; then
    ui_warn "${name}.zip must contain exactly ONE engine file (named '${name}' or '${name}.exe'). Found: ${#candidates[@]}"
    ui_warn "Files found:"
    (cd "${extract_dir}" && find . -maxdepth 3 -type f -print) >&2 || true
    ui_die "Bad zip format for ${name}"
  fi

  printf "%s\n" "${candidates[0]}"
}

copy_engines_from_wix_to_vm() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"
  local remote_home="/home/${REMOTE_USER}"

  ensure_local_tools_for_zip

  ui_step "[10/11] Finalizing setup — Uploading engines"

  for name in "${ENGINE_NAMES[@]}"; do
    local dst="${remote_home}/${name}"

    # ✅ FIRST check remote; if present, skip without downloading
    if ssh -i "${key_path}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      "${REMOTE_USER}@${ip}" "test -f '$dst'" >/dev/null 2>&1; then
      ui_ok "${name} already present; skipping"
      continue
    fi

    # Only download if we actually need to upload
    local url
    url="$(zip_url_for_engine "$name")"
    [ -n "${url}" ] || ui_die "No URL set for ${name}"

    local workdir
    workdir="$(mktemp -d 2>/dev/null || mktemp -d -t algora1_zipwork)"

    local exe_path
    exe_path="$(download_and_extract_single_exe "${name}" "${url}" "${workdir}")"

    ui_spin "Uploading ${name}…" scp -q -i "${key_path}" -o StrictHostKeyChecking=accept-new \
      "${exe_path}" "${REMOTE_USER}@${ip}:${dst}" \
      || ui_die "Failed to upload ${name} to VM"

    ssh -i "${key_path}" -o StrictHostKeyChecking=accept-new \
      "${REMOTE_USER}@${ip}" "chmod +x '${dst}'" >/dev/null 2>&1 || true

    rm -rf "${workdir}" >/dev/null 2>&1 || true

    ui_ok "${name} uploaded"
  done

  ui_ok "Engine transfer complete"
}

# =========================
# CONFIG
# =========================
CFG_DIR="${HOME}/.config/algora1_setup"
CFG_FILE="${CFG_DIR}/config.env"

ensure_cfg_loaded() {
  mkdir -p "${CFG_DIR}"
  chmod 700 "${CFG_DIR}"
  if [ -f "${CFG_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${CFG_FILE}"
  fi
}

save_cfg() {
  umask 077
  mkdir -p "${CFG_DIR}"
  chmod 700 "${CFG_DIR}"
  cat > "${CFG_FILE}" <<EOF
# algora1_setup persisted config (keep private)
PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-}"
ZONE="${ZONE:-}"
MACHINE_TYPE="${MACHINE_TYPE:-}"
REMOTE_USER="${REMOTE_USER:-}"
ALPACA_LIVE_API_KEY="${ALPACA_LIVE_API_KEY:-}"
ALPACA_LIVE_SECRET_KEY="${ALPACA_LIVE_SECRET_KEY:-}"
ALPACA_PAPER_API_KEY="${ALPACA_PAPER_API_KEY:-}"
ALPACA_PAPER_SECRET_KEY="${ALPACA_PAPER_SECRET_KEY:-}"
EOF
  chmod 600 "${CFG_FILE}"
}

# =========================
# GCLOUD
# =========================
install_gcloud_macos() {
  ui_info "Installing Google Cloud SDK (gcloud) on macOS…"
  need_cmd brew || ui_die "Homebrew not found. Install Homebrew, or install gcloud manually: https://cloud.google.com/sdk/docs/install"
  brew update >/dev/null
  brew install --cask google-cloud-sdk
  if [ -f "$(brew --prefix)/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/path.bash.inc" ]; then
    # shellcheck disable=SC1090
    source "$(brew --prefix)/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/path.bash.inc"
  fi
}

install_gcloud_linux() {
  ui_info "Installing Google Cloud SDK (gcloud) on Linux…"
  if need_cmd apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y apt-transport-https ca-certificates gnupg curl
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y google-cloud-cli
  elif need_cmd yum; then
    sudo tee /etc/yum.repos.d/google-cloud-sdk.repo >/dev/null <<'EOF'
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
    sudo yum install -y google-cloud-cli
  else
    ui_die "No supported package manager found (apt-get/yum). Install gcloud manually: https://cloud.google.com/sdk/docs/install"
  fi
}

ensure_gcloud() {
  if need_cmd gcloud; then
    ui_ok "gcloud detected"
    return
  fi
  if [ "$(detect_os)" = "macos" ]; then
    ui_spin "Installing gcloud…" install_gcloud_macos
  else
    ui_spin "Installing gcloud…" install_gcloud_linux
  fi
  need_cmd gcloud || ui_die "gcloud install finished but 'gcloud' not found in PATH."
  ui_ok "gcloud installed"
}

ensure_gcloud_auth() {
  local active
  active="$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)"
  if [ -n "${active}" ]; then
    ui_ok "Authenticated as ${active}"
    GCLOUD_ACCOUNT="${active}"
    return
  fi

  ui_step "[2/11] Google account authentication"
  ui_info "Launching browser login…"
  if ! gcloud auth login --quiet --verbosity=error >/dev/null 2>&1; then
    ui_die "gcloud auth login failed."
  fi

  active="$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)"
  [ -n "${active}" ] || ui_die "Login succeeded but no active account found."
  GCLOUD_ACCOUNT="${active}"
  ui_ok "Authenticated as ${active}"
}

project_exists() {
  local project_id="$1"
  gcloud projects describe "${project_id}" --format="value(projectId)" >/dev/null 2>&1
}

list_accessible_projects() {
  gcloud projects list --format="value(projectId)" 2>/dev/null | sed '/^\s*$/d' || true
}

set_project() {
  local pid="$1"
  gcloud config set project "${pid}" >/dev/null 2>&1
  PROJECT_ID="${pid}"
}

# =========================
# PROJECT ID VALIDATION
# =========================
print_project_id_requirements() {
  if ui_has_gum; then
    gum style --border rounded --padding "1 2" --border-foreground 214 \
      "$(printf "Project ID requirements:\n• Lowercase\n• Alphanumeric + dashes only\n• Max length 30\n• Cannot start/end with dash")" >&2
  else
    warn "Project ID requirements:"
    warn "• Lowercase"
    warn "• Alphanumeric + dashes only"
    warn "• Max length 30"
    warn "• Cannot start/end with dash"
  fi
}

validate_project_id() {
  local pid="$1"

  if [ -z "${pid}" ]; then
    printf "Project ID cannot be empty.\n" >&2
    return 1
  fi

  if [ "${#pid}" -gt 30 ]; then
    printf "Project ID too long (%d). Max length is 30.\n" "${#pid}" >&2
    return 1
  fi

  if [[ "${pid}" =~ [A-Z] ]]; then
    printf "Project ID must be lowercase.\n" >&2
    return 1
  fi

  if ! [[ "${pid}" =~ ^[a-z0-9-]+$ ]]; then
    printf "Project ID may only contain lowercase letters, numbers, and dashes.\n" >&2
    return 1
  fi

  if [[ "${pid}" =~ ^- ]] || [[ "${pid}" =~ -$ ]]; then
    printf "Project ID cannot start or end with a dash.\n" >&2
    return 1
  fi

  return 0
}

random_suffix6() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6 || true; }

auto_suffix_project_id() {
  local base="$1"
  local suf
  suf="$(random_suffix6)"
  [ -n "$suf" ] || suf="000000"
  local candidate="${base}-${suf}"
  if [ "${#candidate}" -gt 30 ]; then
    local max_base=$((30 - 1 - 6))
    candidate="${base:0:${max_base}}-${suf}"
    candidate="${candidate%-}"
  fi
  printf "%s\n" "$candidate"
}

ensure_project_id_tui() {
  ui_step "[3/11] Google Cloud project"

  if [ -n "${PROJECT_ID:-}" ] && project_exists "${PROJECT_ID}"; then
    set_project "${PROJECT_ID}"
    ui_ok "Using saved project: ${PROJECT_ID}"
    return
  fi

  local current
  current="$(gcloud config get-value project 2>/dev/null || true)"
  if [ -n "${current}" ] && [ "${current}" != "(unset)" ] && project_exists "${current}"; then
    set_project "${current}"
    ui_ok "Using gcloud configured project: ${PROJECT_ID}"
    return
  fi

  local projects count
  projects="$(list_accessible_projects)"
  count="$(printf "%s\n" "${projects}" | sed '/^\s*$/d' | wc -l | tr -d ' ')"

  if [ -n "${projects}" ] && [ "${count}" = "1" ]; then
    local only
    only="$(printf "%s\n" "${projects}" | head -n 1)"
    set_project "${only}"
    ui_ok "Found one project: ${PROJECT_ID}"
    return
  fi

  if [ -n "${projects}" ] && [ "${count}" -gt 1 ]; then
    if ui_has_gum; then
      local chosen
      chosen="$(printf "%s\n" "${projects}" | gum choose --header "Select a GCP PROJECT_ID to use")"
      [ -n "${chosen}" ] || ui_die "No project selected."
      project_exists "${chosen}" || ui_die "Project '${chosen}' not found / no access."
      set_project "${chosen}"
      ui_ok "Selected project: ${PROJECT_ID}"
      return
    else
      ui_warn "Multiple projects found:"
      printf "%s\n" "${projects}" >&2
      local pid
      pid="$(ui_input "Enter GCP PROJECT_ID to use:")"
      project_exists "${pid}" || ui_die "Project '${pid}' not found / no access."
      set_project "${pid}"
      ui_ok "Selected project: ${PROJECT_ID}"
      return
    fi
  fi

  ui_warn "No Google Cloud projects found for this account."
  print_project_id_requirements

  while true; do
    local pid
    pid="$(ui_input "Enter a new PROJECT_ID:")"
    pid="$(printf "%s" "$pid" | tr -d '[:space:]')"

    if ! validate_project_id "${pid}"; then
      print_project_id_requirements
      ui_warn "Please try again."
      continue
    fi

    if project_exists "${pid}"; then
      set_project "${pid}"
      ui_ok "Project already exists; using: ${PROJECT_ID}"
      return
    fi

    ui_spin "Creating project '${pid}'…" gcloud projects create "${pid}" --name="algora1" --quiet --verbosity=error
    if project_exists "${pid}"; then
      set_project "${pid}"
      ui_ok "Project created: ${PROJECT_ID}"
      return
    fi

    ui_warn "Failed to create '${pid}'. It may be taken, restricted, or blocked by org policy."
    print_project_id_requirements

    local action
    action="$(ui_choose "How would you like to proceed?" \
      "Try a different PROJECT_ID" \
      "Auto-fix with random suffix" \
      "Exit")"

    case "$action" in
      "Try a different PROJECT_ID") continue ;;
      "Auto-fix with random suffix")
        local candidate
        candidate="$(auto_suffix_project_id "${pid}")"
        ui_info "Trying: ${candidate}"
        if ! validate_project_id "${candidate}"; then
          ui_warn "Auto-generated ID invalid; trying again."
          continue
        fi
        ui_spin "Creating project '${candidate}'…" gcloud projects create "${candidate}" --name="algora1" --quiet --verbosity=error
        if project_exists "${candidate}"; then
          set_project "${candidate}"
          ui_ok "Project created: ${PROJECT_ID}"
          return
        fi
        ui_warn "Auto-fix attempt failed too. Try again."
        ;;
      *) ui_die "Setup cancelled." ;;
    esac
  done
}

# =========================
# BILLING + COMPUTE API ENABLE
# =========================
billing_is_enabled() {
  local project_id="$1"
  local enabled
  enabled="$(gcloud billing projects describe "${project_id}" --format="value(billingEnabled)" 2>/dev/null || true)"
  enabled="$(echo "${enabled}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [ "${enabled}" = "true" ]
}

compute_enable_url() {
  local project_id="$1"
  printf "https://console.cloud.google.com/marketplace/product/google/compute.googleapis.com?project=%s&returnUrl=%%2Fcompute%%2Finstances%%3Fproject%%3D%s\n" \
    "${project_id}" "${project_id}"
}

billing_link_url() {
  local project_id="$1"
  printf "https://console.cloud.google.com/billing/linkedaccount?project=%s\n" "${project_id}"
}

ensure_billing_linked_interactive() {
  ui_step "[4/11] Billing check"

  if billing_is_enabled "${PROJECT_ID}"; then
    ui_ok "Billing linked"
    return
  fi

  while ! billing_is_enabled "${PROJECT_ID}"; do
    if ui_has_gum; then
      gum style --border rounded --padding "1 2" --border-foreground 214 \
        "$(printf "Billing is not linked to this project.\n\n1) Link billing:\n%s\n\nAfter linking billing, press Enter to continue." "$(billing_link_url "${PROJECT_ID}")")" >&2
      gum input --prompt "Press Enter to re-check: " --value "" >/dev/null
    else
      ui_warn "Billing is not linked to this project."
      printf "1) Link billing:\n%s\n\n" "$(billing_link_url "${PROJECT_ID}")" >&2
      printf "Press Enter to re-check…" >&2
      read -r _ || true
    fi
  done

  ui_ok "Billing linked"
}

active_gcloud_account() { gcloud config get-value account 2>/dev/null || true; }

is_service_enabled() {
  local svc="$1"
  gcloud services list --enabled --project "${PROJECT_ID}" --format="value(config.name)" 2>/dev/null | grep -qx "${svc}"
}

ensure_compute_api_enabled_interactive() {
  ui_step "[5/11] Enabling Compute Engine API"

  if is_service_enabled "compute.googleapis.com"; then
    ui_ok "Compute Engine API already enabled"
    return
  fi

  if ui_has_gum; then
    if gum spin --spinner dot --title "Enabling compute.googleapis.com…" -- \
      gcloud services enable compute.googleapis.com --project "${PROJECT_ID}" --quiet >/dev/null 2>&1; then
      ui_ok "compute.googleapis.com enabled"
      return
    fi
  else
    if gcloud services enable compute.googleapis.com --project "${PROJECT_ID}" --quiet >/dev/null 2>&1; then
      ui_ok "compute.googleapis.com enabled"
      return
    fi
  fi

  local acct
  acct="$(active_gcloud_account)"
  [ -n "${acct}" ] && [ "${acct}" != "(unset)" ] || ui_die "No gcloud account set."

  ui_info "Attempting to self-grant permissions (service usage / compute)…"

  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="user:${acct}" \
    --role="roles/serviceusage.serviceUsageAdmin" \
    --quiet >/dev/null 2>&1 || true

  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="user:${acct}" \
    --role="roles/compute.admin" \
    --quiet >/dev/null 2>&1 || true

  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="user:${acct}" \
    --role="roles/iam.serviceAccountUser" \
    --quiet >/dev/null 2>&1 || true

  local ok=0
  for _ in {1..12}; do
    if gcloud services enable compute.googleapis.com --project "${PROJECT_ID}" --quiet >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 5
  done

  if [ "${ok}" = "1" ] && is_service_enabled "compute.googleapis.com"; then
    ui_ok "compute.googleapis.com enabled"
    return
  fi

  ui_warn "Could not enable compute.googleapis.com automatically."
  if ui_has_gum; then
    gum style --border rounded --padding "1 2" --border-foreground 214 \
      "$(printf "Enable Compute Engine API in the browser:\n%s\n\nThen press Enter to re-check." "$(compute_enable_url "${PROJECT_ID}")")" >&2
    gum input --prompt "Press Enter to re-check: " --value "" >/dev/null
  else
    printf "Enable Compute Engine API:\n%s\n" "$(compute_enable_url "${PROJECT_ID}")" >&2
    printf "Press Enter to re-check…" >&2
    read -r _ || true
  fi

  is_service_enabled "compute.googleapis.com" || ui_die "Compute Engine API still not enabled."
  ui_ok "compute.googleapis.com enabled"
}

# =========================
# DEFAULTS + SSH KEY
# =========================
ensure_defaults() {
  REGION="${REGION:-$REGION_DEFAULT}"
  ZONE="${ZONE:-$ZONE_DEFAULT}"
  MACHINE_TYPE="${MACHINE_TYPE:-$MACHINE_TYPE_DEFAULT}"
  REMOTE_USER="${REMOTE_USER:-$USER}"
}

ensure_ssh_key() {
  ui_step "[1/11] Preparing environment"

  need_cmd curl  && ui_ok "curl detected"  || ui_die "curl is required but not found"
  need_cmd unzip && ui_ok "unzip detected" || ui_die "unzip is required but not found"

  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  local key_path="${HOME}/.ssh/${KEY_NAME}"
  local pub_path="${key_path}.pub"

  if [ -f "$key_path" ] && [ -f "$pub_path" ]; then
    ui_ok "SSH key ready"
    return
  fi

  ui_spin "Generating SSH key…" ssh-keygen -t ed25519 -f "$key_path" -N "" -C "${REMOTE_USER}"
  chmod 600 "$key_path"
  chmod 644 "$pub_path"
  ui_ok "SSH key generated"
}

# =========================
# VM
# =========================
instance_exists() {
  gcloud compute instances describe "${INSTANCE_NAME}" --zone "${ZONE}" >/dev/null 2>&1
}

create_instance_if_needed() {
  ui_step "[7/11] Provisioning virtual machine"

  if instance_exists; then
    ui_ok "Instance already exists: ${INSTANCE_NAME} (${ZONE})"
    return
  fi

  local key_pub="${HOME}/.ssh/${KEY_NAME}.pub"
  local ssh_metadata
  ssh_metadata="${REMOTE_USER}:$(cat "$key_pub")"

  ui_spin "Creating VM '${INSTANCE_NAME}'…" gcloud compute instances create "${INSTANCE_NAME}" \
    --zone "${ZONE}" \
    --machine-type "${MACHINE_TYPE}" \
    --image-family "${IMAGE_FAMILY}" \
    --image-project "${IMAGE_PROJECT}" \
    --metadata "ssh-keys=${ssh_metadata}" \
    --tags "ssh" \
    --quiet

  ui_ok "Instance created"
}

get_instance_ip() {
  gcloud compute instances describe "${INSTANCE_NAME}" \
    --zone "${ZONE}" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
}

wait_for_instance_running() {
  ui_info "Waiting for instance to be RUNNING…"
  local status=""
  for _ in {1..120}; do
    status="$(gcloud compute instances describe "${INSTANCE_NAME}" --zone "${ZONE}" --format="get(status)" 2>/dev/null || true)"
    if [ "${status}" = "RUNNING" ]; then
      ui_ok "Instance status: RUNNING"
      return 0
    fi
    sleep 5
  done
  ui_die "Instance never reached RUNNING status."
}

wait_for_ssh_ready() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"

  ui_info "Waiting for SSH…"
  for _ in {1..120}; do
    if ssh -i "${key_path}" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "${REMOTE_USER}@${ip}" "echo ok" >/dev/null 2>&1; then
      ui_ok "SSH ready"
      return 0
    fi
    sleep 5
  done
  ui_die "SSH never became ready."
}

# =========================
# CREDENTIALS
# =========================
ensure_credentials_tui() {
  ui_step "[8/11] Alpaca configuration"

  if [ -n "${ALPACA_LIVE_API_KEY:-}" ] && [ -n "${ALPACA_LIVE_SECRET_KEY:-}" ] \
     && [ -n "${ALPACA_PAPER_API_KEY:-}" ] && [ -n "${ALPACA_PAPER_SECRET_KEY:-}" ]; then
    ui_ok "Using saved Alpaca credentials"
    return
  fi

  ui_info "Enter Alpaca LIVE credentials (used by BEXP/TSLA/NVDA)."
  ALPACA_LIVE_API_KEY="$(ui_input "ALPACA_LIVE_API_KEY:")"
  ALPACA_LIVE_SECRET_KEY="$(ui_secret "ALPACA_LIVE_SECRET_KEY:")"

  ui_info "Enter Alpaca PAPER credentials (used by PMNY)."
  ALPACA_PAPER_API_KEY="$(ui_input "ALPACA_PAPER_API_KEY:")"
  ALPACA_PAPER_SECRET_KEY="$(ui_secret "ALPACA_PAPER_SECRET_KEY:")"

  [ -n "${ALPACA_LIVE_API_KEY}" ] || ui_die "ALPACA_LIVE_API_KEY cannot be empty."
  [ -n "${ALPACA_LIVE_SECRET_KEY}" ] || ui_die "ALPACA_LIVE_SECRET_KEY cannot be empty."
  [ -n "${ALPACA_PAPER_API_KEY}" ] || ui_die "ALPACA_PAPER_API_KEY cannot be empty."
  [ -n "${ALPACA_PAPER_SECRET_KEY}" ] || ui_die "ALPACA_PAPER_SECRET_KEY cannot be empty."

  ui_ok "Credentials captured"
}

write_exports_on_vm() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"

  ui_step "[9/11] Remote configuration"
  ui_spin "Writing credentials to VM…" ssh -i "${key_path}" -o StrictHostKeyChecking=accept-new \
    "${REMOTE_USER}@${ip}" bash -s -- \
    "${ALPACA_LIVE_API_KEY}" "${ALPACA_LIVE_SECRET_KEY}" \
    "${ALPACA_PAPER_API_KEY}" "${ALPACA_PAPER_SECRET_KEY}" <<'EOF'
set -euo pipefail

ALPACA_LIVE_API_KEY="$1"
ALPACA_LIVE_SECRET_KEY="$2"
ALPACA_PAPER_API_KEY="$3"
ALPACA_PAPER_SECRET_KEY="$4"

touch ~/.bashrc ~/.profile

for f in ~/.bashrc ~/.profile; do
  grep -v '^export ALPACA_LIVE_API_KEY=' "$f" \
    | grep -v '^export ALPACA_LIVE_SECRET_KEY=' \
    | grep -v '^export ALPACA_PAPER_API_KEY=' \
    | grep -v '^export ALPACA_PAPER_SECRET_KEY=' \
    > "${f}.tmp" || true
  mv "${f}.tmp" "$f"
done

for f in ~/.bashrc ~/.profile; do
  cat >> "$f" <<EOT

# --- Alpaca credentials ---
export ALPACA_LIVE_API_KEY="${ALPACA_LIVE_API_KEY}"
export ALPACA_LIVE_SECRET_KEY="${ALPACA_LIVE_SECRET_KEY}"
export ALPACA_PAPER_API_KEY="${ALPACA_PAPER_API_KEY}"
export ALPACA_PAPER_SECRET_KEY="${ALPACA_PAPER_SECRET_KEY}"

EOT
done

EOF

  ui_ok "Credentials written to VM"
}

customize_motd_on_vm() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"

  ui_spin "Customizing VM login banner…" ssh -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new -i "${key_path}" \
    "${REMOTE_USER}@${ip}" "bash -s" <<'EOF'
set -euo pipefail

sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true

sudo tee /etc/update-motd.d/00-algora1-header >/dev/null <<'EOT'
#!/bin/sh

printf "\n"
printf "\033[1mWelcome to algora1\033[0m\n\n"
printf "Company Site :  https://www.algora1.com\n\n"

printf "\033[1mControl Panel\033[0m\n"
printf "Run: \033[38;5;39malgora1\033[0m\n\n"

printf "\033[1mMain Menu\033[0m\n"
printf "  • Running sessions\n"
printf "  • Live portfolio updates\n"
printf "  • Clear log\n"
printf "  • Exit\n\n"

printf "\033[1mOne-session mode:\033[0m only one screen session allowed at a time.\n\n"
EOT

sudo chmod +x /etc/update-motd.d/00-algora1-header
EOF

  ui_ok "Login banner installed"
}

# =========================
# VM CONTROL PANEL (post-connect gum menu)
# =========================
install_control_panel_on_vm() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"

  ui_step "[11/11] Installing Control Panel"

  ui_spin "Installing control panel scripts on VM…" ssh -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new -i "${key_path}" \
    "${REMOTE_USER}@${ip}" "bash -s" <<'EOF'
set -euo pipefail

# ---------- helper: install gum on Ubuntu if missing ----------
has_gum() { command -v gum >/dev/null 2>&1; }

install_gum_if_needed() {
  has_gum && return 0

  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y curl gpg >/dev/null 2>&1 || true
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
    sudo apt-get update -y >/dev/null 2>&1
    sudo apt-get install -y gum >/dev/null 2>&1 || true
  fi

  return 0
}

install_gum_if_needed || true

# ---------- /usr/local/bin/algora1-session (runs INSIDE new screen session) ----------
sudo tee /usr/local/bin/algora1-session >/dev/null <<'SESSION'
#!/usr/bin/env bash
set -euo pipefail

ENGINE_NAMES=( "BEXP" "PMNY" "TSLA" "NVDA" )

has_gum() { command -v gum >/dev/null 2>&1; }

choose() {
  local title="$1"; shift
  if has_gum; then
    gum choose --header "$title" "$@"
  else
    echo "$title"
    local i=1
    for opt in "$@"; do echo "  $i) $opt"; i=$((i+1)); done
    printf "Select [1-%d]: " "$#"
    local n; read -r n; n="${n:-1}"
    echo "${@:n:1}"
  fi
}

ok()   { printf "✓ %s\n" "$*"; }
info() { printf "INFO %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*" >&2; }

engine_running_anywhere() {
  # Detect a running engine process on the VM (best-effort)
  pgrep -af '(^|/)\.(\/)?(BEXP|PMNY|TSLA|NVDA)( |$)' >/dev/null 2>&1 && return 0
  pgrep -af '(^|/)(BEXP|PMNY|TSLA|NVDA)( |$)' >/dev/null 2>&1 && return 0
  return 1
}

run_engine_prompt_if_safe() {
  if engine_running_anywhere; then
    warn "An engine appears to be running already. Skipping engine prompt."
    return 0
  fi

  local action
  action="$(choose "Run investment engine?" "Run investment engine" "Back")"
  [ "$action" = "Run investment engine" ] || return 0

  local engine
  engine="$(choose "Select engine" "${ENGINE_NAMES[@]}")"
  [ -n "$engine" ] || return 0

  ok "Starting ${engine}…"
  chmod +x "./${engine}" >/dev/null 2>&1 || true

  # ✅ Force-load Alpaca env vars no matter how screen/bash started
  [ -f "$HOME/.profile" ] && source "$HOME/.profile" || true
  [ -f "$HOME/.bashrc" ]  && source "$HOME/.bashrc"  || true

  # Optional: fail fast with a clear message
  missing=()
  [ -n "${ALPACA_PAPER_API_KEY:-}" ] || missing+=("ALPACA_PAPER_API_KEY")
  [ -n "${ALPACA_PAPER_SECRET_KEY:-}" ] || missing+=("ALPACA_PAPER_SECRET_KEY")
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "Missing keys in this session: ${missing[*]}"
    warn "Fix: ensure keys exist in ~/.profile or ~/.bashrc for user $(whoami)"
    return 0
  fi

  "./${engine}"
}

# Nice header
if has_gum; then
  gum style --border rounded --padding "1 2" --border-foreground 212 \
    "$(printf "algora1 session\nOne-session mode enabled")"
else
  echo "algora1 session (one-session mode enabled)"
fi

# Only prompt if nothing is running on VM
run_engine_prompt_if_safe || true

# Drop into a normal shell so users can work, detach, etc.
exec bash -l
SESSION

sudo chmod +x /usr/local/bin/algora1-session

# ---------- /usr/local/bin/algora1 (main menu) ----------
sudo tee /usr/local/bin/algora1 >/dev/null <<'MENU'
#!/usr/bin/env bash
set -euo pipefail

ENGINE_NAMES=( "BEXP" "PMNY" "TSLA" "NVDA" )

has_gum() { command -v gum >/dev/null 2>&1; }

choose() {
  local title="$1"; shift
  if has_gum; then
    gum choose --header "$title" "$@"
  else
    echo "$title"
    local i=1
    for opt in "$@"; do echo "  $i) $opt"; i=$((i+1)); done
    printf "Select [1-%d]: " "$#"
    local n; read -r n; n="${n:-1}"
    echo "${@:n:1}"
  fi
}

input() {
  local prompt="$1"
  if has_gum; then
    # UI to stderr, captured value to stdout
    gum input --prompt "$prompt " --placeholder "" --width 40 1>&2
    # ^ gum still returns the typed value on stdout, which the caller captures
  else
    printf "%s " "$prompt" >&2
    local v; read -r v
    echo "$v"
  fi
}

confirm() {
  local prompt="$1"
  if has_gum; then
    gum confirm "$prompt"
  else
    printf "%s [y/N]: " "$prompt"
    local a; read -r a || true
    [[ "$a" =~ ^[Yy]$ ]]
  fi
}

ok()   { printf "✓ %s\n" "$*"; }
info() { printf "INFO %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*" >&2; }

# ---- screen session logic (ONE SESSION ONLY) ----

list_sessions_raw() {
  # screen -ls returns exit code 1 when there are no sockets; don't let set -e kill the menu
  command -v screen >/dev/null 2>&1 || return 0
  screen -ls 2>/dev/null \
    | sed -n 's/^[[:space:]]*\([0-9]\+\.[^[:space:]]\+\)[[:space:]].*$/\1/p' \
    || true
}

session_count() {
  list_sessions_raw | sed '/^\s*$/d' | wc -l | tr -d ' '
}

get_only_session() {
  list_sessions_raw | head -n 1
}

has_any_session() {
  [ "$(session_count)" != "0" ]
}

delete_session() {
  local s="$1"
  [ -n "$s" ] || return 0

  # Quit it
  screen -S "$s" -X quit >/dev/null 2>&1 || true

  # Wait until it actually disappears
  for _ in {1..20}; do
    if ! list_sessions_raw | grep -Fxq "$s"; then
      return 0
    fi
    sleep 0.1
  done
  return 0
}

delete_all_sessions() {
  local s
  while read -r s; do
    [ -n "$s" ] || continue
    delete_session "$s"
  done < <(list_sessions_raw)
}

connect_only_session() {
  local s
  s="$(get_only_session)"
  [ -n "$s" ] || return 1
  exec screen -r "$s"
}

create_new_session() {
  local name="$1"
  screen -S "$name" -dm bash -lc "cd \$HOME && exec /usr/local/bin/algora1-session"
}

engine_running_anywhere() {
  pgrep -af '(^|/)\.(\/)?(BEXP|PMNY|TSLA|NVDA)( |$)' >/dev/null 2>&1 && return 0
  pgrep -af '(^|/)(BEXP|PMNY|TSLA|NVDA)( |$)' >/dev/null 2>&1 && return 0
  return 1
}

# ---- logs ----
log_for_engine() {
  case "$1" in
    BEXP) echo "bexp_investing.log" ;;
    TSLA) echo "tsla_investing.log" ;;
    NVDA) echo "nvda_investing.log" ;;
    PMNY) echo "pmny_investing.log" ;;
    *) echo "bexp_investing.log" ;;
  esac
}

detect_running_engine_best_effort() {
  local line
  line="$(pgrep -af '(BEXP|PMNY|TSLA|NVDA)' 2>/dev/null | head -n 1 || true)"
  case "$line" in
    *BEXP*) echo "BEXP" ;;
    *TSLA*) echo "TSLA" ;;
    *NVDA*) echo "NVDA" ;;
    *PMNY*) echo "PMNY" ;;
    *) echo "" ;;
  esac
}

# ---- UI screens ----
draw_header_once() {
  # Clear once, then draw header once
  clear || true
  if has_gum; then
    gum style --border rounded --padding "1 2" --border-foreground 212 \
      "$(printf "algora1 — Control Panel\nThank you for your support.")"
  else
    echo "algora1 — Control Panel (one-session mode enabled)"
  fi
  echo ""
}

running_sessions_menu() {
  local cnt
  cnt="$(session_count)"

  # If multiple sessions exist (shouldn't), enforce the rule
  if [ "$cnt" -gt 1 ]; then
    warn "Multiple screen sessions detected (${cnt}). One-session mode requires deleting extras."
    if confirm "Delete ALL sessions now? (recommended)"; then
      delete_all_sessions
      ok "All sessions deleted."
    fi
    return 0
  fi

  if [ "$cnt" = "0" ]; then
    local action
    action="$(choose "Running sessions" "Start new session" "Back")"
    [ "$action" = "Start new session" ] || return 0

    # Enforce no session exists
    if has_any_session; then
      warn "A session already exists. Delete it first."
      return 0
    fi

    local name
    echo "" >&2
    name="$(input "Session name (default: investing):")"
    name="${name:-investing}"
    # Basic sanitize
    name="$(echo "$name" | tr -d '[:space:]')"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { warn "Invalid name. Use letters/numbers/_/- only."; return 0; }

    create_new_session "$name"
    ok "Session created: $name"
    ok "Connecting…"
    exec screen -r "$name"
  else
    local s
    s="$(get_only_session)"
    local action
    action="$(choose "Running sessions" "Connect" "Delete session" "Back")"

    case "$action" in
      "Connect")
        exec screen -r "$s"
        ;;
      "Delete session")
        if confirm "Delete session '$s'? This will stop any running engine."; then
          delete_session "$s"
          ok "Session deleted."
        fi
        ;;
      *) return 0 ;;
    esac
  fi
}

live_updates_menu() {
  local eng
  eng="$(detect_running_engine_best_effort || true)"

  local logfile=""
  if [ -n "$eng" ]; then
    logfile="$(log_for_engine "$eng")"
    info "Engine detected: $eng"
  else
    local choice
    choice="$(choose "Live portfolio updates" \
      "bexp_investing.log" \
      "tsla_investing.log" \
      "nvda_investing.log" \
      "pmny_investing.log" \
      "Back")"
    [ "$choice" = "Back" ] && return 0
    logfile="$choice"
  fi

  touch "$logfile" >/dev/null 2>&1 || true
  info "Tailing: $logfile (Ctrl+C to return)"

  # --- KEY FIX: Ctrl+C should only exit tail, not the whole menu ---
  local old_trap
  old_trap="$(trap -p INT || true)"

  # When user presses Ctrl+C, stop tail and return to menu
  trap 'trap - INT; return 0' INT

  tail -f "$logfile"

  # Restore previous INT trap (if any)
  eval "$old_trap" 2>/dev/null || trap - INT

  return 0
}

clear_log_menu() {
  local choice
  choice="$(choose "Clear log" \
    "bexp_investing.log" \
    "tsla_investing.log" \
    "nvda_investing.log" \
    "pmny_investing.log" \
    "Clear all logs" \
    "Back")"

  [ "$choice" = "Back" ] && return 0

  if [ "$choice" = "Clear all logs" ]; then
    if confirm "Clear ALL investing logs?"; then
      : > bexp_investing.log 2>/dev/null || true
      : > tsla_investing.log 2>/dev/null || true
      : > nvda_investing.log 2>/dev/null || true
      : > pmny_investing.log 2>/dev/null || true
      ok "All logs cleared."
    fi
    return 0
  fi

  if confirm "Clear '$choice'?"; then
    : > "$choice" 2>/dev/null || true
    ok "Cleared: $choice"
  fi
}

main_loop() {
  draw_header_once

  while true; do
    local selection
    selection="$(choose "Select an option" \
      "Running sessions" \
      "Live portfolio updates" \
      "Clear log" \
      "Exit")"

    case "$selection" in
      "Running sessions") running_sessions_menu ;;
      "Live portfolio updates") live_updates_menu ;;
      "Clear log") clear_log_menu ;;
      "Exit") exit 0 ;;
      *) exit 0 ;;
    esac
  done
}

main_loop
MENU

sudo chmod +x /usr/local/bin/algora1

# Optional: ensure screen is installed
if ! command -v screen >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y screen >/dev/null 2>&1 || true
  fi
fi

EOF
}

ssh_into_instance_menu() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"
  ui_info "Connecting to VM (control panel)…"
  exec ssh -tt -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new -i "${key_path}" \
    "${REMOTE_USER}@${ip}" "bash -lc 'algora1'"
}

ssh_into_instance() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"

  ui_info "Connecting to VM…"
  exec ssh -tt -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new -i "${key_path}" \
    "${REMOTE_USER}@${ip}"
}

# =========================
# INSTALL PLAN + COMPLETION (list style, no box)
# =========================
install_plan_confirm() {
  ui_step "[6/11] Install plan"

  ui_kv_list \
    "OS" "$(detect_os)" \
    "Project" "${PROJECT_ID}" \
    "Zone" "${ZONE}" \
    "Machine" "${MACHINE_TYPE}" \
    "Engines" "BEXP, TSLA, NVDA, PMNY"

  local choice
  choice="$(ui_choose "Proceed?" "Continue" "Exit")"
  [ "$choice" = "Continue" ] || ui_die "Setup cancelled."
}

completion_screen() {
  local ip="$1"
  ui_step "[11/11] Complete"

  ui_kv_list \
    "Instance" "${INSTANCE_NAME}" \
    "IP" "${ip}" \
    "Project" "${PROJECT_ID}" \
    "Zone" "${ZONE}"

  local choice
  choice="$(ui_choose "What next?" "Connect now (menu)" "Exit")"

  case "$choice" in
    "Connect now (menu)") ssh_into_instance_menu "${ip}" ;;
    *) return 0 ;;
  esac
}

# =========================
# MAIN (full 1–11 flow)
# =========================
main() {
  ensure_gum
  ui_header
  ui_ok "Detected: $(detect_os)"

  ensure_cfg_loaded
  ensure_defaults

  # Ensure local CLI exists + ensure PATH is persisted (macOS)
  if [ "$(detect_os)" = "macos" ]; then
    install_local_cli
  fi



  # macOS Dock app should exist even if we fast-path into SSH later
  if [ "$(detect_os)" = "macos" ]; then
    ensure_macos_app_bundle_present "${ALGORA1_ICNS_PATH:-}" || true
  fi

  ensure_ssh_key
  ensure_gcloud
  ensure_gcloud_auth
  ensure_project_id_tui

  save_cfg

  # ✅ If algora1 already exists, skip installer + jump to menu
  fast_path_to_control_panel_if_ready || true


  ensure_billing_linked_interactive
  ensure_compute_api_enabled_interactive

  install_plan_confirm

  create_instance_if_needed
  wait_for_instance_running

  local ip
  ip="$(get_instance_ip)"
  [ -n "${ip}" ] || ui_die "Could not determine instance external IP."
  ui_ok "Instance external IP: ${ip}"

  ssh-keygen -R "${ip}" >/dev/null 2>&1 || true
  wait_for_ssh_ready "${ip}"

  ensure_credentials_tui
  save_cfg

  write_exports_on_vm "${ip}"
  customize_motd_on_vm "${ip}"

  copy_engines_from_wix_to_vm "${ip}"

  install_control_panel_on_vm "${ip}"

  completion_screen "${ip}"
}

main "$@"

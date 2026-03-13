#!/usr/bin/env bash
set -euo pipefail

export CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=1
export CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=1

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
    BEXP) echo "https://ce61ee09-0950-4d0d-b651-266705220b65.usrfiles.com/archives/ce61ee_807b8251b3bb4466903ad79cd5bfc35f.zip" ;;
    PMNY) echo "https://ce61ee09-0950-4d0d-b651-266705220b65.usrfiles.com/archives/ce61ee_766baefbee404509ae8b9641a31d897f.zip" ;;
    TSLA) echo "https://ce61ee09-0950-4d0d-b651-266705220b65.usrfiles.com/archives/ce61ee_a96cfb23e9f046039264fa9cd2b4cd24.zip" ;;
    NVDA) echo "https://ce61ee09-0950-4d0d-b651-266705220b65.usrfiles.com/archives/ce61ee_0df494b5a31b4706a9844b64474d5df8.zip" ;;
    *) echo "" ;;
  esac
}

CFG_DIR="${HOME}/.config/algora1_setup"
CFG_FILE="${CFG_DIR}/config.env"

QUIET="${QUIET:-1}"

log()  { printf "\033[1;32m[ALGORA1]\033[0m %s\n" "$*" >&2; }
logq() { [ "${QUIET}" = "1" ] || log "$@"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[error]\033[0m %s\n" "$*" >&2; exit 1; }

print_engine_blurbs() {
  cat >&2 <<'EOT'
BEXP — Diversified Tesla and NVIDIA engine with real-time risk controls.

TSLA — Tesla engine with signal-based deployment and downside controls.

NVDA — NVIDIA engine with signal-based deployment and downside controls.

PMNY — Paper-trading BEXP for risk-free testing.

EOT
}

C_ACCENT=39      
C_CURSOR=33      
C_OK=40          
C_WARN=136      
C_ERR=196        
C_MUTED=245      

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

set_term_title() {

  printf '\033]0;%s\007' "$1"
}

stat_size_bytes() {
  if [ -f "$1" ]; then
    if stat -f%z "$1" >/dev/null 2>&1; then
      stat -f%z "$1"
    else
      stat -c%s "$1" 2>/dev/null || echo 0
    fi
  else
    echo 0
  fi
}

get_content_length() {
  local url="$1"
  local cl=""
  cl="$(curl -fsSLI "$url" 2>/dev/null | awk -F': ' 'tolower($1)=="content-length"{gsub("\r","",$2); print $2}' | tail -n 1)"
  case "$cl" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$cl" ;;
  esac
}

render_bar() {
  local pct="$1"
  local width="${2:-24}"

  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100

  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))

  local bar=""
  [ "$filled" -gt 0 ] && bar="$(printf '%0.s█' $(seq 1 "$filled"))"
  [ "$empty"  -gt 0 ] && bar="${bar}$(printf '%0.s░' $(seq 1 "$empty"))"

  printf "[%s] %3d%%" "$bar" "$pct"
}

download_file_with_progress() {
  local label="$1"
  local url="$2"
  local out="$3"

  need_cmd curl || ui_die "curl is required but not found."

  rm -f "$out" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$out")"

  local total
  total="$(get_content_length "$url" || true)"

  curl -fL --retry 3 --retry-delay 1 -o "$out" -sS "$url" &
  local pid=$!

  local width=24

  while kill -0 "$pid" >/dev/null 2>&1; do
    local got pct line
    got="$(stat_size_bytes "$out")"

    if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
      pct=$(( got * 100 / total ))
      line="${label} $(render_bar "$pct" "$width")"
    else
      local t=$(( (got / 262144) % (width+1) ))
      local bar="$(printf '%0.s█' $(seq 1 "$t" 2>/dev/null || true))"
      local pad=$(( width - t )); [ "$pad" -lt 0 ] && pad=0
      bar="${bar}$(printf '%0.s░' $(seq 1 "$pad" 2>/dev/null || true))"
      line="${label} [${bar}]"
    fi

    printf "\r\033[K%s" "$line" >&2
    sleep 0.1 || true
  done

  wait "$pid"
  local rc=$?

  [ "$rc" -eq 0 ] || ui_die "Failed to download from ${url}"
  [ -s "$out" ] || ui_die "Download completed but file is empty: $out"

  if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
    printf "\r\033[K%s %s" "$label" "$(render_bar 100 "$width")" >&2
  else
    printf "\r\033[K%s [done]" "$label" >&2
  fi

  printf "\n" >&2
}

ui_has_gum() { need_cmd gum; }

ui_header() {
  if ui_has_gum; then
    gum style --border rounded --padding "1 2" --margin "0 0 1 0" \
      --border-foreground ${C_ACCENT} \
      "$(printf "ALGORA1 Software\nAutomated investment engine deployment.\nModern Terminal UI")" >&2
  else
    log "ALGORA1 Software"
    log "Automated investment engine deployment."
  fi
}

session_pretty_name() {
  local raw="${1:-}"
  raw="${raw##*/}"
  echo "${raw#*.}"
}

ui_step() {
  local label="$1"
  if ui_has_gum; then
    gum style --bold --foreground ${C_ACCENT} "$label" >&2
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
    gum style --foreground ${C_MUTED} "INFO $msg" >&2
  else
    log "INFO $msg"
  fi
}

ui_warn() {
  local msg="$1"
  if ui_has_gum; then
    gum style --foreground ${C_WARN} "WARN $msg" >&2
  else
    warn "$msg"
  fi
}

ui_die() {
  local msg="$1"
  if ui_has_gum; then
    gum style --foreground ${C_ERR} --bold "ERROR $msg" >&2
  else
    die "$msg"
  fi
  exit 1
}

ui_spin() {
  local label="$1"
  shift
  if ui_has_gum; then
    gum spin \
      --spinner dot \
      --spinner.foreground ${C_ACCENT} \
      --title.foreground ${C_ACCENT} \
      --title "$label" -- "$@" >/dev/null 2>&1
  else
    ui_info "$label"
    "$@" >/dev/null 2>&1
  fi
}

ui_choose() {
  local title="$1"; shift
  if ui_has_gum; then
    gum choose \
      --header "$title" \
      --header.foreground ${C_ACCENT} \
      --item.foreground ${C_ACCENT} \
      --selected.foreground ${C_ACCENT} \
      --cursor.foreground ${C_CURSOR} \
      "$@"
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
  printf "%s " "$prompt" >&2
  local v=""
  read -r v || true
  printf "%s\n" "$v"
}

ui_secret() {
  local prompt="$1"
  printf "%s " "$prompt" >&2
  local v=""
  read -r v || true
  printf "%s\n" "$v"
}

ui_kv_list() {
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
  local icon_url="$1"
  local apps_dir="${HOME}/.local/share/applications"
  local icon_dir="${HOME}/.local/share/icons"
  local bin_path="${HOME}/.local/bin/algora1"   

  mkdir -p "$apps_dir" "$icon_dir"

  local icon_path="$icon_dir/algora1.png"
  if [ -n "$icon_url" ]; then
    curl -fsSL "$icon_url" -o "$icon_path" || true
  fi

  cat > "$apps_dir/ALGORA1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ALGORA1
Comment=ALGORA1 control panel
Exec=$bin_path
Terminal=true
Icon=$icon_path
Categories=Finance;Utility;
EOF

  chmod +x "$apps_dir/ALGORA1.desktop"
  ui_ok "Linux shortcut created: $apps_dir/ALGORA1.desktop"
}

install_local_cli() {
  local target_dir="${HOME}/.local/bin"
  mkdir -p "$target_dir"
  chmod 755 "$target_dir"

  local target="$target_dir/algora1"

  if [ "${0##*/}" = "bash" ] || [ "${0##*/}" = "sh" ] || [ ! -f "${0}" ]; then
    : "${ALGORA1_INSTALL_URL:=https://raw.githubusercontent.com/algora01/algora1-installer/main/algora1.sh}"
    need_cmd curl || ui_die "curl is required to install the local command."

    ui_info "Installing local command by downloading from ${ALGORA1_INSTALL_URL}"
    curl -fsSL "${ALGORA1_INSTALL_URL}" -o "${target}" || ui_die "Failed to download installer."
    chmod +x "${target}"
    ui_ok "Installed local command: ${target}"
  else
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

WIX_ICON_PNG_URL="https://static.wixstatic.com/media/ce61ee_00cd47ee0f9c48f69f0f7546f4298188~mv2.png"
GDRIVE_ICNS_FILE_ID="111ErBsF_zrgT6_jpuQERAFCXYPsSgMap"

download_public_gdrive_file() {
  local file_id="$1"
  local out="$2"

  need_cmd curl || return 1

  if curl -fsSL -o "$out" "https://drive.google.com/uc?export=download&id=${file_id}"; then
    [ -s "$out" ] && return 0
  fi

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
  local png="$1"
  local out_icns="$2"

  need_cmd sips     || ui_die "macOS 'sips' not found (unexpected)."
  need_cmd iconutil || ui_die "macOS 'iconutil' not found (unexpected)."

  local tmp
  tmp="$(mktemp -d)"
  local iconset="${tmp}/algora1.iconset"
  mkdir -p "$iconset"

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

  iconutil -c icns "$iconset" -o "$out_icns" >/dev/null
  rm -rf "$tmp"
  [ -s "$out_icns" ]
}

ensure_algora1_icns() {
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

  if [ -n "${GDRIVE_ICNS_FILE_ID:-}" ]; then
    if download_public_gdrive_file "$GDRIVE_ICNS_FILE_ID" "$cfg_icns"; then
      echo "$cfg_icns"; return 0
    fi
  fi

  local tmp_png
  tmp_png="$(mktemp -t algora1_icon.XXXXXX).png"
  if curl -fsSL "$WIX_ICON_PNG_URL" -o "$tmp_png"; then
    if png_to_icns_macos "$tmp_png" "$cfg_icns"; then
      rm -f "$tmp_png" || true
      echo "$cfg_icns"; return 0
    fi
  fi
  rm -f "$tmp_png" || true

  echo ""
  return 1
}

ALGORA1_BUNDLE_ID="com.algora1.launcher"

is_trusted_algora1_app_bundle() {
  local app_root="$1"
  local plist="${app_root}/Contents/Info.plist"
  local exe="${app_root}/Contents/MacOS/algora1"
  local marker="${app_root}/Contents/Resources/.algora1_generated"

  [ -d "$app_root" ] || return 1
  [ -f "$plist" ] || return 1
  [ -x "$exe" ] || return 1
  [ -f "$marker" ] || return 1

  local bid
  bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  [ "$bid" = "$ALGORA1_BUNDLE_ID" ] || return 1

  local bexe
  bexe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
  [ "$bexe" = "algora1" ] || return 1

  grep -q 'do script "algora1"' "$exe" 2>/dev/null || return 1

  return 0
}

ensure_macos_app_bundle_present() {
  local icns_path="${1:-}"
  local app_root="${HOME}/Applications/ALGORA1.app"
  local desktop_app="${HOME}/Desktop/ALGORA1.app"

  if is_trusted_algora1_app_bundle "$app_root"; then
    ui_ok "macOS app bundle present: $app_root"
    return 0
  fi

  if is_trusted_algora1_app_bundle "$desktop_app"; then
    ui_ok "macOS app bundle present: $desktop_app"
    return 0
  fi

  ui_info "Creating macOS Dock app (ALGORA1.app)…"
  install_macos_app_bundle "$icns_path"

  if ! is_trusted_algora1_app_bundle "$app_root"; then
    ui_warn "App bundle creation ran, but bundle did not validate. Check permissions: ~/Applications"
    return 1
  fi

  if ! is_trusted_algora1_app_bundle "$desktop_app"; then
    cp -R "$app_root" "$desktop_app" >/dev/null 2>&1 || true
  fi

  return 0
}

install_macos_app_bundle() {

  local icns_path="${1:-}" 
  local app_root="${HOME}/Applications/ALGORA1.app"
  local contents="${app_root}/Contents"
  local macos_dir="${contents}/MacOS"
  local res_dir="${contents}/Resources"

  mkdir -p "${macos_dir}" "${res_dir}"

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
  <key>CFBundleName</key><string>ALGORA1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
</dict>
</plist>
EOF

  printf "APPL????" > "${contents}/PkgInfo" || true

  local resolved_icns=""
  resolved_icns="$(ensure_algora1_icns "${icns_path:-}" || true)"
  if [ -n "$resolved_icns" ] && [ -f "$resolved_icns" ]; then
    cp "$resolved_icns" "${res_dir}/algora1.icns"
  fi

  printf "generated-by=algora1-installer\n" > "${res_dir}/.algora1_generated" || true

  ui_ok "macOS app created: ${app_root}"
  ui_info "Tip: drag 'ALGORA1' into your Dock. First run may require right-click → Open."

  open -R "${app_root}" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--install-local" ]; then
  ensure_gum || true
  ui_header
  install_local_cli

  if [ "$(detect_os)" = "linux" ]; then
    install_linux_desktop_shortcut "https://static.wixstatic.com/media/ce61ee_00cd47ee0f9c48f69f0f7546f4298188~mv2.png"
  fi

  if [ "$(detect_os)" = "macos" ]; then
    install_macos_app_bundle "${ALGORA1_ICNS_PATH:-}"
  fi

  exit 0
fi

fast_path_to_control_panel_if_ready() {
  instance_exists || return 1

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

  local key_path="${HOME}/.ssh/${KEY_NAME}"
  ui_info "Updating control panel on VM…"
  install_control_panel_on_vm "${ip}"


  if [ "$(detect_os)" = "macos" ]; then
    ensure_macos_app_bundle_present "${ALGORA1_ICNS_PATH:-}" || true
  fi

  ui_info "Launching control panel…"
  ssh_into_instance_menu "${ip}"
}

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

  download_file_with_progress "Downloading ${name}.zip" "${url}" "${zip_path}"

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

  ui_step "[10/12] Finalizing setup — Uploading engines"

  for name in "${ENGINE_NAMES[@]}"; do
    local dst="${remote_home}/${name}"

    if ssh -i "${key_path}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      "${REMOTE_USER}@${ip}" "test -f '$dst'" >/dev/null 2>&1; then
      ui_ok "${name} already present; skipping"
      continue
    fi

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

CFG_DIR="${HOME}/.config/algora1_setup"
CFG_FILE="${CFG_DIR}/config.env"

ensure_cfg_loaded() {
  mkdir -p "${CFG_DIR}"
  chmod 700 "${CFG_DIR}"
  if [ -f "${CFG_FILE}" ]; then
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

install_gcloud_macos() {
  ui_info "Installing Google Cloud SDK (gcloud) on macOS…"
  need_cmd brew || ui_die "Homebrew not found. Install Homebrew, or install gcloud manually: https://cloud.google.com/sdk/docs/install"
  brew update >/dev/null
  brew install --cask google-cloud-sdk
  if [ -f "$(brew --prefix)/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/path.bash.inc" ]; then
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

  ui_step "[2/12] Google account authentication"
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

print_project_id_requirements() {
  if ui_has_gum; then
    gum style --border rounded --padding "1 2" --border-foreground ${C_WARN} \
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
  ui_step "[3/12] Google Cloud project"

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
  ui_step "[4/12] Billing check"

  if billing_is_enabled "${PROJECT_ID}"; then
    ui_ok "Billing linked"
    return
  fi

  while ! billing_is_enabled "${PROJECT_ID}"; do
    if ui_has_gum; then
      gum style --border rounded --padding "1 2" --border-foreground ${C_WARN} \
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
  ui_step "[5/12] Enabling Compute Engine API"

  if is_service_enabled "compute.googleapis.com"; then
    ui_ok "Compute Engine API already enabled"
    return
  fi

  if ui_has_gum; then
    if ui_spin "Enabling compute.googleapis.com…" \
      gcloud services enable compute.googleapis.com --project "${PROJECT_ID}" --quiet; then
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
    gum style --border rounded --padding "1 2" --border-foreground ${C_WARN} \
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

ensure_defaults() {
  REGION="${REGION:-$REGION_DEFAULT}"
  ZONE="${ZONE:-$ZONE_DEFAULT}"
  MACHINE_TYPE="${MACHINE_TYPE:-$MACHINE_TYPE_DEFAULT}"
  REMOTE_USER="${REMOTE_USER:-$USER}"
}

ensure_ssh_key() {
  ui_step "[1/12] Preparing environment"

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

instance_exists() {
  gcloud compute instances describe "${INSTANCE_NAME}" --zone "${ZONE}" >/dev/null 2>&1
}

create_instance_if_needed() {
  ui_step "[7/12] Provisioning virtual machine"

  if instance_exists; then
    ui_ok "Instance already exists: ${INSTANCE_NAME} (${ZONE})"
    return
  fi

  local key_pub="${HOME}/.ssh/${KEY_NAME}.pub"
  local ssh_metadata
  ssh_metadata="${REMOTE_USER}:$(cat "$key_pub")"

  ui_info "Creating VM '${INSTANCE_NAME}' in ${ZONE}…"
  local create_err
  create_err="$(mktemp)"
  if ! gcloud compute instances create "${INSTANCE_NAME}" \
    --zone "${ZONE}" \
    --machine-type "${MACHINE_TYPE}" \
    --image-family "${IMAGE_FAMILY}" \
    --image-project "${IMAGE_PROJECT}" \
    --metadata "ssh-keys=${ssh_metadata}" \
    --tags "ssh" \
    --quiet \
    >/dev/null 2>"${create_err}"; then
    ui_warn "VM provisioning failed at [7/12]."
    if [ -s "${create_err}" ]; then
      ui_warn "gcloud error:"
      sed -n '1,20p' "${create_err}" >&2 || true
    fi
    rm -f "${create_err}" >/dev/null 2>&1 || true
    ui_die "Could not create VM. Check quota, zone capacity, machine type, and billing."
  fi
  rm -f "${create_err}" >/dev/null 2>&1 || true

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

ensure_credentials_tui() {
  ui_step "[8/12] Alpaca configuration"

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

  ui_step "[9/12] Remote configuration"
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
printf "\033[1mWelcome to ALGORA1\033[0m\n\n"
printf "Company Site :  https://www.algora1.com\n\n"

printf "\033[1mControl Panel\033[0m\n"
printf "Run: \033[38;5;39malgora1\033[0m\n\n"

printf "\033[1mMain Menu\033[0m\n"
printf "  • Running session\n"
printf "  • Live Status\n"
printf "  • Live Charts\n"
printf "  • Exit\n\n"

printf "\033[1mOne-session mode:\033[0m only one screen session allowed at a time.\n\n"
EOT

sudo chmod +x /etc/update-motd.d/00-algora1-header
EOF

  ui_ok "Login banner installed"
}

install_control_panel_on_vm() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"

  ui_step "[11/12] Installing Control Panel"

  ui_spin "Installing control panel scripts on VM…" ssh -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new -i "${key_path}" \
    "${REMOTE_USER}@${ip}" "bash -s" <<'REMOTE_INSTALL_EOF'
set -euo pipefail

has_gum() { command -v gum >/dev/null 2>&1; }

hard_clear() {
  printf '\033[?25l\033[H\033[2J\033[3J' 2>/dev/null || true
}

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

sudo tee /usr/local/bin/algora1-session >/dev/null <<'SESSION'
#!/usr/bin/env bash
set -euo pipefail

case "${TERM:-}" in
  screen|screen-bce) export TERM="screen-256color" ;;
esac

ENGINE_NAMES=( "BEXP" "PMNY" "TSLA" "NVDA" )

has_gum() { command -v gum >/dev/null 2>&1; }

print_engine_blurbs() {
  cat >&2 <<'EOT'
BEXP — Diversified Tesla and NVIDIA engine with real-time risk controls.

TSLA — Tesla engine with signal-based deployment and downside controls.

NVDA — NVIDIA engine with signal-based deployment and downside controls.

PMNY — Paper-trading BEXP for risk-free testing.

EOT
}

choose() {
  local title="$1"; shift
  if has_gum; then
    local h=18
    local lines=""
    if command -v tput >/dev/null 2>&1; then
      lines="$(tput lines 2>/dev/null || true)"
      if [ -n "${lines}" ] && [ "${lines}" -gt 10 ] 2>/dev/null; then
        h=$((lines - 6))
      fi
    fi

    # Pin navigation hint to terminal bottom; hide gum's built-in help line.
    if [ -n "${lines}" ] && [ "${lines}" -gt 1 ] 2>/dev/null; then
      tput sc 1>&2 2>/dev/null || true
      tput cup $((lines - 1)) 0 1>&2 2>/dev/null || true
      printf '\033[2K\033[38;5;245m←↓↑→ navigate • enter submit\033[0m' >&2
      tput rc 1>&2 2>/dev/null || true
    fi

    gum choose \
      --header "$title" \
      --header.foreground 39 \
      --item.foreground 39 \
      --selected.foreground 231 \
      --selected.background 39 \
      --cursor.foreground 33 \
      --height "${h}" \
      --no-show-help \
      "$@"
  else
    echo "$title" >&2
    local i=1
    for opt in "$@"; do echo "  $i) $opt" >&2; i=$((i+1)); done
    printf "Select [1-%d]: " "$#" >&2
    local n; read -r n; n="${n:-1}"
    echo "${@:n:1}"
  fi
}

ok()   { printf "✓ %s\n" "$*"; }
info() { printf "INFO %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*" >&2; }

engine_running_anywhere() {
  # Detect real engine executables only (argv[0] basename), not symbol args.
  ps -eo args= 2>/dev/null | awk '
    {
      cmd=$1
      sub(/^.*\//, "", cmd)
      if (cmd=="BEXP" || cmd=="PMNY" || cmd=="TSLA" || cmd=="NVDA") {
        found=1
        exit 0
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

run_engine_prompt_if_safe() {
  if engine_running_anywhere; then
    warn "An engine appears to be running already. Skipping engine prompt."
    return 0
  fi

  local action
  action="$(choose "Run investment engine?" "Run investment engine" "Back")"

  # IMPORTANT: Back should exit the screen session so you return to the Home menu
  if [ "$action" != "Run investment engine" ]; then
    return 1
  fi

  local engine
  engine="$(choose "Select engine" "${ENGINE_NAMES[@]}")"
  [ -n "$engine" ] || return 1

  printf '\033[H\033[2J\033[3J' 2>/dev/null || true

  chmod +x "./${engine}" >/dev/null 2>&1 || true

  [ -f "$HOME/.profile" ] && source "$HOME/.profile" || true
  [ -f "$HOME/.bashrc" ]  && source "$HOME/.bashrc"  || true

  missing=()
  [ -n "${ALPACA_PAPER_API_KEY:-}" ] || missing+=("ALPACA_PAPER_API_KEY")
  [ -n "${ALPACA_PAPER_SECRET_KEY:-}" ] || missing+=("ALPACA_PAPER_SECRET_KEY")
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "Missing keys in this session: ${missing[*]}"
    warn "Fix: ensure keys exist in ~/.profile or ~/.bashrc for user $(whoami)"
    return 0
  fi

  "./${engine}"
  return 0
}

# Clean screen so session UI never mixes with prior content
printf '\033[H\033[2J\033[3J' 2>/dev/null || true

if has_gum; then
  gum style --border rounded --padding "1 2" --border-foreground 39 \
    "$(printf "ALGORA1 session — One-session mode\nSelect engine")" >&2
else
  echo "ALGORA1 session — One-session mode" >&2
fi
echo "" >&2

print_engine_blurbs
echo "" >&2

if run_engine_prompt_if_safe; then
  # When an engine exits, end the screen session so the control panel returns cleanly.
  exit 0
else
  # User hit Back → end this screen session → returns to ALGORA1 Home menu
  exit 0
fi

SESSION

sudo chmod +x /usr/local/bin/algora1-session

sudo tee /usr/local/bin/algora1-live-chart >/dev/null <<'CHART'
#!/usr/bin/env bash
set -euo pipefail

SYMBOL="${1:-TSLA}"
case "$SYMBOL" in
  TSLA|NVDA) ;;
  *) SYMBOL="TSLA" ;;
esac

python3 - "$SYMBOL" <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

ET = ZoneInfo("America/New_York")
UTC = ZoneInfo("UTC")

PLOT_W, PLOT_H = 70, 17
LEFT_PAD = 9
BOTTOM_PAD = 2
TOP_PAD = 4
WICK = "│"
BODY = "▪"
DOJI = "·"
WIDTH = 80
HEIGHT = 24

ACCENT = "\033[38;5;39m"
GREEN = "\033[38;5;34m"
RED = "\033[38;5;160m"
MUTED = "\033[38;5;245m"
RESET = "\033[0m"

symbol = sys.argv[1].upper()

def previous_trading_day(d: date) -> date:
    d -= timedelta(days=1)
    while d.weekday() >= 5:
        d -= timedelta(days=1)
    return d

def next_trading_day(d: date) -> date:
    d += timedelta(days=1)
    while d.weekday() >= 5:
        d += timedelta(days=1)
    return d

def iso_z(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

def market_anchor_day(now_et: datetime) -> date:
    d = now_et.date()
    if d.weekday() >= 5:
        while d.weekday() >= 5:
            d -= timedelta(days=1)
        return d
    open_today = datetime.combine(d, time(9, 30), tzinfo=ET)
    if now_et >= open_today:
        return d
    return previous_trading_day(d)

def fetch_intraday_bars(sym: str):
    key = os.getenv("ALPACA_LIVE_API_KEY", "").strip()
    secret = os.getenv("ALPACA_LIVE_SECRET_KEY", "").strip()
    if not key or not secret:
        return None, "Missing ALPACA_LIVE_API_KEY / ALPACA_LIVE_SECRET_KEY"

    now_et = datetime.now(ET)
    day = market_anchor_day(now_et)
    regular_open = datetime.combine(day, time(9, 30), tzinfo=ET)
    regular_close = datetime.combine(day, time(16, 0), tzinfo=ET)
    next_open = datetime.combine(next_trading_day(day), time(9, 30), tzinfo=ET)
    start = regular_open
    plot_end = regular_close
    time_labels = ["9:30 AM ET", "12:00 PM ET", "4:00 PM ET"]

    # Keep the closed-session chart visible overnight, then clear in the
    # 10-minute pre-open window before the next regular session.
    pre_open_reset_start = next_open - timedelta(minutes=10)
    if pre_open_reset_start <= now_et < next_open:
        return {
            "day": day,
            "start": start,
            "plot_end": plot_end,
            "time_labels": time_labels,
            "bars": [],
            "latest_price": None,
            "latest_time": now_et,
            "active_investment": False,
            "preopen_clear": True,
        }, None

    if now_et < regular_open:
        fetch_end = regular_close
    elif now_et >= regular_close:
        fetch_end = regular_close
    else:
        fetch_end = now_et

    params = {
        "symbols": sym,
        "timeframe": "1Min",
        "start": iso_z(start),
        "end": iso_z(fetch_end),
        "adjustment": "raw",
        "feed": "iex",
        "sort": "asc",
        "limit": "10000",
    }
    url = "https://data.alpaca.markets/v2/stocks/bars?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(
        url,
        headers={
            "APCA-API-KEY-ID": key,
            "APCA-API-SECRET-KEY": secret,
            "accept": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return None, f"IEX request failed: {e}"

    bars_raw = payload.get("bars", {}).get(sym, [])
    bars = []
    for b in bars_raw:
        t = b.get("t")
        o = b.get("o")
        h = b.get("h")
        l = b.get("l")
        c = b.get("c")
        if t is None or o is None or h is None or l is None or c is None:
            continue
        dt = datetime.fromisoformat(t.replace("Z", "+00:00")).astimezone(ET)
        if start <= dt <= regular_close:
            bars.append((dt, float(o), float(h), float(l), float(c)))

    if not bars:
        return None, f"No intraday IEX bars yet for {sym}."

    latest_time = bars[-1][0]
    active_investment = False

    # Active investment = live position exists for this symbol.
    pos_url = f"https://api.alpaca.markets/v2/positions/{sym}"
    pos_req = urllib.request.Request(
        pos_url,
        headers={
            "APCA-API-KEY-ID": key,
            "APCA-API-SECRET-KEY": secret,
            "accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(pos_req, timeout=5) as resp:
            pos_payload = json.loads(resp.read().decode("utf-8"))
            qty = float(pos_payload.get("qty", "0") or 0.0)
            active_investment = abs(qty) > 1e-6
    except urllib.error.HTTPError as e:
        if getattr(e, "code", None) == 404:
            active_investment = False
    except Exception:
        active_investment = False

    latest_price = None
    # During regular session, pull a fresher print so the latest candle can move
    # between 1-minute bars. Outside regular hours, freeze at the session close.
    if regular_open <= now_et < regular_close:
        quote_url = "https://data.alpaca.markets/v2/stocks/quotes/latest?" + urllib.parse.urlencode({
            "symbols": sym,
            "feed": "iex",
        })
        quote_req = urllib.request.Request(
            quote_url,
            headers={
                "APCA-API-KEY-ID": key,
                "APCA-API-SECRET-KEY": secret,
                "accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(quote_req, timeout=5) as resp:
                q_payload = json.loads(resp.read().decode("utf-8"))
                quote = q_payload.get("quotes", {}).get(sym, {})
                ap = quote.get("ap")
                bp = quote.get("bp")
                qt = quote.get("t")
                if ap is not None and bp is not None and ap > 0 and bp > 0:
                    latest_price = (float(ap) + float(bp)) / 2.0
                elif ap is not None and ap > 0:
                    latest_price = float(ap)
                elif bp is not None and bp > 0:
                    latest_price = float(bp)
                if qt:
                    qdt = datetime.fromisoformat(qt.replace("Z", "+00:00")).astimezone(ET)
                    if qdt > latest_time:
                        latest_time = qdt
        except Exception:
            latest_price = None

        # Fallback to latest trade if quote isn't available.
        trade_url = "https://data.alpaca.markets/v2/stocks/trades/latest?" + urllib.parse.urlencode({
            "symbols": sym,
            "feed": "iex",
        })
        trade_req = urllib.request.Request(
            trade_url,
            headers={
                "APCA-API-KEY-ID": key,
                "APCA-API-SECRET-KEY": secret,
                "accept": "application/json",
            },
        )
        if latest_price is None:
            try:
                with urllib.request.urlopen(trade_req, timeout=5) as resp:
                    t_payload = json.loads(resp.read().decode("utf-8"))
                    trade = t_payload.get("trades", {}).get(sym, {})
                    p = trade.get("p")
                    tt = trade.get("t")
                    if p is not None:
                        latest_price = float(p)
                    if tt:
                        tdt = datetime.fromisoformat(tt.replace("Z", "+00:00")).astimezone(ET)
                        if tdt > latest_time:
                            latest_time = tdt
            except Exception:
                latest_price = None

    return {
        "day": day,
        "start": start,
        "plot_end": plot_end,
        "time_labels": time_labels,
        "bars": bars,
        "latest_price": latest_price,
        "latest_time": latest_time,
        "active_investment": active_investment,
        "preopen_clear": False,
    }, None

def y_to_row(v: float, ymin: float, ymax: float) -> int:
    if ymax == ymin:
        return 0
    return int((ymax - v) / (ymax - ymin) * (PLOT_H - 1))

def build_candles(bars, start: datetime, plot_end: datetime):
    total = (plot_end - start).total_seconds()
    if total <= 0:
        return [None] * PLOT_W

    candles = [None] * PLOT_W
    for dt, o, h, l, c in bars:
        if dt < start or dt > plot_end:
            continue
        col = int(((dt - start).total_seconds() / total) * (PLOT_W - 1))
        col = max(0, min(PLOT_W - 1, col))

        cur = candles[col]
        if cur is None:
            candles[col] = {"o": o, "h": h, "l": l, "c": c}
        else:
            cur["h"] = max(cur["h"], h)
            cur["l"] = min(cur["l"], l)
            cur["c"] = c

    return candles

def put_label(canvas, row: int, text: str):
    s = f"{text:>7}"
    for k, ch in enumerate(s):
        canvas[row][k] = ch

def render_error(msg: str):
    lines = [" " * WIDTH for _ in range(HEIGHT)]
    title = f"LIVE CHARTS ({symbol})"
    tstart = max(0, (WIDTH - len(title)) // 2)
    lines[0] = (" " * tstart + title)[:WIDTH].ljust(WIDTH)

    text = msg[:WIDTH - 6]
    mstart = max(0, (WIDTH - len(text)) // 2)
    lines[11] = (" " * mstart + text)[:WIDTH].ljust(WIDTH)

    sys.stdout.write("\n".join(lines))

def render_chart(data):
    start = data["start"]
    plot_end = data["plot_end"]
    time_labels = data.get("time_labels") or ["9:30 AM ET", "12:00 PM ET", "4:00 PM ET"]
    bars = data["bars"]
    latest_price = data.get("latest_price")
    active_investment = bool(data.get("active_investment"))
    preopen_clear = bool(data.get("preopen_clear"))

    if preopen_clear:
        W = LEFT_PAD + 1 + PLOT_W
        H = TOP_PAD + PLOT_H + 1 + BOTTOM_PAD
        canvas = [[" "] * W for _ in range(H)]

        title = f"{symbol} Daily Candlesticks"
        title_start = max(0, (W - len(title)) // 2)
        title_row = 1
        for i, ch in enumerate(title):
            canvas[title_row][title_start + i] = ch

        hint = "Press Ctrl+C to return"
        hint_row = 2
        hint_start = max(0, (W - len(hint)) // 2)
        hint_positions = set()
        for i, ch in enumerate(hint):
            c = hint_start + i
            if c < W:
                canvas[hint_row][c] = ch
                hint_positions.add((hint_row, c))

        msg = "Preparing next market session..."
        msg2 = "Chart resets 10m before 9:30 AM ET."
        mid_row = TOP_PAD + (PLOT_H // 2) - 1
        msg_start = max(0, (W - len(msg)) // 2)
        msg2_start = max(0, (W - len(msg2)) // 2)
        msg_positions = set()
        for i, ch in enumerate(msg):
            c = msg_start + i
            if c < W:
                canvas[mid_row][c] = ch
                msg_positions.add((mid_row, c))
        for i, ch in enumerate(msg2):
            c = msg2_start + i
            if c < W:
                canvas[mid_row + 1][c] = ch
                msg_positions.add((mid_row + 1, c))

        lines = []
        for r in range(H):
            row_chars = []
            for c, ch in enumerate(canvas[r]):
                if (r, c) in hint_positions or (r, c) in msg_positions:
                    row_chars.append(f"{MUTED}{ch}{RESET}")
                else:
                    row_chars.append(ch)
            lines.append("".join(row_chars))

        if len(lines) < HEIGHT:
            lines.extend([" " * WIDTH for _ in range(HEIGHT - len(lines))])
        else:
            lines = lines[:HEIGHT]

        sys.stdout.write("\n".join(lines))
        return

    session_bars = [b for b in bars if b[0] <= plot_end]
    if not session_bars:
        session_bars = [bars[0]]

    candles = build_candles(session_bars, start, plot_end)
    last_price = float(latest_price) if latest_price is not None else session_bars[-1][4]
    for col in range(PLOT_W - 1, -1, -1):
        candle = candles[col]
        if candle is None:
            continue
        # Keep historical wick geometry stable; only the latest close updates in real-time.
        candle["c"] = last_price
        break

    y_values = []
    for c in candles:
        if c is None:
            continue
        y_values.append(c["l"])
        y_values.append(c["h"])
    if not y_values:
        y_values = [last_price]

    ymin, ymax = min(y_values), max(y_values)
    if ymax == ymin:
        ymax += 0.5
        ymin -= 0.5
    else:
        pad = max(0.01, (ymax - ymin) * 0.14)
        ymax += pad
        ymin -= pad

    W = LEFT_PAD + 1 + PLOT_W
    H = TOP_PAD + PLOT_H + 1 + BOTTOM_PAD
    canvas = [[" "] * W for _ in range(H)]

    axis_x = LEFT_PAD
    plot_top = TOP_PAD
    axis_y = TOP_PAD + PLOT_H

    for r in range(plot_top, plot_top + PLOT_H):
        canvas[r][axis_x] = "│"
    for c in range(axis_x, W):
        canvas[axis_y][c] = "─"
    canvas[axis_y][axis_x] = "└"

    latest_candle_col = -1
    for col in range(PLOT_W - 1, -1, -1):
        if candles[col] is not None:
            latest_candle_col = col
            break

    candle_colors = {}
    close_markers = set()
    for col, candle in enumerate(candles):
        if candle is None:
            continue

        c = axis_x + 1 + col
        o = candle["o"]
        h = candle["h"]
        l = candle["l"]
        close = max(l, min(h, candle["c"]))
        base_color = ACCENT if active_investment else (GREEN if close >= o else RED)

        wick_top = plot_top + y_to_row(h, ymin, ymax)
        wick_bottom = plot_top + y_to_row(l, ymin, ymax)
        lo = min(wick_top, wick_bottom)
        hi = max(wick_top, wick_bottom)
        for r in range(lo, hi + 1):
            canvas[r][c] = WICK
            candle_colors[(r, c)] = base_color

        close_row = plot_top + y_to_row(close, ymin, ymax)
        body_ch = DOJI if abs(close - o) < 1e-8 else BODY
        canvas[close_row][c] = body_ch
        if active_investment:
            candle_colors[(close_row, c)] = ACCENT
        else:
            candle_colors[(close_row, c)] = ACCENT if col == latest_candle_col else base_color
        close_markers.add((close_row, c))

    last_r = plot_top + y_to_row(max(ymin, min(ymax, last_price)), ymin, ymax)

    put_label(canvas, plot_top + 0, f"${ymax:.2f}")
    put_label(canvas, plot_top + (PLOT_H // 2), f"${((ymax + ymin) / 2):.2f}")
    put_label(canvas, plot_top + (PLOT_H - 1), f"${ymin:.2f}")

    put_label(canvas, last_r, f"${last_price:.2f}")
    last_label_positions = {(last_r, col) for col in range(7)}

    ticks = [
        (0, time_labels[0]),
        (PLOT_W // 2, time_labels[1]),
        (PLOT_W - 1, time_labels[2]),
    ]
    label_row = axis_y + 1
    for col, lab in ticks:
        tick_c = axis_x + 1 + col
        if axis_x <= tick_c < W:
            canvas[axis_y][tick_c] = "┬"
            start_col = tick_c - len(lab) // 2
            min_start = axis_x + 1
            max_start = W - len(lab)
            start_col = max(min_start, min(start_col, max_start))
            for k, ch in enumerate(lab):
                canvas[label_row][start_col + k] = ch

    title = f"{symbol} Daily Candlesticks"
    title_start = max(0, (W - len(title)) // 2)
    title_row = 1
    for i, ch in enumerate(title):
        canvas[title_row][title_start + i] = ch

    hint = "Press Ctrl+C to return"
    hint_row = 2
    hint_start = max(axis_x + 2, (W - len(hint)) // 2)
    hint_positions = set()
    for i, ch in enumerate(hint):
        c = hint_start + i
        if c < W:
            canvas[hint_row][c] = ch
            hint_positions.add((hint_row, c))

    lines = []
    for r in range(H):
        row_chars = []
        for c, ch in enumerate(canvas[r]):
            if (r, c) in hint_positions:
                row_chars.append(f"{MUTED}{ch}{RESET}")
            elif (r, c) in last_label_positions:
                row_chars.append(f"{ACCENT}{ch}{RESET}")
            elif active_investment and (r, c) in close_markers:
                row_chars.append(f"{ACCENT}{ch}{RESET}")
            elif (r, c) in candle_colors:
                row_chars.append(f"{candle_colors[(r, c)]}{ch}{RESET}")
            else:
                row_chars.append(ch)
        lines.append("".join(row_chars))

    if len(lines) < HEIGHT:
        lines.extend([" " * WIDTH for _ in range(HEIGHT - len(lines))])
    else:
        lines = lines[:HEIGHT]

    sys.stdout.write("\n".join(lines))

data, err = fetch_intraday_bars(symbol)
if err:
    render_error(err)
    sys.exit(0)

render_chart(data)
PY
CHART

sudo chmod +x /usr/local/bin/algora1-live-chart

sudo tee /usr/local/bin/algora1 >/dev/null <<'MENU'
#!/usr/bin/env bash
set -euo pipefail

case "${TERM:-}" in
  screen|screen-bce) export TERM="screen-256color" ;;
esac

ENGINE_NAMES=( "BEXP" "PMNY" "TSLA" "NVDA" )

CUSTOM_ROOT="${HOME}/.algora1_custom"
CUSTOM_META_DIR="${CUSTOM_ROOT}/meta"
CUSTOM_BUILD_DIR="${CUSTOM_ROOT}/builds"
CUSTOM_EXPORT_DIR="${CUSTOM_ROOT}/exports"

CUSTOM_INDUSTRIES=(
  "Information Technology"
  "Health Care"
  "Financials"
  "Consumer Discretionary"
  "Communication Services"
  "Consumer Staples"
  "Energy"
  "Diversify Exposure"
)

CUSTOM_PORTFOLIO_TYPES=(
  "Growth"
  "Stability"
  "Efficiency"
)

has_gum() { command -v gum >/dev/null 2>&1; }

# ----------------------------
# Keyboard / input management
# ----------------------------
_stty_saved=""

ui_save_tty() {
  _stty_saved="$(stty -g 2>/dev/null || true)"
}

ui_restore_tty() {
  if [ -n "${_stty_saved}" ]; then
    stty "${_stty_saved}" 2>/dev/null || true
  else
    stty sane 2>/dev/null || true
  fi
}

ui_drain_input() {
  # Non-blocking: discard pending keys
  while IFS= read -r -t 0.01 _junk 2>/dev/null; do :; done
}

ui_view_mode_on() {
  ui_save_tty
  stty -echo -icanon time 0 min 0 2>/dev/null || true
  ui_drain_input
  cursor_hide
  printf '\033[?25l' 2>/dev/null || true
}

ui_view_mode_off() {
  ui_drain_input
  ui_restore_tty
  cursor_show
}

ui_wait_enter_only() {
  # Robust "Press Enter" wait: canonical input, but echo disabled (so nothing shows).
  ui_save_tty
  stty -echo icanon 2>/dev/null || true
  ui_drain_input
  cursor_hide

  # Wait for Enter (user may type junk; it won't display)
  local _line=""
  IFS= read -r _line 2>/dev/null || true

  ui_restore_tty
  cursor_show
  ui_drain_input
}

hard_clear() {
  # Clear screen + scrollback so the header box always starts at the top.
  local seq=$'\033[H\033[2J\033[3J'
  printf '%s' "$seq" 2>/dev/null || true
  if [ -w /dev/tty ]; then
    printf '%s' "$seq" > /dev/tty 2>/dev/null || true
  fi
}

session_pretty_name() {
  # input: "2758.investing" -> output: "investing"
  local raw="${1:-}"
  raw="${raw##*/}"
  echo "${raw#*.}"
}

cursor_hide() { printf '\033[?25l' 2>/dev/null || true; }
cursor_show() { printf '\033[?25h' 2>/dev/null || true; }

_visible_len() {
  local s
  s="$(printf '%s' "$1" | sed -E $'s/\x1B\[[0-9;]*[A-Za-z]//g')"
  printf '%s' "${#s}"
}

_pad_right() {
  local txt="$1"
  local width="$2"
  local plain len
  plain="$(printf '%s' "$txt" | sed -E $'s/\x1B\[[0-9;]*[A-Za-z]//g')"
  len=${#plain}
  [ "$len" -gt "$width" ] && txt="${plain:0:$width}" && len="$width"
  printf '%s%*s' "$txt" $((width - len)) ''
}

_pad_center() {
  local txt="$1"
  local width="$2"
  local plain len lp rp
  plain="$(printf '%s' "$txt" | sed -E $'s/\x1B\[[0-9;]*[A-Za-z]//g')"
  len=${#plain}
  [ "$len" -gt "$width" ] && txt="${plain:0:$width}" && len="$width"
  lp=$(( (width - len) / 2 ))
  rp=$(( width - len - lp ))
  printf '%*s%s%*s' "$lp" '' "$txt" "$rp" ''
}

render_box() {
  local msg="$1"
  local min_w="${2:-0}"
  local max_w="${3:-60}"
  local center_y="${4:-1}"
  local pad_y="${5:-1}"
  local pad_x="${6:-2}"
  local align="${7:-center}"

  local rows cols
  rows="$(tput lines 2>/dev/null || echo 24)"
  cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

  local longest=0
  local lines=0
  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines + 1))
    local vlen
    vlen="$(_visible_len "$line")"
    case "$vlen" in ''|*[!0-9]*) vlen=0 ;; esac
    [ "$vlen" -gt "$longest" ] && longest="$vlen"
  done < <(printf '%b' "$msg")
  [ "$lines" -eq 0 ] && lines=1

  local inner_w=$((longest + (pad_x * 2)))
  [ "$inner_w" -lt "$min_w" ] && inner_w="$min_w"
  [ "$inner_w" -gt "$max_w" ] && inner_w="$max_w"
  [ "$inner_w" -gt $((cols - 4)) ] && inner_w=$((cols - 4))
  [ "$inner_w" -lt 1 ] && inner_w=1

  local box_w=$((inner_w + 2))
  local left=$(( (cols - box_w) / 2 ))
  [ "$left" -lt 0 ] && left=0

  if [ "$center_y" = "1" ]; then
    local box_h=$((lines + 2 + (pad_y * 2)))
    local top_pad=$(( (rows - box_h) / 2 ))
    [ "$top_pad" -lt 0 ] && top_pad=0
    printf '\033[H' 2>/dev/null || true
    for _ in $(seq 1 "$top_pad"); do printf '\n'; done
  fi

  local hline
  printf -v hline '%*s' "$inner_w" ''
  hline="${hline// /─}"
  printf '%*s\033[38;5;39m╭%s╮\033[0m\n' "$left" '' "$hline"

  for _ in $(seq 1 "$pad_y"); do
    printf '%*s\033[38;5;39m│\033[0m%*s\033[38;5;39m│\033[0m\n' "$left" '' "$inner_w" ''
  done

  while IFS= read -r line || [ -n "$line" ]; do
    local content_w=$((inner_w - (pad_x * 2)))
    [ "$content_w" -lt 0 ] && content_w=0
    local core
    if [ "$align" = "left" ]; then
      core="$(_pad_right "$line" "$content_w")"
    else
      core="$(_pad_center "$line" "$content_w")"
    fi
    printf '%*s\033[38;5;39m│\033[0m%*s%s%*s\033[38;5;39m│\033[0m\n' "$left" '' "$pad_x" '' "$core" "$pad_x" ''
  done < <(printf '%b' "$msg")

  for _ in $(seq 1 "$pad_y"); do
    printf '%*s\033[38;5;39m│\033[0m%*s\033[38;5;39m│\033[0m\n' "$left" '' "$inner_w" ''
  done

  printf '%*s\033[38;5;39m╰%s╯\033[0m\n' "$left" '' "$hline"
}

center_box() {
  render_box "$1" "${2:-0}" "${3:-60}" "${4:-1}" 1 2 center
}

small_footer_box() {
  render_box "$1" 0 32 0 0 1 center
}

show_centered_info_box() {
  local msg="$1"
  hard_clear
  center_box "$msg" 0 76 1
}

show_notice_with_return() {
  local msg="$1"
  hard_clear
  center_box "$(printf "%s\n\nPress Enter to return." "$msg")" 0 76 1
  ui_wait_enter_only
}

show_simple_notice() {
  local msg="$1"
  show_notice_with_return "$msg"
}

pause_return_box() {
  ui_wait_enter_only
}

validate_stop_loss() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  [ "$v" -ge 0 ] && [ "$v" -le 20 ]
}

normalize_allocation_csv() {
  # Strip spaces so "50, 50" becomes "50,50".
  printf "%s" "$1" | tr -d '[:space:]'
}

validate_allocation_csv() {
  local csv="$1"
  local expected="$2"
  local sum=0
  local v

  [ -n "$csv" ] || return 1
  [[ "$expected" =~ ^[0-9]+$ ]] || return 1

  IFS=',' read -r -a _alloc_arr <<< "$csv"
  [ "${#_alloc_arr[@]}" -eq "$expected" ] || return 1

  for v in "${_alloc_arr[@]}"; do
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    [ "$v" -ge 1 ] && [ "$v" -le 100 ] || return 1
    sum=$((sum + v))
  done

  [ "$sum" -le 100 ]
}

prompt_allocation_csv() {
  local ticker_csv="$1"
  local expected=0
  local allocations norm

  IFS=',' read -r -a _tickers <<< "$ticker_csv"
  expected="${#_tickers[@]}"

  while true; do
    allocations="$(input "Enter percentages matching ticker order (example: 50,50):")"
    norm="$(normalize_allocation_csv "$allocations")"
    if validate_allocation_csv "$norm" "$expected"; then
      printf "%s\n" "$norm"
      return 0
    fi
    show_notice_with_return "Invalid percentages. Enter ${expected} integers (1-100) separated by commas. Total must be <=100."
    draw_header_once
  done
}

prompt_stop_loss() {
  local prompt="${1:-Stop loss percent}"
  local default="${2:-6}"
  local sl=""
  local err=""

  while true; do
    draw_header_once
    [ -n "$err" ] && printf '\033[38;5;196m%s\033[0m\n\n' "$err" >&2
    sl="$(input "${prompt} (0-20, default ${default}):")"
    sl="${sl:-$default}"

    if validate_stop_loss "$sl"; then
      printf '%s\n' "$sl"
      return 0
    fi

    err='Enter a whole number from 0 to 20.'
  done
}

strip_ansi() {
  printf '%s' "$1" | sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g'
}

center_ansi() {
  local txt="$1"
  local width="$2"
  local plain len lp rp
  plain="$(strip_ansi "$txt")"
  len="${#plain}"
  if [ "$len" -gt "$width" ]; then
    txt="${plain:0:$width}"
    len="$width"
  fi
  lp=$(( (width - len) / 2 ))
  rp=$(( width - len - lp ))
  printf "%*s%s%*s" "$lp" "" "$txt" "$rp" ""
}

left_ansi() {
  local txt="$1"
  local width="$2"
  local plain len
  plain="$(strip_ansi "$txt")"
  len="${#plain}"
  if [ "$len" -gt "$width" ]; then
    txt="${plain:0:$width}"
    len="$width"
  fi
  printf "%s%*s" "$txt" $((width - len)) ""
}

live_status_box() {
  local engine="$1"
  local body="$2"

  local rows cols
  rows="$(tput lines 2>/dev/null || echo 24)"
  cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

  local footer_txt="Press Enter to return."
  local -a body_lines=()
  local blank_run=0
  while IFS= read -r ln; do
    local plain
    plain="$(strip_ansi "$ln")"

    # Drop hard separators from legacy status writers.
    if [[ "$plain" =~ ^[[:space:]]*[─-]{4,}[[:space:]]*$ ]]; then
      continue
    fi
    if [[ "$plain" =~ ^[[:space:]]*$ ]]; then
      if [ "$blank_run" -lt 1 ]; then
        body_lines+=("")
      fi
      blank_run=$((blank_run + 1))
      continue
    fi
    blank_run=0

    if [[ "$plain" == *"Ctrl+C to go back"* ]] || [[ "$plain" == "Press Enter to return."* ]]; then
      continue
    fi
    body_lines+=("$ln")
  done < <(printf "%s\n" "$body" | sed 's/\r//g')

  # Trim leading/trailing empty lines from incoming status.
  while [ "${#body_lines[@]}" -gt 0 ]; do
    local first_plain
    first_plain="$(strip_ansi "${body_lines[0]}")"
    [[ "$first_plain" =~ ^[[:space:]]*$ ]] || break
    body_lines=("${body_lines[@]:1}")
  done
  while [ "${#body_lines[@]}" -gt 0 ]; do
    local last_idx last_plain
    last_idx=$(( ${#body_lines[@]} - 1 ))
    last_plain="$(strip_ansi "${body_lines[$last_idx]}")"
    [[ "$last_plain" =~ ^[[:space:]]*$ ]] || break
    body_lines=("${body_lines[@]:0:$last_idx}")
  done

  if [ "${#body_lines[@]}" -eq 0 ]; then
    body_lines+=("(no status yet)")
  fi

  # Build compact main content with exactly one blank line at top/bottom inside border.
  local -a content=("" "${body_lines[@]}" "")
  local -a compact=()
  local ln plain
  blank_run=0
  for ln in "${content[@]}"; do
    plain="$(strip_ansi "$ln")"
    if [[ "$plain" =~ ^[[:space:]]*$ ]]; then
      if [ "$blank_run" -lt 1 ]; then
        compact+=("")
      fi
      blank_run=$((blank_run + 1))
    else
      blank_run=0
      compact+=("$ln")
    fi
  done
  content=("${compact[@]}")

  # Fit main content to screen while preserving footer mini-box.
  local max_content=$((rows - 7))
  [ "$max_content" -lt 5 ] && max_content=5
  if [ "${#content[@]}" -gt "$max_content" ]; then
    local keep_head=$((max_content - 2))
    [ "$keep_head" -lt 3 ] && keep_head=3
    content=("${content[@]:0:$keep_head}" "")
  fi

  # Width follows longest visible line so border matches text.
  local longest=0
  for ln in "${content[@]}"; do
    plain="$(strip_ansi "$ln")"
    [ "${#plain}" -gt "$longest" ] && longest="${#plain}"
  done

  local main_text_w="$longest"
  [ "$main_text_w" -lt 52 ] && main_text_w=52
  local max_text_w=$((cols - 8))
  [ "$main_text_w" -gt "$max_text_w" ] && main_text_w="$max_text_w"
  [ "$main_text_w" -lt 20 ] && main_text_w=20

  local main_box_w=$((main_text_w + 4))
  local main_box_h=$(( ${#content[@]} + 2 ))

  local footer_text_w="${#footer_txt}"
  [ "$footer_text_w" -lt 24 ] && footer_text_w=24
  [ "$footer_text_w" -gt "$max_text_w" ] && footer_text_w="$max_text_w"
  [ "$footer_text_w" -gt "$main_text_w" ] && footer_text_w="$main_text_w"
  local footer_box_w=$((footer_text_w + 4))
  local footer_box_h=3
  
  # Center both boxes as a single grouped block.
  local group_w="$main_box_w"
  [ "$footer_box_w" -gt "$group_w" ] && group_w="$footer_box_w"
  local group_left=$(( (cols - group_w) / 2 ))
  [ "$group_left" -lt 0 ] && group_left=0
  local main_left=$((group_left + (group_w - main_box_w) / 2))
  local footer_left=$((group_left + (group_w - footer_box_w) / 2))

  local gap=1
  local group_h=$((main_box_h + gap + footer_box_h))
  local top=$(( (rows - group_h) / 2 ))
  [ "$top" -lt 0 ] && top=0

  local header_idx=-1
  for ((i=0; i<${#content[@]}; i++)); do
    plain="$(strip_ansi "${content[$i]}")"
    if [[ ! "$plain" =~ ^[[:space:]]*$ ]]; then
      header_idx="$i"
      break
    fi
  done

  printf '\033[%d;1H' "$((top + 1))" 2>/dev/null || true

  local hline
  printf -v hline '%*s' "$((main_box_w - 2))" ''
  hline="${hline// /─}"
  printf '%*s\033[38;5;39m╭%s╮\033[0m\033[K\n' "$main_left" "" "$hline"
  for ((i=0; i<${#content[@]}; i++)); do
    local txt="" inside plain
    txt="${content[$i]}"
    plain="$(strip_ansi "$txt")"
    if [ "$i" -eq "$header_idx" ]; then
      inside="$(left_ansi "$txt" "$main_text_w")"
    elif [[ "$plain" == Equity:* ]] || [[ "$plain" == "Total P&L:"* ]]; then
      inside="$(left_ansi "$txt" "$main_text_w")"
    elif [[ "$plain" =~ ^[[:space:]]*$ ]]; then
      printf -v inside '%*s' "$main_text_w" ""
    else
      inside="$(center_ansi "$txt" "$main_text_w")"
    fi
    printf '%*s\033[38;5;39m│\033[0m %s \033[38;5;39m│\033[0m\033[K\n' "$main_left" "" "$inside"
  done
  printf '%*s\033[38;5;39m╰%s╯\033[0m\033[K\n' "$main_left" "" "$hline"

  printf '\033[K\n'

  local footer_hline footer_inside
  printf -v footer_hline '%*s' "$((footer_box_w - 2))" ''
  footer_hline="${footer_hline// /─}"
  footer_inside="$(center_ansi "$footer_txt" "$footer_text_w")"
  printf '%*s\033[38;5;39m╭%s╮\033[0m\033[K\n' "$footer_left" "" "$footer_hline"
  printf '%*s\033[38;5;39m│\033[0m %s \033[38;5;39m│\033[0m\033[K\n' "$footer_left" "" "$footer_inside"
  printf '%*s\033[38;5;39m╰%s╯\033[0m\033[K\n' "$footer_left" "" "$footer_hline"

}

secs_until_midnight_et() {
  # seconds until next midnight in America/New_York (ET)
  local now_s next_s
  now_s="$(TZ=America/New_York date +%s)"
  next_s="$(TZ=America/New_York date -d 'tomorrow 00:00:00' +%s)"
  local secs=$((next_s - now_s))
  [ "$secs" -lt 5 ] && secs=5
  printf "%s\n" "$secs"
}

choose() {
  local title="$1"; shift
  if has_gum; then
    local h=18
    local lines=""
    if command -v tput >/dev/null 2>&1; then
      lines="$(tput lines 2>/dev/null || true)"
      if [ -n "${lines}" ] && [ "${lines}" -gt 10 ] 2>/dev/null; then
        h=$((lines - 6))
      fi
    fi

    # Pin navigation hint to terminal bottom; hide gum's built-in help line.
    if [ -n "${lines}" ] && [ "${lines}" -gt 1 ] 2>/dev/null; then
      tput sc 1>&2 2>/dev/null || true
      tput cup $((lines - 1)) 0 1>&2 2>/dev/null || true
      printf '\033[2K\033[38;5;245m←↓↑→ navigate • enter submit\033[0m' >&2
      tput rc 1>&2 2>/dev/null || true
    fi

    gum choose \
      --header "$title" \
      --header.foreground 39 \
      --item.foreground 39 \
      --selected.foreground 231 \
      --selected.background 39 \
      --cursor.foreground 33 \
      --height "${h}" \
      --no-show-help \
      "$@"
  else
    echo "$title" >&2
    local i=1
    for opt in "$@"; do echo "  $i) $opt" >&2; i=$((i+1)); done
    printf "Select [1-%d]: " "$#" >&2
    local n; read -r n; n="${n:-1}"
    echo "${@:n:1}"
  fi
}

secret() {
  local prompt="$1"
  local v=""
  printf "%s " "$prompt" >&2
  IFS= read -r v < /dev/tty || true
  printf "%s\n" "$v"
}

input() {
  local prompt="$1"
  local v=""
  printf "%s " "$prompt" >&2
  IFS= read -r v < /dev/tty || true
  printf "%s\n" "$v"
}

confirm() {
  local prompt="$1"
  if has_gum; then
    gum confirm \
      --prompt.foreground 39 \
      --selected.foreground 231 \
      --selected.background 39 \
      --unselected.foreground 245 \
      "$prompt"
  else
    printf "%s [y/N]: " "$prompt"
    local a; read -r a || true
    [[ "$a" =~ ^[Yy]$ ]]
  fi
}

ok()   { printf "✓ %s\n" "$*"; }
info() { printf "INFO %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*" >&2; }

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

  screen -S "$s" -X quit >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! list_sessions_raw | grep -Fxq "$s"; then
      return 0
    fi
    sleep 0.1 || true
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
  screen -r "$s" || true
  return 0
}

create_new_session() {
  local name="$1"
  screen -S "$name" -dm bash -lc "cd \$HOME && export TERM=screen-256color && exec /usr/local/bin/algora1-session"
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
    *) echo "pmny_investing.log" ;;
  esac
}

live_status_for_engine() {
  case "$1" in
    BEXP) echo "bexp_live_status.txt" ;;
    TSLA) echo "tsla_live_status.txt" ;;
    NVDA) echo "nvda_live_status.txt" ;;
    PMNY) echo "pmny_live_status.txt" ;;
    *) echo "pmny_live_status.txt" ;;
  esac
}

detect_running_engine_best_effort() {
  # Match only executable basename (argv[0]), so plain "TSLA" args don't count.
  ps -eo args= 2>/dev/null | awk '
    {
      cmd=$1
      sub(/^.*\//, "", cmd)
      if (cmd=="BEXP" || cmd=="TSLA" || cmd=="NVDA" || cmd=="PMNY") {
        print cmd
        found=1
        exit 0
      }
    }
    END { if (!found) print "" }
  '
}

ensure_custom_dirs() {
  mkdir -p "${CUSTOM_META_DIR}" "${CUSTOM_BUILD_DIR}" "${CUSTOM_EXPORT_DIR}"
}

custom_meta_path() {
  local id="$1"
  printf "%s/%s.env\n" "${CUSTOM_META_DIR}" "${id}"
}

custom_build_dir() {
  local id="$1"
  printf "%s/%s\n" "${CUSTOM_BUILD_DIR}" "${id}"
}

custom_zip_path() {
  local id="$1"
  printf "%s/%s.zip\n" "${CUSTOM_EXPORT_DIR}" "${id}"
}

normalize_engine_id() {
  # Uppercase only; validation happens separately to avoid silently dropping chars.
  printf "%s" "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]'
}

validate_engine_id() {
  local id="$1"
  [[ "$id" =~ ^[A-Z]{4}$ ]]
}

sanitize_engine_id() {
  local raw trimmed letters
  raw="$(printf "%s" "$1" | tr -d '\r')"
  trimmed="$(printf "%s" "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  letters="$(printf "%s" "$trimmed" | tr -cd 'A-Za-z')"
  # Must be exactly 4 letters and nothing else.
  [ "${#letters}" -eq 4 ] || return 1
  [ "${#letters}" -eq "${#trimmed}" ] || return 1
  printf "%s" "$letters" | tr '[:lower:]' '[:upper:]'
}

custom_engine_exists() {
  local id="$1"
  [ -f "$(custom_meta_path "$id")" ]
}

save_custom_meta() {
  local id="$1"
  shift

  ensure_custom_dirs

  local path
  path="$(custom_meta_path "$id")"

  : > "$path"
  chmod 600 "$path"

  while [ "$#" -ge 2 ]; do
    printf '%s="%s"\n' "$1" "$2" >> "$path"
    shift 2
  done
}

load_custom_meta() {
  local id="$1"
  local path
  path="$(custom_meta_path "$id")"
  [ -f "$path" ] || return 1

  unset ENGINE_ID ENGINE_MODE ENGINE_BUILDER UNIVERSE_TYPE TICKERS INDUSTRY \
        PORTFOLIO_TYPE METRIC_FOCUS ALLOCATION_MODE ALLOCATIONS STOP_LOSS \
        ALGORITHM_RULE CREATED_AT

  # shellcheck disable=SC1090
  source "$path"
}

list_custom_engine_ids() {
  ensure_custom_dirs
  find "${CUSTOM_META_DIR}" -maxdepth 1 -type f -name '*.env' -printf '%f\n' 2>/dev/null \
    | sed 's/\.env$//' \
    | sort
}

choose_custom_engine_id() {
  local ids=()
  while IFS= read -r id; do
    [ -n "$id" ] && ids+=("$id")
  done < <(list_custom_engine_ids)

  [ "${#ids[@]}" -gt 0 ] || return 1
  choose "Select Custom Engine" "${ids[@]}" "Back"
}

portfolio_description() {
  case "$1" in
    Growth) echo "Highest return focus (CAGR / Total Return)" ;;
    Stability) echo "Lower drawdown / smoother ride" ;;
    Efficiency) echo "Best risk-adjusted return" ;;
    *) echo "" ;;
  esac
}

default_algorithm_rule() {
  echo "BUY if price > SMA50 and SMA10 > SMA20 and NOT(price < SMA20), else SELL"
}

industry_seed_tickers() {
  case "$1" in
    "Information Technology") echo "AAPL,MSFT,NVDA" ;;
    "Health Care") echo "LLY,UNH,JNJ" ;;
    "Financials") echo "JPM,GS,BLK" ;;
    "Consumer Discretionary") echo "AMZN,TSLA,HD" ;;
    "Communication Services") echo "GOOG,META,NFLX" ;;
    "Consumer Staples") echo "COST,WMT,PG" ;;
    "Energy") echo "XOM,CVX" ;;
    "Diversify Exposure") echo "MSFT,LLY,JPM,AMZN,XOM" ;;
    *) echo "" ;;
  esac
}

metric_focus_for_portfolio_type() {
  case "$1" in
    Growth) echo "CAGR, Total Return" ;;
    Stability) echo "Max Drawdown, Annualized Volatility" ;;
    Efficiency) echo "Sharpe, Sortino, Calmar" ;;
    *) echo "" ;;
  esac
}

CUSTOM_SUPPORTED_TICKERS=(
  AAPL MSFT NVDA
  LLY UNH JNJ
  JPM GS BLK
  AMZN TSLA HD
  GOOG META NFLX
  COST WMT PG
  XOM CVX
)

ticker_supported() {
  local needle="$1"
  local t
  for t in "${CUSTOM_SUPPORTED_TICKERS[@]}"; do
    [ "$t" = "$needle" ] && return 0
  done
  return 1
}

normalize_ticker_csv() {
  printf "%s" "$1" \
    | tr '[:lower:]' '[:upper:]' \
    | sed 's/[^A-Z,]//g' \
    | sed 's/,,*/,/g' \
    | sed 's/^,*//' \
    | sed 's/,*$//'
}

validate_ticker_csv_supported() {
  local csv="$1"
  local bad=()
  local token

  [ -n "$csv" ] || return 1

  IFS=',' read -r -a _ticker_arr <<< "$csv"
  for token in "${_ticker_arr[@]}"; do
    [ -n "$token" ] || continue
    ticker_supported "$token" || bad+=("$token")
  done

  [ "${#bad[@]}" -eq 0 ]
}

build_custom_bundle_files() {
  local id="$1"
  local build_dir
  build_dir="$(custom_build_dir "$id")"

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  load_custom_meta "$id" || return 1

  cat > "${build_dir}/README.txt" <<CUSTOM_README_EOF
ALGORA1 Custom Engine
Custom Engine Name: ${ENGINE_ID}
Mode: ${ENGINE_MODE}
Builder: ${ENGINE_BUILDER}
Universe: ${UNIVERSE_TYPE}
Tickers: ${TICKERS:-}
Industry: ${INDUSTRY:-}
Portfolio Type: ${PORTFOLIO_TYPE:-}
Metric Focus: ${METRIC_FOCUS:-}
Allocation Mode: ${ALLOCATION_MODE:-}
Allocations: ${ALLOCATIONS:-}
Stop Loss: ${STOP_LOSS:-}%
Created: ${CREATED_AT:-}
CUSTOM_README_EOF
  cp "$(custom_meta_path "$id")" "${build_dir}/engine.env"

  cat > "${build_dir}/${id}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "This custom engine package was created successfully."
echo "Real runtime generation hook has not been wired yet."
echo "Re-upload one current engine template and wire generation into build_custom_bundle_files()."
EOF
  chmod +x "${build_dir}/${id}"

  (
    cd "${build_dir}" &&
    zip -qr "$(custom_zip_path "$id")" .
  )
}

print_custom_engine_summary() {
  local id="$1"
  load_custom_meta "$id" || return 1

  local created_display="${CREATED_AT:-}"
  if [ -n "$created_display" ] && [[ "$created_display" != *"ET"* ]]; then
    created_display="${created_display} ET"
  fi

  cat <<CUSTOM_SUMMARY_EOF
Custom Engine Name: ${ENGINE_ID}
Mode: ${ENGINE_MODE}
Builder: ${ENGINE_BUILDER}
Universe: ${UNIVERSE_TYPE}
Tickers: ${TICKERS:-}
Industry: ${INDUSTRY:-}
Portfolio Type: ${PORTFOLIO_TYPE:-}
Metric Focus: ${METRIC_FOCUS:-}
Allocation Mode: ${ALLOCATION_MODE:-}
Allocations: ${ALLOCATIONS:-}
Stop Loss: ${STOP_LOSS:-}%
Created: ${created_display}
Zip: $(custom_zip_path "$id")
CUSTOM_SUMMARY_EOF
}

pause_return() {
  pause_return_box
}

draw_header_once() {
  hard_clear
  if has_gum; then
    gum style --border rounded --padding "1 2" --border-foreground 39 \
      "$(printf "ALGORA1 — Control Panel\nWelcome to ALGORA1's Terminal UI.")"
  else
    echo "ALGORA1 — Control Panel (one-session mode enabled)"
  fi
  echo ""
}

prompt_box_input() {
  local prompt="$1"
  local value=""
  local rows cols width inner left top
  local prompt_label="Input:"
  local prompt_text=""
  local input_max=20

  ui_restore_tty
  ui_drain_input
  cursor_show
  hard_clear

  rows="$(tput lines 2>/dev/null || echo 24)"
  cols="$(tput cols 2>/dev/null || echo 80)"
  case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac

  width=76
  [ "$width" -gt $((cols - 2)) ] && width=$((cols - 2))
  [ "$width" -lt 44 ] && width=44

  inner=$((width - 4))
  left=$(( (cols - width) / 2 ))
  [ "$left" -lt 0 ] && left=0

  top=$(( (rows - 9) / 2 ))
  [ "$top" -lt 0 ] && top=0

  printf '\033[H\033[2J\033[3J' > /dev/tty

  if [ "$top" -gt 0 ]; then
    local i
    for ((i=0; i<top; i++)); do
      printf '\n' > /dev/tty
    done
  fi

  local hline
  printf -v hline '%*s' $((width - 2)) ''
  hline="${hline// /─}"

  printf '%*s\033[38;5;39m╭%s╮\033[0m\n' "$left" '' "$hline" > /dev/tty
  printf '%*s\033[38;5;39m│\033[0m %s \033[38;5;39m│\033[0m\n' \
    "$left" '' "$(_pad_center 'ALGORA1 — Control Panel' "$inner")" > /dev/tty
  printf '%*s\033[38;5;39m│\033[0m %s \033[38;5;39m│\033[0m\n' \
    "$left" '' "$(_pad_center 'Welcome to ALGORA1'\''s Terminal UI.' "$inner")" > /dev/tty
  printf '%*s\033[38;5;39m│\033[0m %s \033[38;5;39m│\033[0m\n' \
    "$left" '' "$(_pad_right '' "$inner")" > /dev/tty

  prompt_text="$(_pad_right "$prompt" "$inner")"
  printf '%*s\033[38;5;39m│\033[0m %s \033[38;5;39m│\033[0m\n' \
    "$left" '' "$prompt_text" > /dev/tty

  printf '%*s\033[38;5;39m│\033[0m %s \033[38;5;39m│\033[0m\n' \
    "$left" '' "$(_pad_right "${prompt_label}" "$inner")" > /dev/tty

  printf '%*s\033[38;5;39m│\033[0m %s \033[38;5;39m│\033[0m\n' \
    "$left" '' "$(_pad_right '' "$inner")" > /dev/tty
  printf '%*s\033[38;5;39m╰%s╯\033[0m\n' "$left" '' "$hline" > /dev/tty

  # Move cursor inside the "Input:" row, right after the label.
  local input_row input_col
  input_row=$((top + 6))
  input_col=$((left + 3 + ${#prompt_label} + 1))

  printf '\033[%d;%dH' "$input_row" "$input_col" > /dev/tty
  IFS= read -r value < /dev/tty || true

  cursor_hide
  ui_drain_input
  printf '%s\n' "$value"
}

show_custom_engine_summary_box() {
  local id="$1"
  load_custom_meta "$id" || return 1

  local stop_loss_display="${STOP_LOSS:-}"
  [ -n "$stop_loss_display" ] && stop_loss_display="${stop_loss_display}%"

  local zip_name
  zip_name="$(basename "$(custom_zip_path "$id")")"

  local created_display="${CREATED_AT:-}"
  if [ -n "$created_display" ] && [[ "$created_display" != *"ET"* ]]; then
    created_display="${created_display} ET"
  fi

  local summary
  summary="$(cat <<EOF
Custom Engine Name: ${ENGINE_ID}
Mode: ${ENGINE_MODE}
Builder: ${ENGINE_BUILDER}
Universe: ${UNIVERSE_TYPE}
Tickers: ${TICKERS:-}
Industry: ${INDUSTRY:-}
Portfolio Type: ${PORTFOLIO_TYPE:-}
Metric Focus: ${METRIC_FOCUS:-}
Allocation Mode: ${ALLOCATION_MODE:-}
Allocations: ${ALLOCATIONS:-}
Stop Loss: ${stop_loss_display}
Created: ${created_display}
Zip: ${zip_name}

Press Enter to return.
EOF
)"
  hard_clear
  center_box "$summary" 0 76 1
}

custom_engine_builder_guided() {
  ensure_custom_dirs
  hard_clear

  local raw_id id mode universe
  raw_id="$(prompt_box_input "Enter Custom Engine Name (4 letters):")"
  id="$(sanitize_engine_id "$raw_id")" || {
    show_notice_with_return "Invalid Custom Engine Name: use exactly 4 letters (A-Z)."
    return 0
  }

  if custom_engine_exists "$id"; then
    show_notice_with_return "Custom Engine Name already exists: $id"
    return 0
  fi

  draw_header_once
  mode="$(choose "Select mode" "Live Engine" "Paper Engine" "Back")"
  [ "$mode" != "Back" ] || return 0

  draw_header_once
  universe="$(choose "Invest by" "Ticker" "Industry Basket" "Back")"
  [ "$universe" != "Back" ] || return 0

  local tickers="" industry="" portfolio_type="" metric_focus=""
  local allocation_mode="Equal Weight"
  local allocations=""
  local stop_loss="6"
  local algorithm_rule
  algorithm_rule="$(default_algorithm_rule)"

  if [ "$universe" = "Ticker" ]; then
    local ticker
    ticker="$(input "Enter ticker (example: AAPL):")"
    ticker="$(printf "%s" "$ticker" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z')"

    if [ -z "$ticker" ]; then
      show_notice_with_return "Ticker cannot be empty."
      return 0
    fi

    if ! ticker_supported "$ticker"; then
      show_notice_with_return "Unsupported ticker: $ticker

Supported custom tickers:
AAPL, MSFT, NVDA, LLY, UNH, JNJ, JPM, GS, BLK,
AMZN, TSLA, HD, GOOG, META, NFLX, COST, WMT, PG, XOM, CVX"
      return 0
    fi

    tickers="$ticker"

    stop_loss="$(prompt_stop_loss "Stop loss percent" "6")"
  else
    draw_header_once
    industry="$(choose "Select industry" "${CUSTOM_INDUSTRIES[@]}" "Back")"
    [ "$industry" != "Back" ] || return 0

    draw_header_once
    portfolio_type="$(choose "Select portfolio type" "${CUSTOM_PORTFOLIO_TYPES[@]}" "Back")"
    [ "$portfolio_type" != "Back" ] || return 0

    metric_focus="$(metric_focus_for_portfolio_type "$portfolio_type")"

    tickers="$(industry_seed_tickers "$industry")"
    allocation_mode="Model Portfolio"
    allocations="AUTO"
  fi

  save_custom_meta "$id" \
    ENGINE_ID "$id" \
    ENGINE_MODE "$(printf "%s" "$mode" | sed 's/ Engine$//')" \
    ENGINE_BUILDER "Guided" \
    UNIVERSE_TYPE "$universe" \
    TICKERS "$tickers" \
    INDUSTRY "$industry" \
    PORTFOLIO_TYPE "$portfolio_type" \
    METRIC_FOCUS "$metric_focus" \
    ALLOCATION_MODE "$allocation_mode" \
    ALLOCATIONS "$allocations" \
    STOP_LOSS "$stop_loss" \
    ALGORITHM_RULE "$algorithm_rule" \
    CREATED_AT "$(TZ=America/New_York date '+%Y-%m-%d %H:%M:%S ET')"

  build_custom_bundle_files "$id"

  show_custom_engine_summary_box "$id"
  ui_wait_enter_only
}

custom_engine_builder_advanced() {
  ensure_custom_dirs
  hard_clear

  local raw_id id mode
  raw_id="$(prompt_box_input "Enter Custom Engine Name (4 letters):")"
  id="$(sanitize_engine_id "$raw_id")" || {
    show_centered_info_box "Invalid Custom Engine Name: use exactly 4 letters (A-Z)."
    pause_return_box
    return 0
  }

  if custom_engine_exists "$id"; then
    show_centered_info_box "Custom Engine Name already exists: $id"
    pause_return_box
    return 0
  fi

  draw_header_once
  mode="$(choose "Select mode" "Live Engine" "Paper Engine" "Back")"
  [ "$mode" != "Back" ] || return 0

  local ticker_csv
  ticker_csv="$(input "Enter ticker(s), comma-separated (example: NVDA,TSLA):")"
  ticker_csv="$(normalize_ticker_csv "$ticker_csv")"

  if [ -z "$ticker_csv" ]; then
    show_notice_with_return "Ticker list cannot be empty."
    return 0
  fi

  if ! validate_ticker_csv_supported "$ticker_csv"; then
    show_notice_with_return "One or more tickers are unsupported.

Supported custom tickers:
AAPL, MSFT, NVDA, LLY, UNH, JNJ, JPM, GS, BLK,
AMZN, TSLA, HD, GOOG, META, NFLX, COST, WMT, PG, XOM, CVX"
    return 0
  fi

  local allocation_mode allocations
  draw_header_once
  allocation_mode="$(choose "Allocation method" "Equal Weight" "Manual Percentages" "Back")"
  [ "$allocation_mode" != "Back" ] || return 0

  if [ "$allocation_mode" = "Manual Percentages" ]; then
    allocations="$(prompt_allocation_csv "$ticker_csv")"
  else
    allocations="AUTO_EQUAL"
  fi

  local model_choice algorithm_rule
  draw_header_once
  model_choice="$(choose "Entry/Exit model" "Default Trend" "Fast Trend" "Conservative Trend" "Custom SMA Lengths" "Back")"
  [ "$model_choice" != "Back" ] || return 0

  case "$model_choice" in
    "Default Trend")
      algorithm_rule="BUY if price > SMA50 and SMA10 > SMA20 and NOT(price < SMA20), else SELL"
      ;;
    "Fast Trend")
      algorithm_rule="BUY if price > SMA30 and SMA5 > SMA10 and NOT(price < SMA10), else SELL"
      ;;
    "Conservative Trend")
      algorithm_rule="BUY if price > SMA100 and SMA20 > SMA50 and NOT(price < SMA50), else SELL"
      ;;
    "Custom SMA Lengths")
      local sma_fast sma_mid sma_slow
      sma_fast="$(input "Fast SMA length:")"
      sma_mid="$(input "Mid SMA length:")"
      sma_slow="$(input "Slow SMA length:")"
      algorithm_rule="BUY if price > SMA${sma_slow} and SMA${sma_fast} > SMA${sma_mid} and NOT(price < SMA${sma_mid}), else SELL"
      ;;
  esac

  local stop_loss
  stop_loss="$(prompt_stop_loss "Stop loss percent" "6")"

  save_custom_meta "$id" \
    ENGINE_ID "$id" \
    ENGINE_MODE "$(printf "%s" "$mode" | sed 's/ Engine$//')" \
    ENGINE_BUILDER "Advanced" \
    UNIVERSE_TYPE "Ticker Basket" \
    TICKERS "$ticker_csv" \
    INDUSTRY "" \
    PORTFOLIO_TYPE "" \
    METRIC_FOCUS "" \
    ALLOCATION_MODE "$allocation_mode" \
    ALLOCATIONS "$allocations" \
    STOP_LOSS "$stop_loss" \
    ALGORITHM_RULE "$algorithm_rule" \
    CREATED_AT "$(TZ=America/New_York date '+%Y-%m-%d %H:%M:%S ET')"

  build_custom_bundle_files "$id"

  show_custom_engine_summary_box "$id"
  ui_wait_enter_only
}

view_custom_engines_menu() {
  ensure_custom_dirs

  local picked
  picked="$(choose_custom_engine_id || true)"
  [ -n "${picked:-}" ] || return 0
  [ "$picked" != "Back" ] || return 0

  while true; do
    draw_header_once

    local action
    action="$(choose "Custom Engine: $picked" \
      "View Summary" \
      "Rebuild Zip" \
      "Show Backtest Info" \
      "Delete" \
      "Back")"

    case "$action" in
      "View Summary")
        show_custom_engine_summary_box "$picked"
        ui_wait_enter_only
        ;;
      "Rebuild Zip")
        build_custom_bundle_files "$picked"
        show_notice_with_return "Zip rebuilt successfully: $(basename "$(custom_zip_path "$picked")")"
        ;;
      "Show Backtest Info")
        load_custom_meta "$picked" || true
        show_notice_with_return "Custom Engine Name: ${ENGINE_ID}
Industry: ${INDUSTRY:-Not set}
Portfolio Type: ${PORTFOLIO_TYPE:-Not set}
Metric Focus: ${METRIC_FOCUS:-Not set}

Backtest links are not wired yet."
        ;;
      "Delete")
        if confirm "Delete custom engine '${picked}'?"; then
          rm -f "$(custom_meta_path "$picked")"
          rm -rf "$(custom_build_dir "$picked")"
          rm -f "$(custom_zip_path "$picked")"
          show_notice_with_return "Deleted ${picked}"
          return 0
        fi
        ;;
      *)
        return 0
        ;;
    esac
  done
}

custom_engines_menu() {
  ensure_custom_dirs

  while true; do
    draw_header_once

    local count selection
    count="$(list_custom_engine_ids | sed '/^\s*$/d' | wc -l | tr -d ' ')"

    if [ "${count}" = "0" ]; then
      selection="$(choose "Custom Engines" \
        "Custom Engine Builder (Guided)" \
        "Custom Engine Builder (Advanced)" \
        "Back")"
    else
      selection="$(choose "Custom Engines" \
        "Custom Engine Builder (Guided)" \
        "Custom Engine Builder (Advanced)" \
        "View Custom Engines" \
        "Back")"
    fi

    case "$selection" in
      "Custom Engine Builder (Guided)") custom_engine_builder_guided ;;
      "Custom Engine Builder (Advanced)") custom_engine_builder_advanced ;;
      "View Custom Engines") view_custom_engines_menu ;;
      *) return 0 ;;
    esac
  done
}

running_sessions_menu() {
  local cnt
  cnt="$(session_count)"

  if [ "$cnt" -gt 1 ]; then
    warn "Multiple screen sessions detected (${cnt}). One-session maxiumum per account deleting extras."
    if confirm "Delete all sessions now? (recommended)"; then
      delete_all_sessions
      ok "All sessions deleted."
    fi
    return 0
  fi

  if [ "$cnt" = "0" ]; then
    local action
    action="$(choose "Running session" "Start new session" "Back")"
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
    name="$(echo "$name" | tr -d '[:space:]')"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { warn "Invalid name. Use letters/numbers/_/- only."; return 0; }

    create_new_session "$name"

    hard_clear
    ui_view_mode_on
    screen -r "$name" || true
    ui_view_mode_off
    hard_clear
    return 0

  else
    local s_raw s_name action
    s_raw="$(get_only_session)"
    s_name="$s_raw"
    command -v session_pretty_name >/dev/null 2>&1 && s_name="$(session_pretty_name "$s_raw")"

    hard_clear
    if has_gum; then
      gum style --border rounded --padding "1 2" --border-foreground 39 \
        "$(printf "Running Session\nSession: %s" "$s_name")"
      echo ""
    fi

    action="$(choose "Running session" "Connect" "Delete session" "Back")"

    case "$action" in
      "Connect")
        hard_clear
        ui_view_mode_on
        screen -r "$s_raw" || true
        ui_view_mode_off
        hard_clear
        return 0
        ;;
      "Delete session")
        if confirm "Delete session '${s_name}'? This will stop any running engine."; then
          delete_session "$s_raw"
          ok "Session deleted."
        fi
        ;;
      *) return 0 ;;
    esac
  fi
}

live_status_menu() {
  cursor_hide

  # 1) Detect an engine ONCE when entering Live Status
  local eng
  eng="$(detect_running_engine_best_effort || true)"

  # 2) If none, show centered box and wait for Enter to return (no twitch)
  if [ -z "$eng" ]; then
    show_simple_notice "No active engine detected."
    hard_clear
    return 0
  fi

  # 3) If engine exists, do the live tail loop like before
  local stop=0
  trap 'stop=1' INT
  ui_view_mode_on

  # Safety: if SSH drops or the script is terminated, restore tty + cursor
  trap 'trap - INT TERM HUP; ui_view_mode_off; exit 0' TERM HUP

  hard_clear
  local last_render=""
  while true; do
    if [ "$stop" -eq 1 ]; then
      trap - INT TERM HUP
      ui_view_mode_off
      echo ""
      return 0
    fi

    # Re-detect engine each tick; if it stops, show centered message + Enter to return
    eng="$(detect_running_engine_best_effort || true)"
    if [ -z "$eng" ]; then
      trap - INT TERM HUP
      ui_view_mode_off

      show_simple_notice "Engine stopped."
      hard_clear
      return 0
    fi

    local file
    file="$(live_status_for_engine "$eng")"

    cursor_hide
    touch "$file" >/dev/null 2>&1 || true
    local status_txt
    status_txt="$(cat "$file" 2>/dev/null || true)"
    if [ -z "$status_txt" ]; then
      status_txt="(no status yet)"
    fi

    # Redraw only on actual content change to prevent twitching.
    local render_key="${eng}::${status_txt}"
    if [ "$render_key" != "$last_render" ]; then
      live_status_box "$eng" "$status_txt"
      last_render="$render_key"
      cursor_hide
    fi

    local key=""
    if IFS= read -r -s -n 1 -t 1 key < /dev/tty; then
      # In non-canonical mode, Enter can arrive as empty, CR, or LF.
      if [ -z "$key" ] || [ "$key" = $'\n' ] || [ "$key" = $'\r' ]; then
        trap - INT TERM HUP
        ui_view_mode_off
        hard_clear
        return 0
      fi
    fi
  done
}

live_charts_menu() {
  local eng
  eng="$(detect_running_engine_best_effort || true)"

  if [ -z "$eng" ]; then
    show_notice_with_return "No active engine detected."
    hard_clear
    return 0
  fi

  local pick symbol
  case "$eng" in
    NVDA)
      pick="$(choose "Live Charts" "NVIDIA Corporation (NVDA)" "Back")"
      case "$pick" in
        "NVIDIA Corporation (NVDA)") symbol="NVDA" ;;
        *) return 0 ;;
      esac
      ;;
    TSLA)
      pick="$(choose "Live Charts" "Tesla, Inc. (TSLA)" "Back")"
      case "$pick" in
        "Tesla, Inc. (TSLA)") symbol="TSLA" ;;
        *) return 0 ;;
      esac
      ;;
    BEXP|PMNY|*)
      pick="$(choose "Live Charts" "Tesla, Inc. (TSLA)" "NVIDIA Corporation (NVDA)" "Back")"
      case "$pick" in
        "Tesla, Inc. (TSLA)") symbol="TSLA" ;;
        "NVIDIA Corporation (NVDA)") symbol="NVDA" ;;
        *) return 0 ;;
      esac
      ;;
  esac

  local stop=0
  trap 'stop=1' INT
  ui_view_mode_on
  hard_clear
  cursor_hide

  # Safety: if SSH drops or the script is terminated, restore tty + cursor
  trap 'trap - INT TERM HUP; ui_view_mode_off; exit 0' TERM HUP

  while true; do
    if [ "$stop" -eq 1 ]; then
      trap - INT TERM HUP
      ui_view_mode_off
      hard_clear
      return 0
    fi

    printf '\033[H' 2>/dev/null || true
    cursor_hide
    /usr/local/bin/algora1-live-chart "$symbol" 2>/dev/null || true
    cursor_hide

    # Ignore all keys except Enter; Ctrl+C is handled by trap.
    local key=""
    if IFS= read -r -s -n 1 -t 0.6 key < /dev/tty; then
      # In non-canonical mode, Enter can arrive as empty, CR, or LF.
      if [ -z "$key" ] || [ "$key" = $'\n' ] || [ "$key" = $'\r' ]; then
        trap - INT TERM HUP
        ui_view_mode_off
        hard_clear
        return 0
      fi
    fi
  done
}

troubleshoot_menu() {
  local eng
  eng="$(detect_running_engine_best_effort || true)"

  # If none running: show centered screen and return on Enter (no typing, no cursor)
  if [ -z "$eng" ]; then
    show_notice_with_return "No active engine detected."
    hard_clear
    return 0
  fi

  # If engine running, tail that engine's log like before
  local logfile=""
  logfile="$(log_for_engine "$eng")"
  info "Engine detected: $eng"

  touch "$logfile" >/dev/null 2>&1 || true
  info "Tailing: $logfile (Ctrl+C to return)"

  local stop=0
  trap 'stop=1' INT
  ui_view_mode_on
  ui_drain_input

  while true; do
    set +e
    local secs today
    secs="$(secs_until_midnight_et)"
    today="$(TZ=America/New_York date +%F)"

    timeout "$secs" tail -n 200 -F "$logfile" 2>/dev/null \
      | awk -v d="$today" 'index($0, d) == 1 { print; fflush() }'
    local rc=$?
    set -e
    ui_drain_input

    if [ "$stop" -eq 1 ]; then
      trap - INT
      ui_view_mode_off
      echo ""
      return 0
    fi

    sleep 0.2 || true
  done
}

main_loop() {
  while true; do
    cursor_show
    draw_header_once

    local selection
    selection="$(choose "Select an option" \
      "Running session" \
      "Custom Engines" \
      "Live Status" \
      "Live Charts" \
      "System Activity" \
      "Exit")"

    case "$selection" in
      "Running session") running_sessions_menu ;;
      "Custom Engines") custom_engines_menu ;;
      "Live Status") live_status_menu ;;
      "Live Charts") live_charts_menu ;;
      "System Activity") troubleshoot_menu ;;
      "Exit") exit 0 ;;
      *) exit 0 ;;
    esac
  done
}

main_loop
MENU

sudo chmod +x /usr/local/bin/algora1

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y >/dev/null 2>&1 || true
  command -v screen >/dev/null 2>&1 || sudo apt-get install -y screen >/dev/null 2>&1 || true
  command -v zip >/dev/null 2>&1 || sudo apt-get install -y zip >/dev/null 2>&1 || true
fi

REMOTE_INSTALL_EOF
}

ssh_into_instance_menu() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"
  ui_info "Connecting to VM (control panel)…"
  set_term_title "ALGORA1's TUI - Automated Algorithmic Investments - $(detect_os)"
  exec ssh -tt \
    -o LogLevel=ERROR \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -i "${key_path}" \
    "${REMOTE_USER}@${ip}" "bash -lc 'algora1'"
}

ssh_into_instance() {
  local ip="$1"
  local key_path="${HOME}/.ssh/${KEY_NAME}"

  ui_info "Connecting to VM…"
  set_term_title "ALGORA1's TUI - Automated Algorithmic Investments - $(detect_os)"
  exec ssh -tt \
    -o LogLevel=ERROR \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -i "${key_path}" \
    "${REMOTE_USER}@${ip}"
}

install_plan_confirm() {
  ui_step "[6/12] Install plan"

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
  ui_step "[12/12] Complete"

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

main() {
  ensure_gum
  ui_header
  ui_ok "Detected: $(detect_os)"

  ensure_cfg_loaded
  ensure_defaults

  if [ "$(detect_os)" = "macos" ]; then
    install_local_cli
  fi

  if [ "$(detect_os)" = "macos" ]; then
    ensure_macos_app_bundle_present "${ALGORA1_ICNS_PATH:-}" || true
  fi

  ensure_ssh_key
  ensure_gcloud
  ensure_gcloud_auth
  ensure_project_id_tui

  save_cfg

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

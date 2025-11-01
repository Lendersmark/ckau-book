#!/usr/bin/env bash
set -euo pipefail

# ============================================
# ckau-book addons manager (hardcoded catalog)
# ============================================
# Features
# - Interactive loop menu: Install/Update, Remove, List, Exit.
# - Hardcoded catalog of addons.
# - Install logs a per-repo manifest of files and commit SHA.
# - Remove uses manifest; fallback derives files from repo ZIP.
# - Install/Update checks latest branch commit SHA via GitHub API.
# - Temp workdir under /userdata (not /tmp) + automatic cleanup.
#
# Requirements: curl, unzip, tar, sed, awk
#
# CLI (non-interactive)
#   ./install-addons-batocera.sh list
#   ./install-addons-batocera.sh install <Name> [...]   # install or update
#   ./install-addons-batocera.sh install all
#   ./install-addons-batocera.sh remove  <Name>|all
#
# Env
#   THEMES_DIR  (default: /userdata/themes)
#   BACKUP      (default: 0)    # backup ckau-book-addons before writing
#   BRANCH      (default: main) # default if per-addon branch empty
#   KEEP_TMP    (default: 0)    # keep temp dir for debugging
#   TMP_BASE    (default: ${THEMES_DIR}/.tmp)  # base for temp dirs

SCRIPT_VERSION="1.4.0"

THEMES_DIR="${THEMES_DIR:-/userdata/themes}"
ADDONS_DIR="${THEMES_DIR}/ckau-book-addons"
BACKUP="${BACKUP:-0}"
DEFAULT_BRANCH="${BRANCH:-main}"
KEEP_TMP="${KEEP_TMP:-0}"
TMP_BASE="${TMP_BASE:-${THEMES_DIR}/.tmp}"

MARKERS_DIR="${ADDONS_DIR}/.ckau-installed"          # per-repo state
MANIFESTS_DIR="${MARKERS_DIR}/manifests"             # files written
SHA_FILE_NAME="installed.sha"                        # commit sha saved per repo

msg(){ echo "[ckau-addon v${SCRIPT_VERSION}] $*"; }
die(){ echo "[ckau-addon v${SCRIPT_VERSION}][ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need curl; need unzip; need tar; need sed; need awk

# --------------------------------------------
# Hardcoded catalog: Name|Owner|Repo|Branch|Description
# --------------------------------------------
CATALOG="$(cat <<'EOF'
Colorful-4K-Images|CkauNui|ckau-book-addons-Colorful-4K-Images|main|High-res colorful system images
Colorful-Video|CkauNui|ckau-book-addons-Colorful-Video|main|Colorful video assets for systems
Cinematic-Video|CkauNui|ckau-book-addons-Cinematic-Video|main|Cinematic video assets
Consoles|CkauNui|ckau-book-addons-Consoles|main|Console artwork / assets
Wallpapers|CkauNui|ckau-book-addons-Wallpapers|main|Wallpapers set
EOF
)"

normalize() { printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[ _]+/-/g; s/[^a-z0-9-]+//g'; }

ensure_dirs(){ mkdir -p "${THEMES_DIR}" "${ADDONS_DIR}" "${MARKERS_DIR}" "${MANIFESTS_DIR}"; }
ensure_tmp_base(){ mkdir -p "${TMP_BASE}"; }

# optional: prune old temp dirs (>1 day) quietly
prune_old_tmp(){ find "${TMP_BASE}" -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true; }

catalog_lines(){ echo "${CATALOG}" | grep -vE '^\s*#|^\s*$'; }
catalog_count(){ catalog_lines | wc -l | awk '{print $1}'; }
catalog_get_n(){ catalog_lines | sed -n "${1}p"; }

# Resolve user-friendly name to "owner|repo|branch|name|desc"
resolve_addon(){
  local input="$1" needle; needle="$(normalize "$input")"
  local line name owner repo branch desc suffix
  while IFS= read -r line; do
    name="$(echo "$line" | awk -F'|' '{print $1}')"
    owner="$(echo "$line" | awk -F'|' '{print $2}')"
    repo="$(echo  "$line" | awk -F'|' '{print $3}')"
    branch="$(echo "$line" | awk -F'|' '{print $4}')"
    desc="$(echo "$line" | awk -F'|' '{print $5}')"
    [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
    suffix="$(echo "$repo" | sed -E 's/^ckau-book-addons-//I')"
    if [ "$(normalize "$name")" = "$needle" ] \
       || [ "$(normalize "$suffix")" = "$needle" ] \
       || [ "$(normalize "$repo")" = "$needle" ]; then
      printf "%s|%s|%s|%s|%s\n" "$owner" "$repo" "$branch" "$name" "$desc"; return 0
    fi
  done < <(catalog_lines)
  return 1
}

marker_repo_dir(){ printf "%s/%s" "${MARKERS_DIR}" "$1"; }      # arg: repo
manifest_path(){ printf "%s/%s.manifest" "${MANIFESTS_DIR}" "$1"; }
sha_path(){ printf "%s/%s" "$(marker_repo_dir "$1")" "${SHA_FILE_NAME}"; }

is_installed_repo(){ [ -f "$(manifest_path "$1")" ]; }

backup_addons(){
  if [ "${BACKUP}" = "1" ] && [ -d "${ADDONS_DIR}" ]; then
    local b="/userdata/system/backups/ckau-book-addons-$(date +%Y%m%d-%H%M%S).tgz"
    mkdir -p "$(dirname "$b")"
    msg "Creating backup: $b"
    tar -C "${THEMES_DIR}" -czf "$b" "ckau-book-addons"
  fi
}

print_list_with_status(){
  local idx=0
  msg "Available addons:"
  while IFS= read -r line; do
    idx=$((idx+1))
    local name owner repo branch desc
    name="$(echo "$line" | awk -F'|' '{print $1}')"
    owner="$(echo "$line" | awk -F'|' '{print $2}')"
    repo="$(echo  "$line" | awk -F'|' '{print $3}')"
    branch="$(echo "$line" | awk -F'|' '{print $4}')"
    desc="$(echo "$line" | awk -F'|' '{print $5}')"
    [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
    local mark="[ ]"; is_installed_repo "$repo" && mark="[✓]"
    printf "  %2d) %-18s %-3s %s/%s [%s]\n" "$idx" "$name" "$mark" "$owner" "$repo" "$branch"
    [ -n "$desc" ] && printf "       - %s\n" "$desc"
  done < <(catalog_lines)
}

# -------- GitHub helpers (latest commit SHA for branch) --------
latest_sha_for_branch(){
  # GitHub API: https://api.github.com/repos/:owner/:repo/commits/:branch
  local owner="$1" repo="$2" branch="$3"
  curl -fsSL "https://api.github.com/repos/${owner}/${repo}/commits/${branch}" \
    | grep -m1 '"sha"' | sed -E 's/.*"sha":\s*"([0-9a-f]+)".*/\1/' || true
}

installed_sha(){ local repo="$1" f; f="$(sha_path "$repo")"; [ -f "$f" ] && cat "$f" || echo ""; }
save_sha(){ local repo="$1" sha="$2" d; d="$(marker_repo_dir "$repo")"; mkdir -p "$d"; printf "%s\n" "$sha" > "$(sha_path "$repo")"; }

# ---------------- Install / Update / Remove core ----------------
install_from_zip_url(){
  local zip_url="$1" repo="$2" latest_sha="$3"
  ensure_tmp_base; prune_old_tmp
  local tmp; tmp="$(mktemp -d -p "${TMP_BASE}" ckau_addon_XXXXXX)"
  if [ "${KEEP_TMP}" != "1" ]; then trap 'rm -rf "'"$tmp"'" || true' EXIT
  else msg "Debug mode: temp kept at $tmp"; fi

  local zip_file="$tmp/addon.zip"
  msg "Downloading: $zip_url"
  curl -L --fail -o "$zip_file" "$zip_url"

  msg "Extracting..."
  unzip -q "$zip_file" -d "$tmp"

  local root; root="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$root" ] || die "Malformed ZIP (no root folder)."

  ensure_dirs; backup_addons

  # Build a manifest of all files written (relative to THEMES_DIR)
  local manifest; manifest="$(manifest_path "$repo")"
  mkdir -p "$(dirname "$manifest")"

  msg "Installing into ${THEMES_DIR}"
  (
    cd "$root"
    tar -cf - . \
    | ( cd "${THEMES_DIR}" && tar -xvpf - )
  ) | sed -E 's#^\./##' > "${manifest}.tmp"

  # Keep *all* paths, not only under ckau-book-addons/
  sort -u "${manifest}.tmp" > "$manifest"
  rm -f "${manifest}.tmp"

  # Save latest SHA (if available)
  [ -n "$latest_sha" ] && save_sha "$repo" "$latest_sha"

  # Marker info
  local rdir; rdir="$(marker_repo_dir "$repo")"; mkdir -p "$rdir"
  {
    echo "repo=${repo}"
    echo "datetime=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "zip_url=${zip_url}"
    echo "sha=$(installed_sha "$repo")"
  } > "${rdir}/info.txt"

  msg "Done. Files recorded in manifest: $(wc -l < "$manifest")"
  msg "Assets are under ${ADDONS_DIR}. Press F5 in EmulationStation to reload."
}

# Install or update in one go
install_one(){
  local name="$1"
  local resolved owner repo branch disp desc zip_url latest current

  resolved="$(resolve_addon "$name")" || die "Addon not found: $name"
  owner="$(echo "$resolved" | cut -d'|' -f1)"
  repo="$(echo  "$resolved" | cut -d'|' -f2)"
  branch="$(echo "$resolved" | cut -d'|' -f3)"
  disp="$(echo   "$resolved" | cut -d'|' -f4)"
  desc="$(echo   "$resolved" | cut -d'|' -f5)"

  current="$(installed_sha "$repo")"
  latest="$(latest_sha_for_branch "$owner" "$repo" "$branch")"
  zip_url="https://github.com/${owner}/${repo}/archive/refs/heads/${branch}.zip"

  if [ -z "$current" ]; then
    msg "Installing '${disp}' from ${owner}/${repo} [branch: ${branch}]"
    install_from_zip_url "$zip_url" "$repo" "$latest"
    return
  fi

  if [ -n "$latest" ] && [ "$latest" = "$current" ]; then
    msg "'${disp}' is already up to date (sha: $current). Nothing to do."
    return
  fi

  if [ -z "$latest" ]; then
    msg "Cannot resolve latest SHA from GitHub API; performing a refresh install of '${disp}'."
  else
    msg "Updating '${disp}' (current: ${current:-unknown} -> latest: $latest)."
  fi
  install_from_zip_url "$zip_url" "$repo" "$latest"
}

install_all(){ while IFS= read -r l; do install_one "$(echo "$l" | awk -F'|' '{print $1}')"; done < <(catalog_lines); }

remove_one(){
  local name="$1"
  local resolved owner repo branch disp manifest
  resolved="$(resolve_addon "$name")" || die "Addon not found: $name"
  owner="$(echo "$resolved" | cut -d'|' -f1)"
  repo="$(echo  "$resolved" | cut -d'|' -f2)"
  branch="$(echo "$resolved" | cut -d'|' -f3)"
  disp="$(echo  "$resolved" | cut -d'|' -f4)"
  manifest="$(manifest_path "$repo")"

  ensure_dirs

  # ---- list other manifests (not the current one)
  _other_manifests(){
    find "${MANIFESTS_DIR}" -type f ! -name "$(basename "$manifest")" 2>/dev/null
  }

  # ---- check if a relative path is referenced by any other manifest
  _is_referenced_elsewhere(){
    local rel="$1"
    local f
    while IFS= read -r f; do
      grep -F -q -- "$rel" "$f" && return 0
    done < <(_other_manifests)
    return 1
  }

  # ---- delete list of RELATIVE paths safely
  _safe_delete_list(){
    # 1) delete files first
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      case "$rel" in
        /*|../*) continue ;;  # safety: ignore absolute/parent paths
      esac
      local abs="${THEMES_DIR}/${rel}"
      [ -f "$abs" ] || continue
      _is_referenced_elsewhere "$rel" && continue
      rm -f "$abs"
    done

    # 2) then delete directories (deepest first)
    #    sort by path length (desc) so deeper directories go first
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      case "$rel" in
        /*|../*) continue ;;
      esac
      local abs="${THEMES_DIR}/${rel}"
      [ -d "$abs" ] || continue
      _is_referenced_elsewhere "$rel" && continue
      rmdir --ignore-fail-on-non-empty "$abs" 2>/dev/null || true
    done < <(sed -e 's#/$##' "$manifest" | awk '{ print length($0) " " $0 }' | sort -rn | cut -d" " -f2-)
  }

  if [ -f "$manifest" ]; then
    msg "Removing '${disp}' using saved manifest"
    _safe_delete_list < "$manifest"
  else
    if [ "${DEEP_REMOVE:-0}" != "1" ]; then
      msg "'${disp}' does not appear installed (no manifest). Nothing to remove. Set DEEP_REMOVE=1 to attempt a repo-based cleanup."
      return 0
    fi
    msg "No manifest for '${disp}' → DEEP_REMOVE=1: deriving file list from the repo (fallback)"
    ensure_tmp_base; prune_old_tmp
    local tmp; tmp="$(mktemp -d -p "${TMP_BASE}" ckau_rm_XXXXXX)"
    trap 'rm -rf "'"$tmp"'" || true' EXIT
    local zip="https://github.com/${owner}/${repo}/archive/refs/heads/${branch}.zip"
    curl -L --fail -o "$tmp/a.zip" "$zip"
    unzip -q "$tmp/a.zip" -d "$tmp"
    local root; root="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    [ -n "$root" ] || die "Malformed ZIP (no root folder)."
    # Build a temporary list of relative paths from the repo snapshot
    local tmp_list="$tmp/paths.txt"
    find "$root" -type f -o -type d \
      | sed -E "s#^$root/##" \
      | sort -u > "$tmp_list"
    _safe_delete_list < "$tmp_list"
  fi

  # best-effort: remove empty dirs under THEMES_DIR
  find "${THEMES_DIR}" -type d -empty -delete || true

  # remove marker & manifest (if any)
  rm -f "$manifest"
  rm -rf "$(marker_repo_dir "$repo")"

  msg "Removed '${disp}'."
}

remove_all(){ while IFS= read -r l; do remove_one "$(echo "$l" | awk -F'|' '{print $1}')"; done < <(catalog_lines); }

# ----------------------------- Interactive menu ------------------------------
interactive_menu(){
  ensure_dirs; ensure_tmp_base; prune_old_tmp
  while true; do
    echo
    print_list_with_status
    echo
    echo "Choose an action:"
    echo "  1) Install / Update addons"
    echo "  2) Remove addons"
    echo "  3) List addons (refresh)"
    echo "  0) Exit"
    printf "> "
    local action; IFS= read -r action || true
    case "$action" in
      1)
        pick_and_apply "install"
        echo; read -rp "Done. Press ENTER to go back to menu..." _ ;;
      2)
        pick_and_apply "remove"
        echo; read -rp "Done. Press ENTER to go back to menu..." _ ;;
      3)
        # refresh
        ;;
      0|"")
        msg "Bye."; break ;;
      *)
        echo "Invalid choice. Try again." ;;
    esac
  done
}

pick_and_apply(){
  local mode="$1"
  echo
  print_list_with_status
  echo
  echo "Type numbers (e.g., '1 3') or 'all'. Empty to cancel."
  printf "[%s] > " "$mode"
  local choice; IFS= read -r choice || true
  [ -z "$choice" ] && { msg "Cancelled."; return; }
  if [ "$choice" = "all" ]; then
    [ "$mode" = "install" ] && install_all || remove_all
    return
  fi
  local total; total="$(catalog_count)"
  for n in $choice; do
    echo "$n" | grep -qE '^[0-9]+$' || { msg "Skip invalid: $n"; continue; }
    [ "$n" -ge 1 ] && [ "$n" -le "$total" ] || { msg "Skip out-of-range: $n"; continue; }
    local line; line="$(catalog_get_n "$n")"
    local name; name="$(echo "$line" | awk -F'|' '{print $1}')"
    [ "$mode" = "install" ] && install_one "$name" || remove_one "$name"
  done
}

usage(){
  cat <<EOF
Usage:
  $0                          # interactive menu
  $0 list                     # list addons with status
  $0 install <Name> [...]     # install/update by name
  $0 install all              # install/update all
  $0 remove  <Name>|all       # remove by name or all

Env:
  THEMES_DIR (default: ${THEMES_DIR})
  BACKUP     (default: ${BACKUP})
  BRANCH     (default: ${DEFAULT_BRANCH})
  KEEP_TMP   (default: ${KEEP_TMP})
  TMP_BASE   (default: ${TMP_BASE})
EOF
}

# ------------------------------- CLI -----------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  "")
    interactive_menu ;;
  list)
    print_list_with_status ;;
  install)  # install == install or update
    [ $# -ge 1 ] || die "Missing name(s) or 'all'"
    if [ "$1" = "all" ]; then install_all
    else for x in "$@"; do install_one "$x"; done; fi ;;
  remove)
    [ $# -ge 1 ] || die "Missing name or 'all'"
    if [ "$1" = "all" ]; then remove_all
    else for x in "$@"; do remove_one "$x"; done; fi ;;
  -h|--help|help)
    usage ;;
  *)
    usage; exit 1 ;;
esac

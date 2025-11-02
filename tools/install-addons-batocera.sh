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

MARKERS_DIR="${THEMES_DIR}/.ckau-installed"          # per-repo state
MANIFESTS_DIR="${MARKERS_DIR}/manifests"             # files written
SHA_FILE_NAME="installed.sha"                        # commit sha saved per repo

# Map a GitHub repo name to its local root (relative to THEMES_DIR).
# - Theme:         repo "ckau-book"                      -> "ckau-book"
# - Addons repos:  repo "ckau-book-addons-XYZ"           -> "ckau-book-addons/XYZ"
# Returns the RELATIVE path (no leading slash).
repo_local_root(){
  local repo="$1"
  case "$repo" in
    ckau-book) printf '%s\n' "ckau-book"; return 0 ;;
    ckau-book-addons-*) printf '%s\n' "ckau-book-addons"; return 0 ;;
    *) printf '%s\n' "$repo" ;;
  esac
}

# Return newline-separated sentinel paths (relative to THEMES_DIR)
# that uniquely identify a given repo as "present" locally.
# We only map the known addons you mentioned. Others can be added later.
repo_sentinel_paths(){
  local repo="$1"
  case "$repo" in
    ckau-book)
      printf '%s\n' "ckau-book"
      ;;
    ckau-book-addons-Colorful-4K-Images)
      printf '%s\n' "ckau-book-addons/_inc/anim/4K"
      ;;
    ckau-book-addons-Colorful-Video)
      printf '%s\n' "ckau-book-addons/_inc/anim/video"
      ;;
    ckau-book-addons-Cinematic-Video)
      printf '%s\n' "ckau-book-addons/_inc/videos"
      ;;
    ckau-book-addons-Consoles)
      printf '%s\n' "ckau-book-addons/_inc/art"
      ;;
    ckau-book-addons-Wallpapers)
      printf '%s\n' "ckau-book-addons/_inc/art2"
      ;;
    *)
      # default heuristic: assume a folder with the repo name
      printf '%s\n' "$repo"
      ;;
  esac
}

# --------------------------------------------------------------
# Bootstrap tracking for manually preinstalled content
# --------------------------------------------------------------
# If a repo already exists in THEMES_DIR but does not yet have
# a local manifest/SHA, this function generates them automatically
# without downloading anything. It allows first-run detection of
# manually installed themes (e.g., ckau-book) so that updates work
# normally afterwards.
bootstrap_repo_tracking(){
  local owner="$1" repo="$2" branch="$3"
  local local_root_rel; local_root_rel="$(repo_local_root "$repo")"
  local repo_dir="${THEMES_DIR}/${local_root_rel}"
  local manifest sha latest
  manifest="$(manifest_path "$repo")"
  sha="$(sha_path "$repo")"
  # Build the list of subtrees we will record in the manifest
  # (theme: the whole root; addons: only their sentinel subtrees).
  local scan_list=()
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ -e "${THEMES_DIR}/${s}" ]; then
      scan_list+=("$s")
    fi
  done < <(repo_sentinel_paths "$repo")

  # If we found no existing sentinel for this repo, do not bootstrap it.
  # (Keeps behavior safe for addons that are not present.)
  if [ "${#scan_list[@]}" -eq 0 ]; then
    return 0
  fi

  # Already tracked? Nothing to do.
  [ -f "$manifest" ] && [ -f "$sha" ] && return 0

  # Repo folder not found? Cannot bootstrap.
  [ -d "$repo_dir" ] || return 0

  ensure_dirs

  msg "Detected existing untracked installation of '${repo}'. Initializing local tracking..."

  # Generate manifest (canonical: sorted, unique)
  mkdir -p "$(dirname "$manifest")"
  (
    cd "${THEMES_DIR}" || exit 0
    find "${repo}" -mindepth 1 -print | LC_ALL=C sort -u
  ) > "${manifest}.tmp"
  mv -f "${manifest}.tmp" "$manifest"

  # Obtain latest remote SHA to use as baseline
  latest="$(latest_sha_for_branch "$owner" "$repo" "$branch")"
  if [ -n "$latest" ]; then
    save_sha "$repo" "$latest"
    msg "Tracking initialized: $(wc -l < "$manifest") entries, sha=$latest"
  else
    msg "Warning: could not retrieve remote SHA; manifest created without SHA baseline."
  fi
}

# --------------------------------------------------------------
# Resync tracking if local content changed outside this script
# --------------------------------------------------------------
# If files under the repo's local tree (theme or addon sentinel subtrees)
# look newer than the recorded installed SHA, or if the file list diverges
# from the stored manifest, we assume a manual update (e.g., via EmulationStation).
# In that case we rebuild the manifest and set installed.sha to the latest
# remote commit, skipping any download.
resync_tracking_if_manual_update(){
  local owner="$1" repo="$2" branch="$3"
  local manifest sha latest
  local local_root_rel repo_dir
  local scan_has_any=0

  manifest="$(manifest_path "$repo")"
  sha="$(sha_path "$repo")"
  local_root_rel="$(repo_local_root "$repo")"
  repo_dir="${THEMES_DIR}/${local_root_rel}"

  # Nothing to do if repo dir doesn't exist or tracking isn't initialized yet.
  [ -d "$repo_dir" ] || return 0
  [ -f "$manifest" ] || return 0
  [ -f "$sha" ] || return 0

  # Build the list of subtrees to scan:
  # - for theme: whole "ckau-book"
  # - for addons: sentinel subtrees (e.g., ckau-book-addons/_inc/anim/4K, ...).
  # If no sentinel is defined/found, fall back to the local root.
  # (No process substitution; portable on BusyBox.)
  _scan_list_file="$(mktemp)"; : > "$_scan_list_file"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ -e "${THEMES_DIR}/${s}" ]; then
      printf '%s\n' "$s" >> "$_scan_list_file"
      scan_has_any=1
    fi
  done <<EOF_SENTINELS
$(repo_sentinel_paths "$repo")
EOF_SENTINELS
  if [ "$scan_has_any" -eq 0 ]; then
    printf '%s\n' "$local_root_rel" > "$_scan_list_file"
  fi

  # ----------------------------
  # Heuristic A: any file newer than installed.sha?
  # ----------------------------
  while IFS= read -r subtree; do
    # Stop at first hit: -print -quit
    if ( cd "${THEMES_DIR}" && find "$subtree" -type f -newer "$sha" -print -quit | grep -q . ); then
      msg "Detected manual update of '${repo}' (files newer than installed SHA). Resyncing tracking..."
      # Rebuild manifest from the scan list
      tmp_manifest="$(mktemp)"
      : > "$tmp_manifest"
      (
        cd "${THEMES_DIR}" || exit 0
        while IFS= read -r s2; do
          [ -n "$s2" ] || continue
          [ -e "$s2" ] || continue
          find "$s2" -mindepth 1 -print
        done < "$_scan_list_file"
      ) >> "$tmp_manifest"
      mv -f "$tmp_manifest" "$manifest"

      # Update installed SHA to latest remote
      latest="$(latest_sha_for_branch "$owner" "$repo" "$branch")"
      [ -n "$latest" ] && save_sha "$repo" "$latest"
      msg "Tracking resynced (manifest rebuilt, sha=${latest:-unknown})."
      rm -f "$_scan_list_file"
      return 0
    fi
  done < "$_scan_list_file"

  # ----------------------------
  # Heuristic B: file list drifted vs manifest?
  # ----------------------------
  tmp_list="$(mktemp)"
  tmp_list2="$(mktemp)"
  (
    cd "${THEMES_DIR}" || exit 0
    # Costruisci la lista corrente (ordinata e unica)
    while IFS= read -r s3; do
      [ -n "$s3" ] || continue
      [ -e "$s3" ] || continue
      find "$s3" -mindepth 1 -print
    done < "$_scan_list_file" | LC_ALL=C sort -u
  ) > "$tmp_list"

  # Canonicalizza anche il manifest salvato
  LC_ALL=C sort -u "$manifest" > "$tmp_list2"

  if ! diff -q "$tmp_list" "$tmp_list2" >/dev/null 2>&1 ; then
    msg "Detected file-list changes in '${repo}'. Resyncing tracking..."
    mv -f "$tmp_list" "$manifest"
    latest="$(latest_sha_for_branch "$owner" "$repo" "$branch")"
    [ -n "$latest" ] && save_sha "$repo" "$latest"
    msg "Tracking resynced (manifest rebuilt, sha=${latest:-unknown})."
    rm -f "$tmp_list2"
    return 0
  fi

  rm -f "$tmp_list" "$tmp_list2"
}

msg(){ echo "[ckau-addon v${SCRIPT_VERSION}] $*"; }
die(){ echo "[ckau-addon v${SCRIPT_VERSION}][ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need curl; need unzip; need tar; need sed; need awk; need diff

# --------------------------------------------
# Hardcoded catalog: Name|Owner|Repo|Branch|Description
# --------------------------------------------
CATALOG="$(cat <<'EOF'
Theme|CkauNui|ckau-book|master|ckau-book theme core
Colorful-4K-Images|CkauNui|ckau-book-addons-Colorful-4K-Images|main|High-res colorful system images
Colorful-Video|CkauNui|ckau-book-addons-Colorful-Video|main|Colorful video assets for systems
Cinematic-Video|CkauNui|ckau-book-addons-Cinematic-Video|main|Cinematic video assets
Consoles|CkauNui|ckau-book-addons-Consoles|main|Console artwork / assets
Wallpapers|CkauNui|ckau-book-addons-Wallpapers|main|Wallpapers set
EOF
)"

# --------------------------------------------------------------
# Preflight bootstrap for all catalog entries
# --------------------------------------------------------------
# Run before showing the menu (and on refresh/list) so that any
# manually preinstalled repos already present under THEMES_DIR
# get a local manifest/SHA without re-downloading.
# It only runs resync if tracking already existed, to avoid
# a spurious "file-list changes" right after bootstrap.
preflight_bootstrap_all(){
  local name owner repo branch desc
  local local_root_rel present had_tracking

  # Read CATALOG line-by-line: strip CR (CRLF), skip empty/comment lines.
  printf '%s\n' "$CATALOG" | tr -d '\r' | \
  while IFS='|' read -r name owner repo branch desc; do
    # Skip empty or comment lines
    [ -n "${name:-}" ] || continue
    case "$name" in \#*) continue ;; esac
    # Require a non-empty repo field
    [ -n "${repo:-}" ] || continue

    present=0
    had_tracking=0
    local_root_rel="$(repo_local_root "$repo")"

    # Consider present if the local root exists…
    [ -d "${THEMES_DIR}/${local_root_rel}" ] && present=1

    # …or if any sentinel path for this repo exists
    if [ "$present" -eq 0 ]; then
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        if [ -e "${THEMES_DIR}/${s}" ]; then
          present=1
          break
        fi
      done <<EOF_SENTINELS
$(repo_sentinel_paths "$repo")
EOF_SENTINELS
    fi

    # Snapshot tracking state BEFORE bootstrap
    [ -f "$(manifest_path "$repo")" ] && [ -f "$(sha_path "$repo")" ] && had_tracking=1

    # If present locally, ensure tracking; resync only if it already existed
    if [ "$present" -eq 1 ]; then
      bootstrap_repo_tracking "$owner" "$repo" "$branch"
      if [ "$had_tracking" -eq 1 ]; then
        resync_tracking_if_manual_update "$owner" "$repo" "$branch"
      fi
    fi
  done
}

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
  msg "Available downloads:"
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
  # Tries multiple strategies to resolve a branch HEAD sha.
  # Order: /git/refs/heads/<branch> → /commits?sha=<branch>&per_page=1 → zipball ETag
  local owner="$1" repo="$2" branch="$3"
  local ua="ckau-addon/${SCRIPT_VERSION} (+https://github.com/CkauNui/ckau-book)"
  local auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

  # 1) Fast path: refs API
  #   GET https://api.github.com/repos/:owner/:repo/git/refs/heads/:branch
  #   → {"object":{"sha":"<sha>",...}}
  local sha
  sha="$(
    curl -fsSL -H "User-Agent: ${ua}" -H "Accept: application/vnd.github+json" \
      "${auth[@]}" \
      "https://api.github.com/repos/${owner}/${repo}/git/refs/heads/${branch}" \
    | sed -nE 's/.*"object"\s*:\s*\{[^}]*"sha"\s*:\s*"([0-9a-f]{7,40})".*/\1/p' \
    || true
  )"
  [ -n "$sha" ] && { printf '%s\n' "$sha"; return 0; }

  # 2) Commits API (explicit query param)
  #   GET .../commits?sha=<branch>&per_page=1
  #   → [{"sha":"<sha>",...}]
  sha="$(
    curl -fsSL -H "User-Agent: ${ua}" -H "Accept: application/vnd.github+json" \
      "${auth[@]}" \
      "https://api.github.com/repos/${owner}/${repo}/commits?sha=${branch}&per_page=1" \
    | sed -nE 's/.*"sha"\s*:\s*"([0-9a-f]{7,40})".*/\1/p' \
    | head -n1 \
    || true
  )"
  [ -n "$sha" ] && { printf '%s\n' "$sha"; return 0; }

  # 3) Zipball ETag fallback (no JSON; works anche quando l’API fa 422)
  #   HEAD https://api.github.com/repos/:owner/:repo/zipball/:branch
  #   ETag tipicamente contiene il commit (W/"<sha>")
  sha="$(
    curl -fsSLI -H "User-Agent: ${ua}" -H "Accept: application/vnd.github+json" \
      "${auth[@]}" \
      "https://api.github.com/repos/${owner}/${repo}/zipball/${branch}" \
    | awk -F': ' 'BEGIN{IGNORECASE=1} $1=="etag"{print $2}' \
    | tr -d 'W/"' \
    | tr -d '"' \
    | sed -nE 's/^([0-9a-f]{7,40}).*/\1/p' \
    || true
  )"
  [ -n "$sha" ] && { printf '%s\n' "$sha"; return 0; }

  # Give up
  echo ""
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
  msg "Assets installed under ${THEMES_DIR}. Press F5 in EmulationStation to reload."
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

  bootstrap_repo_tracking "$owner" "$repo" "$branch"
  # If the user updated files manually (e.g., via EmulationStation), resync tracking now.
  resync_tracking_if_manual_update "$owner" "$repo" "$branch"

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

  # Guard-rail: don't remove the core theme unless explicit
  if [ "$repo" = "ckau-book" ] && [ "${ALLOW_THEME_REMOVE:-0}" != "1" ]; then
    die "Refusing to remove 'ckau-book'. Set ALLOW_THEME_REMOVE=1 if you really mean it."
  fi

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
  # clear screen each time the menu is shown
  printf '\033c'
  
  ensure_dirs; ensure_tmp_base; prune_old_tmp
  preflight_bootstrap_all
  while true; do
    printf '\033c'
    print_list_with_status
    echo
    echo "Choose an action:"
    echo "  1) Install / Update theme or addons"
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
        preflight_bootstrap_all
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
    preflight_bootstrap_all
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

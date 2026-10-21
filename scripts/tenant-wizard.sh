#!/usr/bin/env bash
# Tenant wizard: bootstrap tenants GitOps wiring + register pointer Applications
# to external tenant repos. Writes to the current working branch only (no commit/push).
set -euo pipefail

WIZARD_BRANCH="tenant-wizardry"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/tenant-wizard/templates"
CONFIRM_PHRASE="do it!"
MAX_CONFIRM_ATTEMPTS=3

MODE=""          # bootstrap | register | both
CONFIG_FILE=""
OVERLAY=""
ROOT_DIR=""

# Planned actions (newline-separated human lines)
PLAN_LINES=()
# Tenant registrations to apply: id|repoURL|targetRevision|path|overwrite(yes/no)
TENANT_ACTIONS=()
DO_BOOTSTRAP=false
DO_REGISTER=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--config FILE] [--mode bootstrap|register|both] [--overlay NAME]

Bootstraps tenants AppProject/ApplicationSet wiring for a cluster overlay and/or
registers pointer Applications under tenants/<id>/remote/ pointing at external repos.

Options:
  --config FILE   Batch YAML (see scripts/tenant-wizard.example.yaml)
  --mode MODE     bootstrap | register | both (default: ask, or from config)
  --overlay NAME  Cluster overlay name (default: ask / infer from branch)
  -h, --help      Show this help

Safety:
  - Refuses to run on branch '${WIZARD_BRANCH}' (merge it into a working branch first).
  - Requires typing '${CONFIRM_PHRASE}' before writing files (max ${MAX_CONFIRM_ATTEMPTS} attempts).
  - Does not git commit or push.
EOF
}

log()  { echo "$*"; }
warn() { echo "WARNING: $*" >&2; }
err()  { echo "ERROR: $*" >&2; }

die() {
  err "$*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

find_git_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "Not inside a git repository"
}

current_branch() {
  git -C "${ROOT_DIR}" branch --show-current
}

fail_if_wizard_branch() {
  local branch
  branch="$(current_branch)"
  if [[ "${branch}" == "${WIZARD_BRANCH}" ]]; then
    die "Fail-safe: refuse to run on branch '${WIZARD_BRANCH}'. Merge '${WIZARD_BRANCH}' into a working branch, checkout that branch, then re-run."
  fi
  if [[ -z "${branch}" ]]; then
    die "Detached HEAD is not supported; checkout a named working branch."
  fi
}

list_overlays() {
  local d
  for d in "${ROOT_DIR}"/clusters/overlays/*/; do
    [[ -d "${d}" ]] || continue
    basename "${d}"
  done | sort
}

confirm_overlay() {
  local branch default candidate
  branch="$(current_branch)"
  default=""
  if [[ -d "${ROOT_DIR}/clusters/overlays/${branch}" ]]; then
    default="${branch}"
  fi

  log ""
  log "Available cluster overlays:"
  list_overlays | sed 's/^/  - /'
  log ""

  if [[ -n "${OVERLAY}" ]]; then
    [[ -d "${ROOT_DIR}/clusters/overlays/${OVERLAY}" ]] || die "Overlay not found: ${OVERLAY}"
    log "Using overlay from flag/config: ${OVERLAY}"
    read -r -p "Confirm overlay '${OVERLAY}'? [Y/n] " ans || true
    ans="${ans:-Y}"
    [[ "${ans}" =~ ^[Yy]$ ]] || die "Overlay not confirmed."
    return
  fi

  if [[ -n "${default}" ]]; then
    read -r -p "Confirm overlay [${default}]: " candidate || true
    OVERLAY="${candidate:-${default}}"
  else
    read -r -p "Enter overlay name: " OVERLAY || true
  fi
  [[ -n "${OVERLAY}" ]] || die "Overlay is required."
  [[ -d "${ROOT_DIR}/clusters/overlays/${OVERLAY}" ]] || die "Overlay not found: ${OVERLAY}"
  log "Overlay confirmed: ${OVERLAY}"
}

path_exists() { [[ -e "$1" ]]; }

file_contains() {
  local file="$1" pattern="$2"
  [[ -f "${file}" ]] && grep -qF "${pattern}" "${file}"
}

health_check() {
  local ok=0
  local total=5
  local project_file apps_kust projects_kust appset_file patch_file apps_overlay_kust cluster_kust

  project_file="${ROOT_DIR}/components/argocd/projects/base/tenants-project.yaml"
  projects_kust="${ROOT_DIR}/components/argocd/projects/base/kustomization.yaml"
  appset_file="${ROOT_DIR}/components/argocd/apps/base/tenants-applicationset.yaml"
  apps_kust="${ROOT_DIR}/components/argocd/apps/base/kustomization.yaml"
  patch_file="${ROOT_DIR}/components/argocd/apps/overlays/${OVERLAY}/patch-tenants-applicationset.yaml"
  apps_overlay_kust="${ROOT_DIR}/components/argocd/apps/overlays/${OVERLAY}/kustomization.yaml"
  cluster_kust="${ROOT_DIR}/clusters/overlays/${OVERLAY}/kustomization.yaml"

  log ""
  log "=== Tenants bootstrap health check (overlay=${OVERLAY}) ==="

  if path_exists "${project_file}" && file_contains "${projects_kust}" "tenants-project.yaml"; then
    log "[ok] AppProject tenants"
    ok=$((ok + 1))
  else
    log "[missing] AppProject tenants / projects kustomization wiring"
  fi

  if path_exists "${appset_file}" && file_contains "${apps_kust}" "tenants-applicationset.yaml"; then
    log "[ok] ApplicationSet tenants"
    ok=$((ok + 1))
  else
    log "[missing] ApplicationSet tenants / apps base kustomization wiring"
  fi

  if path_exists "${patch_file}"; then
    log "[ok] Overlay patch ${patch_file#"${ROOT_DIR}"/}"
    ok=$((ok + 1))
  else
    log "[missing] Overlay patch-tenants-applicationset.yaml"
  fi

  if path_exists "${apps_overlay_kust}" && file_contains "${apps_overlay_kust}" "patch-tenants-applicationset.yaml"; then
    log "[ok] Apps overlay references tenants patch"
    ok=$((ok + 1))
  else
    log "[missing] Apps overlay kustomization patch entry for tenants"
  fi

  if path_exists "${cluster_kust}" && grep -q "name: tenants" "${cluster_kust}" 2>/dev/null; then
    log "[ok] Cluster overlay replacements for ApplicationSet tenants"
    ok=$((ok + 1))
  else
    log "[missing] Cluster overlay replacements for ApplicationSet tenants generator"
  fi

  log "Health: ${ok}/${total} checks passed."
  if [[ ${ok} -eq ${total} ]]; then
    return 0
  fi
  return 1
}

choose_mode() {
  if [[ -n "${MODE}" ]]; then
    case "${MODE}" in
      bootstrap|register|both) ;;
      *) die "Invalid mode: ${MODE}" ;;
    esac
  else
    log ""
    log "Select mode:"
    log "  1) bootstrap wiring only"
    log "  2) register tenants only"
    log "  3) both (default)"
    read -r -p "Choice [3]: " choice || true
    choice="${choice:-3}"
    case "${choice}" in
      1) MODE="bootstrap" ;;
      2) MODE="register" ;;
      3) MODE="both" ;;
      *) die "Invalid choice" ;;
    esac
  fi

  case "${MODE}" in
    bootstrap) DO_BOOTSTRAP=true; DO_REGISTER=false ;;
    register)  DO_BOOTSTRAP=false; DO_REGISTER=true ;;
    both)      DO_BOOTSTRAP=true; DO_REGISTER=true ;;
  esac
  log "Mode: ${MODE}"
}

ensure_resource_line() {
  # ensure_resource_line <kustomization.yaml> <resource-filename>
  local kust="$1" resource="$2"
  if file_contains "${kust}" "${resource}"; then
    return 0
  fi
  python3 - "${kust}" "${resource}" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
resource = sys.argv[2]
text = path.read_text()
if resource in text:
    sys.exit(0)
lines = text.splitlines()
out = []
inserted = False
in_resources = False
for i, line in enumerate(lines):
    out.append(line)
    if line.strip() == "resources:":
        in_resources = True
        continue
    if in_resources:
        if line.startswith("  - ") or line.strip() == "":
            # peek if next non-empty is still a resource
            pass
        if line.startswith("  - "):
            # keep going; insert after last resource block later
            pass
        elif not line.startswith(" ") and line.strip() != "":
            # left resources block; insert before this line
            out.insert(-1, f"  - {resource}")
            inserted = True
            in_resources = False
if in_resources and not inserted:
    out.append(f"  - {resource}")
    inserted = True
if not inserted:
    if "resources:" not in text:
        out.append("")
        out.append("resources:")
        out.append(f"  - {resource}")
    else:
        # append at end of file under resources
        for idx in range(len(out)-1, -1, -1):
            if out[idx].startswith("  - "):
                out.insert(idx+1, f"  - {resource}")
                inserted = True
                break
        if not inserted:
            out.append(f"  - {resource}")
path.write_text("\n".join(out) + "\n")
PY
}

ensure_apps_overlay_patch() {
  local kust="${ROOT_DIR}/components/argocd/apps/overlays/${OVERLAY}/kustomization.yaml"
  [[ -f "${kust}" ]] || die "Missing apps overlay kustomization: ${kust}"
  if file_contains "${kust}" "patch-tenants-applicationset.yaml"; then
    return 0
  fi
  python3 - "${kust}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
if "patch-tenants-applicationset.yaml" in text:
    sys.exit(0)
block = """  - path: patch-tenants-applicationset.yaml
    target:
      kind: ApplicationSet
      name: tenants
"""
if "patches:" not in text:
    text = text.rstrip() + "\n\npatches:\n" + block
else:
    text = text.rstrip() + "\n" + block
path.write_text(text if text.endswith("\n") else text + "\n")
PY
}

ensure_cluster_replacements() {
  local kust="${ROOT_DIR}/clusters/overlays/${OVERLAY}/kustomization.yaml"
  [[ -f "${kust}" ]] || die "Missing cluster overlay kustomization: ${kust}"
  if grep -q "name: tenants" "${kust}" 2>/dev/null; then
    return 0
  fi
  python3 - "${kust}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
if "name: tenants" in text:
    sys.exit(0)

repo_target = """      - select:
          kind: ApplicationSet
          name: tenants
        fieldPaths:
          - spec.generators.0.git.repoURL
"""
rev_target = """      - select:
          kind: ApplicationSet
          name: tenants
        fieldPaths:
          - spec.generators.0.git.revision
"""

lines = text.splitlines()
out = []
inserted_repo = False
inserted_rev = False

for idx, line in enumerate(lines):
    out.append(line)
    stripped = line.strip()
    # Insert after generic ApplicationSet template repoURL target
    if (
        not inserted_repo
        and stripped == "- spec.template.spec.source.repoURL"
    ):
        # confirm we are under an ApplicationSet select without name: tenants
        window = "\n".join(lines[max(0, idx - 6) : idx + 1])
        if "kind: ApplicationSet" in window and "name: tenants" not in window:
            out.extend(repo_target.rstrip("\n").splitlines())
            inserted_repo = True
    if (
        not inserted_rev
        and stripped == "- spec.template.spec.source.targetRevision"
    ):
        window = "\n".join(lines[max(0, idx - 6) : idx + 1])
        if "kind: ApplicationSet" in window and "name: tenants" not in window:
            out.extend(rev_target.rstrip("\n").splitlines())
            inserted_rev = True

if not inserted_repo or not inserted_rev:
    sys.stderr.write(
        "Could not locate generic ApplicationSet replacement targets; "
        "appending tenants generator replacements.\n"
    )
    if "replacements:" not in text:
        out.append("")
        out.append("replacements:")
    if not inserted_repo:
        out.append("  - source:")
        out.append("      kind: ConfigMap")
        out.append("      fieldPath: data.repoURL")
        out.append("      name: gitops-repo-config")
        out.append("    targets:")
        out.extend(repo_target.rstrip("\n").splitlines())
    if not inserted_rev:
        out.append("  - source:")
        out.append("      kind: ConfigMap")
        out.append("      fieldPath: data.targetRevision")
        out.append("      name: gitops-repo-config")
        out.append("    targets:")
        out.extend(rev_target.rstrip("\n").splitlines())

path.write_text("\n".join(out) + "\n")
PY
}

plan_bootstrap() {
  PLAN_LINES+=("BOOTSTRAP wiring for overlay '${OVERLAY}':")
  PLAN_LINES+=("  - ensure components/argocd/projects/base/tenants-project.yaml")
  PLAN_LINES+=("  - ensure components/argocd/projects/base/kustomization.yaml includes tenants-project.yaml")
  PLAN_LINES+=("  - ensure components/argocd/apps/base/tenants-applicationset.yaml")
  PLAN_LINES+=("  - ensure components/argocd/apps/base/kustomization.yaml includes tenants-applicationset.yaml")
  PLAN_LINES+=("  - ensure components/argocd/apps/overlays/${OVERLAY}/patch-tenants-applicationset.yaml")
  PLAN_LINES+=("  - ensure apps overlay kustomization patches tenants ApplicationSet")
  PLAN_LINES+=("  - ensure clusters/overlays/${OVERLAY}/kustomization.yaml tenants generator replacements")
}

apply_bootstrap() {
  local project_file appset_file patch_file
  project_file="${ROOT_DIR}/components/argocd/projects/base/tenants-project.yaml"
  appset_file="${ROOT_DIR}/components/argocd/apps/base/tenants-applicationset.yaml"
  patch_file="${ROOT_DIR}/components/argocd/apps/overlays/${OVERLAY}/patch-tenants-applicationset.yaml"

  mkdir -p "$(dirname "${project_file}")" "$(dirname "${appset_file}")" "$(dirname "${patch_file}")"

  cp "${TEMPLATES_DIR}/tenants-project.yaml" "${project_file}"
  cp "${TEMPLATES_DIR}/tenants-applicationset.yaml" "${appset_file}"
  sed "s/__OVERLAY__/${OVERLAY}/g" "${TEMPLATES_DIR}/patch-tenants-applicationset.yaml" > "${patch_file}"

  ensure_resource_line "${ROOT_DIR}/components/argocd/projects/base/kustomization.yaml" "tenants-project.yaml"
  ensure_resource_line "${ROOT_DIR}/components/argocd/apps/base/kustomization.yaml" "tenants-applicationset.yaml"
  ensure_apps_overlay_patch
  ensure_cluster_replacements
  log "Bootstrap wiring applied for overlay '${OVERLAY}'."
}

tenant_exists() {
  local id="$1"
  [[ -d "${ROOT_DIR}/tenants/${id}/remote/overlays/${OVERLAY}" ]] \
    || [[ -f "${ROOT_DIR}/tenants/${id}/remote/base/application.yaml" ]]
}

read_existing_pointer_target() {
  local id="$1"
  local app="${ROOT_DIR}/tenants/${id}/remote/base/application.yaml"
  if [[ -f "${app}" ]]; then
    # shellcheck disable=SC2016
    yq -r '.spec.source | "repoURL=\(.repoURL) targetRevision=\(.targetRevision) path=\(.path)"' "${app}" 2>/dev/null || echo "(unreadable)"
  else
    echo "(no application.yaml)"
  fi
}

prompt_tenant_interactive() {
  local id repo revision path clone_path choice overwrite="no" existing

  log ""
  log "=== Register tenant (interactive) ==="
  read -r -p "Tenant id (directory name under tenants/): " id || true
  [[ -n "${id}" ]] || die "Tenant id is required."

  if tenant_exists "${id}"; then
    existing="$(read_existing_pointer_target "${id}")"
    warn "Tenant id '${id}' already exists for overlay '${OVERLAY}'."
    warn "Current pointer: ${existing}"
    read -r -p "Skip or overwrite? [skip/overwrite]: " choice || true
    case "${choice}" in
      overwrite|o|O) overwrite="yes" ;;
      skip|s|S|"") log "Skipping tenant '${id}'."; return 0 ;;
      *) die "Expected skip or overwrite." ;;
    esac
  fi

  log "Tenant source:"
  log "  1) local git clone path"
  log "  2) repo URL + targetRevision (default)"
  read -r -p "Choice [2]: " choice || true
  choice="${choice:-2}"

  if [[ "${choice}" == "1" ]]; then
    read -r -p "Path to local clone: " clone_path || true
    [[ -n "${clone_path}" ]] || die "clone path required"
    clone_path="${clone_path/#\~/${HOME}}"
    [[ -d "${clone_path}/.git" ]] || die "Not a git clone: ${clone_path}"
    repo="$(git -C "${clone_path}" remote get-url origin)"
    revision="$(git -C "${clone_path}" branch --show-current)"
    [[ -n "${revision}" ]] || revision="$(git -C "${clone_path}" rev-parse --short HEAD)"
    # normalize ssh to https-ish display optional; keep as-is
    log "Detected repoURL=${repo} targetRevision=${revision}"
  else
    read -r -p "repoURL: " repo || true
    read -r -p "targetRevision [main]: " revision || true
    revision="${revision:-main}"
  fi
  [[ -n "${repo}" ]] || die "repoURL required"

  read -r -p "Remote path [${id}/namespaces/overlays/${OVERLAY}]: " path || true
  path="${path:-${id}/namespaces/overlays/${OVERLAY}}"

  TENANT_ACTIONS+=("${id}|${repo}|${revision}|${path}|${overwrite}")
  PLAN_LINES+=("REGISTER tenant '${id}' -> ${repo}@${revision} path=${path} (overwrite=${overwrite})")

  read -r -p "Add another tenant? [y/N]: " choice || true
  if [[ "${choice}" =~ ^[Yy]$ ]]; then
    prompt_tenant_interactive
  fi
}

load_tenants_from_config() {
  require_cmd yq
  local count i name repo revision path clone_path overwrite existing choice
  count="$(yq '.tenants | length' "${CONFIG_FILE}")"
  [[ "${count}" != "null" && "${count}" -gt 0 ]] || die "No tenants listed in ${CONFIG_FILE}"

  for ((i=0; i<count; i++)); do
    name="$(yq -r ".tenants[${i}].name // \"\"" "${CONFIG_FILE}")"
    repo="$(yq -r ".tenants[${i}].repoURL // \"\"" "${CONFIG_FILE}")"
    revision="$(yq -r ".tenants[${i}].targetRevision // \"\"" "${CONFIG_FILE}")"
    path="$(yq -r ".tenants[${i}].path // \"\"" "${CONFIG_FILE}")"
    clone_path="$(yq -r ".tenants[${i}].clonePath // \"\"" "${CONFIG_FILE}")"
    overwrite="$(yq -r ".tenants[${i}].overwrite // false" "${CONFIG_FILE}")"

    [[ -n "${name}" && "${name}" != "null" ]] || die "tenants[${i}].name is required"

    if [[ -n "${clone_path}" && "${clone_path}" != "null" ]]; then
      clone_path="${clone_path/#\~/${HOME}}"
      [[ -d "${clone_path}/.git" ]] || die "clonePath not a git repo: ${clone_path}"
      repo="$(git -C "${clone_path}" remote get-url origin)"
      revision="$(git -C "${clone_path}" branch --show-current)"
      [[ -n "${revision}" ]] || revision="$(git -C "${clone_path}" rev-parse --short HEAD)"
    fi

    [[ -n "${repo}" && "${repo}" != "null" ]] || die "tenants[${i}] needs repoURL or clonePath"
    [[ -n "${revision}" && "${revision}" != "null" ]] || revision="main"
    [[ -n "${path}" && "${path}" != "null" ]] || path="${name}/namespaces/overlays/${OVERLAY}"

    if tenant_exists "${name}"; then
      existing="$(read_existing_pointer_target "${name}")"
      warn "Tenant id '${name}' already exists for overlay '${OVERLAY}'."
      warn "Current pointer: ${existing}"
      if [[ "${overwrite}" == "true" ]]; then
        warn "Config sets overwrite=true; will overwrite '${name}'."
        overwrite="yes"
      else
        warn "Skipping '${name}' (set overwrite: true in YAML to replace)."
        PLAN_LINES+=("SKIP tenant '${name}' (duplicate; overwrite not set)")
        continue
      fi
    else
      overwrite="no"
    fi

    TENANT_ACTIONS+=("${name}|${repo}|${revision}|${path}|${overwrite}")
    PLAN_LINES+=("REGISTER tenant '${name}' -> ${repo}@${revision} path=${path} (overwrite=${overwrite})")
  done
}

apply_tenant_registration() {
  local entry id repo revision path overwrite
  local base_dir overlay_dir
  for entry in "${TENANT_ACTIONS[@]}"; do
    IFS='|' read -r id repo revision path overwrite <<<"${entry}"
    base_dir="${ROOT_DIR}/tenants/${id}/remote/base"
    overlay_dir="${ROOT_DIR}/tenants/${id}/remote/overlays/${OVERLAY}"
    mkdir -p "${base_dir}" "${overlay_dir}"

    sed \
      -e "s|__TENANT_ID__|${id}|g" \
      -e "s|__REPO_URL__|${repo}|g" \
      -e "s|__TARGET_REVISION__|${revision}|g" \
      -e "s|__REMOTE_PATH__|${path}|g" \
      "${TEMPLATES_DIR}/pointer-application.yaml" > "${base_dir}/application.yaml"

    cp "${TEMPLATES_DIR}/pointer-base-kustomization.yaml" "${base_dir}/kustomization.yaml"
    cp "${TEMPLATES_DIR}/pointer-overlay-kustomization.yaml" "${overlay_dir}/kustomization.yaml"
    log "Registered pointer for tenant '${id}' at tenants/${id}/remote/overlays/${OVERLAY}"
  done
}

print_plan() {
  log ""
  log "=== Planned changes ==="
  if [[ ${#PLAN_LINES[@]} -eq 0 ]]; then
    log "(nothing to do)"
    return
  fi
  local line
  for line in "${PLAN_LINES[@]}"; do
    log "${line}"
  done
  log "Branch: $(current_branch)"
  log "Repo root: ${ROOT_DIR}"
  log "No git commit/push will be performed."
}

confirm_do_it() {
  local attempt=1 answer
  log ""
  log "To proceed, type exactly: ${CONFIRM_PHRASE}"
  while [[ ${attempt} -le ${MAX_CONFIRM_ATTEMPTS} ]]; do
    read -r -p "Confirm (${attempt}/${MAX_CONFIRM_ATTEMPTS}): " answer || true
    if [[ "${answer}" == "${CONFIRM_PHRASE}" ]]; then
      return 0
    fi
    warn "Did not match '${CONFIRM_PHRASE}'."
    attempt=$((attempt + 1))
  done
  die "Confirmation failed after ${MAX_CONFIRM_ATTEMPTS} attempts. Aborting."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG_FILE="${2:-}"
        shift 2
        ;;
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --overlay)
        OVERLAY="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

load_config_defaults() {
  [[ -n "${CONFIG_FILE}" ]] || return 0
  [[ -f "${CONFIG_FILE}" ]] || die "Config not found: ${CONFIG_FILE}"
  require_cmd yq
  if [[ -z "${OVERLAY}" ]]; then
    OVERLAY="$(yq -r '.overlay // ""' "${CONFIG_FILE}")"
    [[ "${OVERLAY}" != "null" ]] || OVERLAY=""
  fi
  if [[ -z "${MODE}" ]]; then
    MODE="$(yq -r '.mode // ""' "${CONFIG_FILE}")"
    [[ "${MODE}" != "null" && -n "${MODE}" ]] || MODE=""
  fi
}

main() {
  require_cmd git
  require_cmd python3
  require_cmd sed
  [[ -d "${TEMPLATES_DIR}" ]] || die "Templates missing at ${TEMPLATES_DIR}"

  parse_args "$@"
  ROOT_DIR="$(find_git_root)"
  cd "${ROOT_DIR}"

  fail_if_wizard_branch
  load_config_defaults
  confirm_overlay

  if health_check; then
    log "Tenants wiring looks complete for this overlay."
  else
    log "Tenants wiring is incomplete for this overlay."
  fi

  choose_mode

  if [[ "${DO_REGISTER}" == true && "${DO_BOOTSTRAP}" != true ]]; then
    if ! health_check >/dev/null; then
      warn "Tenants wiring incomplete; register mode may produce Applications that cannot sync until you bootstrap."
      read -r -p "Continue with register only? [y/N]: " cont || true
      [[ "${cont}" =~ ^[Yy]$ ]] || die "Aborted. Re-run with --mode both or bootstrap first."
    fi
  fi

  if [[ "${DO_BOOTSTRAP}" == true ]]; then
    plan_bootstrap
  fi

  if [[ "${DO_REGISTER}" == true ]]; then
    if [[ -n "${CONFIG_FILE}" ]]; then
      load_tenants_from_config
    else
      prompt_tenant_interactive
    fi
  fi

  print_plan

  if [[ ${#PLAN_LINES[@]} -eq 0 ]]; then
    log "Nothing to apply."
    exit 0
  fi

  # If only skips, still require confirm? Plan says confirm before every actual execution.
  # If there are no bootstrap and no tenant actions, exit.
  if [[ "${DO_BOOTSTRAP}" != true && ${#TENANT_ACTIONS[@]} -eq 0 ]]; then
    log "No write actions after skips. Exiting."
    exit 0
  fi

  confirm_do_it

  if [[ "${DO_BOOTSTRAP}" == true ]]; then
    apply_bootstrap
  fi
  if [[ "${DO_REGISTER}" == true && ${#TENANT_ACTIONS[@]} -gt 0 ]]; then
    apply_tenant_registration
  fi

  log ""
  log "Done. Review 'git status' / 'git diff', then commit when ready."
  health_check || true
}

main "$@"

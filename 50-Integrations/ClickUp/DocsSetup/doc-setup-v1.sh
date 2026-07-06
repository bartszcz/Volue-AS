#!/usr/bin/env bash
#
# doc-setup.sh / knowledge-base-structure.sh
#
# Bootstrap a "Knowledge Base" Space in ClickUp:
# - Creates (or reuses) a Space
# - Creates a set of Folders
# - Optionally creates Docs via v3 Docs API
#
# REQUIREMENTS:
#   - curl
#   - jq
#
# CONFIG (env vars):
CLICKUP_API_TOKEN="pk_43066209_XNXJJXEP6JQM54SNXD14948S7BTY0GG1"
CLICKUP_TEAM_ID="9012767431"
#
# OPTIONAL:
#   KB_CREATE_DOCS=true  - if set to "true", script will also create Docs via v3 Docs API
#
set -euo pipefail

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but not installed." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi

if [[ -z "${CLICKUP_API_TOKEN:-}" ]]; then
  echo "ERROR: CLICKUP_API_TOKEN is not set." >&2
  exit 1
fi

if [[ -z "${CLICKUP_TEAM_ID:-}" ]]; then
  echo "ERROR: CLICKUP_TEAM_ID is not set." >&2
  exit 1
fi

KB_CREATE_DOCS="${KB_CREATE_DOCS:-false}"

API_V2_BASE="https://api.clickup.com/api/v2"
API_V3_BASE="https://api.clickup.com/api/v3"

auth_header() {
  printf "Authorization: %s" "$CLICKUP_API_TOKEN"
}

# IMPORTANT: log to STDERR, not STDOUT
log() {
  printf "%s\n" "$*" >&2
}

#######################################
# BLUEPRINT
#######################################

read -r -d '' KB_BLUEPRINT <<'EOF' || true
{
  "space_name": "Knowledge Base",
  "space_color": "#FFD166",
  "folders": [
    {
      "name": "00. 📚 Index & Conventions",
      "docs": [
        "KB – How to use this space",
        "KB – Naming conventions & tags"
      ]
    },
    {
      "name": "01. 🔁 Incidents & Fixes",
      "docs": [
        "Incidents – Windows / AD",
        "Incidents – Azure / Entra / M365",
        "Incidents – Networking / Fortinet",
        "Incidents – Other"
      ]
    },
    {
      "name": "02. 📋 How-To Procedures",
      "docs": [
        "How-To – User onboarding / offboarding",
        "How-To – Backup / restore scenarios",
        "How-To – Regular maintenance checklists"
      ]
    },
    {
      "name": "03. 🧩 Architecture & Design",
      "docs": [
        "Architecture – Hyper-V & storage topology",
        "Architecture – Network & security zones",
        "Architecture – Cloud layout (Azure / Entra / AVD)"
      ]
    },
    {
      "name": "04. 🤖 Scripts & Automation",
      "docs": [
        "Scripts – PowerShell snippets",
        "Scripts – Python snippets",
        "Scripts – Logic Apps / n8n patterns"
      ]
    },
    {
      "name": "05. 🧪 Lab Notes & Experiments",
      "docs": [
        "Lab – Experiments index",
        "Lab – Performance tests",
        "Lab – Risky ideas & notes"
      ]
    }
  ]
}
EOF

SPACE_NAME="$(jq -r '.space_name' <<<"$KB_BLUEPRINT")"
SPACE_COLOR="$(jq -r '.space_color // "#4B7BEC"' <<<"$KB_BLUEPRINT")"

#######################################
# API helpers
#######################################

api_v2() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" \
      "${API_V2_BASE}${path}" \
      -H "$(auth_header)" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -sS -X "$method" \
      "${API_V2_BASE}${path}" \
      -H "$(auth_header)" \
      -H "Content-Type: application/json"
  fi
}

api_v3() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" \
      "${API_V3_BASE}${path}" \
      -H "$(auth_header)" \
      -H "accept: application/json" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -sS -X "$method" \
      "${API_V3_BASE}${path}" \
      -H "$(auth_header)" \
      -H "accept: application/json"
  fi
}

#######################################
# Space: get or create
#######################################

get_space_by_name() {
  local team_id="$1"
  local name="$2"

  api_v2 GET "/team/${team_id}/space" |
    jq -r --arg name "$name" '.spaces[] | select(.name == $name) | .id' |
    head -n1
}

create_space() {
  local team_id="$1"
  local name="$2"
  local color="$3"

  log "Creating Space: ${name}"

  local body
  body="$(jq -n \
    --arg name "$name" \
    --arg color "$color" \
    '{name: $name, color: $color}'
  )"

  api_v2 POST "/team/${team_id}/space" "$body" | jq -r '.id'
}

ensure_space() {
  local team_id="$1"
  local name="$2"
  local color="$3"

  local space_id
  space_id="$(get_space_by_name "$team_id" "$name" || true)"

  if [[ -n "$space_id" && "$space_id" != "null" ]]; then
    log "Found existing Space: ${name}"
    log "  -> space_id = ${space_id}"
    printf "%s" "$space_id"
    return 0
  fi

  space_id="$(create_space "$team_id" "$name" "$color")"
  if [[ -z "$space_id" || "$space_id" == "null" ]]; then
    echo "ERROR: Failed to create Space '${name}'." >&2
    exit 1
  fi
  log "  -> space_id = ${space_id}"
  printf "%s" "$space_id"
}

#######################################
# Folders: get or create
#######################################

get_folder_by_name() {
  local space_id="$1"
  local name="$2"

  api_v2 GET "/space/${space_id}/folder" |
    jq -r --arg name "$name" '.folders[] | select(.name == $name) | .id' |
    head -n1
}

create_folder() {
  local space_id="$1"
  local name="$2"

  log "  Creating Folder: ${name}"

  local body
  body="$(jq -n --arg name "$name" '{name: $name}')"

  api_v2 POST "/space/${space_id}/folder" "$body" | jq -r '.id'
}

ensure_folder() {
  local space_id="$1"
  local name="$2"

  local folder_id
  folder_id="$(get_folder_by_name "$space_id" "$name" || true)"

  if [[ -n "$folder_id" && "$folder_id" != "null" ]]; then
    log "  Found existing Folder: ${name}"
    log "    -> folder_id = ${folder_id}"
    printf "%s" "$folder_id"
    return 0
  fi

  folder_id="$(create_folder "$space_id" "$name")"
  if [[ -z "$folder_id" || "$folder_id" == "null" ]]; then
    echo "ERROR: Failed to create Folder '${name}'." >&2
    exit 1
  fi
  log "    -> folder_id = ${folder_id}"
  printf "%s" "$folder_id"
}

#######################################
# Docs (v3): create (only if enabled)
#######################################

create_doc() {
  local workspace_id="$1"
  local title="$2"

  log "    Creating Doc: ${title}"

  local body
  body="$(jq -n --arg name "$title" '{name: $name}')"

  api_v3 POST "/workspaces/${workspace_id}/docs" "$body" | jq -r '.id'
}

#######################################
# MAIN
#######################################

main() {
  local team_id="${CLICKUP_TEAM_ID}"

  log "Using Workspace/Team ID: ${team_id}"
  log "KB_CREATE_DOCS = ${KB_CREATE_DOCS}"

  # 1. Ensure Space
  local space_id
  space_id="$(ensure_space "$team_id" "$SPACE_NAME" "$SPACE_COLOR")"

  echo "Space: ${SPACE_NAME}"
  echo "Space ID: ${space_id}"

  # 2. Folders + (optionally) Docs
  log ""
  log "Processing Folders and Docs for Space '${SPACE_NAME}'..."

  jq -c '.folders[]' <<<"$KB_BLUEPRINT" | \
  while IFS= read -r folder; do
    folder_name="$(jq -r '.name' <<<"$folder")"
    folder_id="$(ensure_folder "$space_id" "$folder_name")"

    if [[ "$KB_CREATE_DOCS" == "true" ]]; then
      jq -r '.docs[]?' <<<"$folder" | \
      while IFS= read -r doc_title; do
        [[ -z "$doc_title" ]] && continue
        doc_id="$(create_doc "$team_id" "$doc_title")"
        log "      -> doc_id = ${doc_id}"
      done
    fi

    log ""
  done

  echo "Knowledge Base structure setup complete."
  if [[ "$KB_CREATE_DOCS" == "true" ]]; then
    echo "Docs were created at Workspace level (visible in Docs search)."
  else
    echo "Docs creation is currently disabled (KB_CREATE_DOCS=false)."
  fi
}

main "$@"

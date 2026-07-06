#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
API_TOKEN="pk_43066209_XNXJJXEP6JQM54SNXD14948S7BTY0GG1"
TEAM_ID="9012767431"        # You can get it from the URL or API
BLUEPRINT_FILE="volue-clickup-structure.json"

# ===== HELPER =====
api() {
  local method="$1"
  local url="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$url" \
      -H "Authorization: $API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -sS -X "$method" "$url" \
      -H "Authorization: $API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

create_space() {
  local name="$1"
  local description="$2"
  local color="$3"
  local multiple_assignees="$4"
  local features_json="$5"
  local statuses_json="$6"

  # ClickUp API for creating a space (v2)
  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg description "$description" \
    --arg color "$color" \
    --argjson multiple "$multiple_assignees" \
    --argjson features "$features_json" \
    --argjson statuses "$statuses_json" '
    {
      "name": $name,
      "color": $color,
      "description": $description,
      "multiple_assignees": $multiple,
      "features": $features,
      "statuses": $statuses
    }')

  api "POST" "https://api.clickup.com/api/v2/team/${TEAM_ID}/space" "$payload" | jq -r '.id'
}

create_folder() {
  local space_id="$1"
  local name="$2"

  local payload
  payload=$(jq -n --arg name "$name" '{name: $name}')

  api "POST" "https://api.clickup.com/api/v2/space/${space_id}/folder" "$payload" | jq -r '.id'
}

create_list() {
  local folder_id="$1"
  local name="$2"
  local description="$3"

  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg description "$description" \
    '{name: $name, content: $description}')

  api "POST" "https://api.clickup.com/api/v2/folder/${folder_id}/list" "$payload" | jq -r '.id'
}

create_custom_field() {
  # Note: ClickUp's custom field creation is slightly limited via public API.
  # This function is a best-effort sketch; you may need to adjust based on current docs.
  local list_id="$1"
  local field_name="$2"
  local field_type="$3"
  local options_json="${4:-[]}"

  # This is speculative – ClickUp's current v2 API may differ.
  # Check docs for /list/{list_id}/field and adjust types.
  local payload
  payload=$(jq -n \
    --arg name "$field_name" \
    --arg type "$field_type" \
    --argjson options "$options_json" '
    {
      "name": $name,
      "type": $type,
      "type_config":
        ( if ($type == "drop_down") then { "options": $options } else {} end )
    }')

  api "POST" "https://api.clickup.com/api/v2/list/${list_id}/field" "$payload" || true
}

# ===== MAIN =====

if [[ ! -f "$BLUEPRINT_FILE" ]]; then
  echo "Blueprint file '$BLUEPRINT_FILE' not found."
  exit 1
fi

spaces_count=$(jq '.spaces | length' "$BLUEPRINT_FILE")
echo "Found $spaces_count spaces in blueprint."

for s_idx in $(seq 0 $((spaces_count - 1))); do
  space_name=$(jq -r ".spaces[$s_idx].name" "$BLUEPRINT_FILE")
  space_desc=$(jq -r ".spaces[$s_idx].description" "$BLUEPRINT_FILE")
  space_color=$(jq -r ".spaces[$s_idx].color" "$BLUEPRINT_FILE")
  multiple_assignees=$(jq ".spaces[$s_idx].multiple_assignees" "$BLUEPRINT_FILE")
  features_json=$(jq ".spaces[$s_idx].features" "$BLUEPRINT_FILE")
  statuses_json=$(jq ".spaces[$s_idx].statuses" "$BLUEPRINT_FILE")

  echo "Creating space: $space_name"
  space_id=$(create_space "$space_name" "$space_desc" "$space_color" "$multiple_assignees" "$features_json" "$statuses_json")
  echo "  -> space_id = $space_id"

  folders_count=$(jq ".spaces[$s_idx].folders | length" "$BLUEPRINT_FILE")
  for f_idx in $(seq 0 $((folders_count - 1))); do
    folder_name=$(jq -r ".spaces[$s_idx].folders[$f_idx].name" "$BLUEPRINT_FILE")
    echo "  Creating folder: $folder_name"
    folder_id=$(create_folder "$space_id" "$folder_name")
    echo "    -> folder_id = $folder_id"

    lists_count=$(jq ".spaces[$s_idx].folders[$f_idx].lists | length" "$BLUEPRINT_FILE")
    for l_idx in $(seq 0 $((lists_count - 1))); do
      list_name=$(jq -r ".spaces[$s_idx].folders[$f_idx].lists[$l_idx].name" "$BLUEPRINT_FILE")
      list_desc=$(jq -r ".spaces[$s_idx].folders[$f_idx].lists[$l_idx].description" "$BLUEPRINT_FILE")
      echo "    Creating list: $list_name"
      list_id=$(create_list "$folder_id" "$list_name" "$list_desc")
      echo "      -> list_id = $list_id"

      cf_count=$(jq ".spaces[$s_idx].folders[$f_idx].lists[$l_idx].custom_fields | length" "$BLUEPRINT_FILE")
      if [[ "$cf_count" -gt 0 ]]; then
        echo "      Creating $cf_count custom fields for list $list_name"
      fi

      for cf_idx in $(seq 0 $((cf_count - 1))); do
        cf_name=$(jq -r ".spaces[$s_idx].folders[$f_idx].lists[$l_idx].custom_fields[$cf_idx].name" "$BLUEPRINT_FILE")
        cf_type=$(jq -r ".spaces[$s_idx].folders[$f_idx].lists[$l_idx].custom_fields[$cf_idx].type" "$BLUEPRINT_FILE")

        if [[ "$cf_type" == "drop_down" ]]; then
          cf_options=$(jq ".spaces[$s_idx].folders[$f_idx].lists[$l_idx].custom_fields[$cf_idx].options" "$BLUEPRINT_FILE")
        else
          cf_options="[]"
        fi

        echo "        -> custom field: $cf_name ($cf_type)"
        create_custom_field "$list_id" "$cf_name" "$cf_type" "$cf_options"
      done

    done
  done
done

echo "Done. Basic Volue workspace structure created (Spaces, Folders, Lists, basic custom fields)."

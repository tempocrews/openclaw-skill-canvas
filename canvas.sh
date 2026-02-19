#!/usr/bin/env bash
set -euo pipefail

# Canvas LMS CLI wrapper for OpenClaw
# Usage: canvas.sh <command> <student_key> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find config: check OPENCLAW_WORKSPACE first, then common locations
CONFIG_PATHS=(
  "${OPENCLAW_WORKSPACE:-}/canvas-config.json"
  "$HOME/.openclaw/workspace/canvas-config.json"
)

CONFIG_FILE=""
for p in "${CONFIG_PATHS[@]}"; do
  if [[ -f "$p" ]]; then
    CONFIG_FILE="$p"
    break
  fi
done

if [[ -z "$CONFIG_FILE" ]]; then
  echo "Error: canvas-config.json not found. See SKILL.md for setup." >&2
  exit 1
fi

# --- Helpers ---

get_student_field() {
  local student="$1" field="$2"
  jq -r ".students[\"$student\"].$field // empty" "$CONFIG_FILE"
}

canvas_api() {
  local student="$1" endpoint="$2"
  shift 2
  local domain token
  domain=$(get_student_field "$student" "domain")
  token=$(get_student_field "$student" "token")

  if [[ -z "$domain" || -z "$token" ]]; then
    echo "Error: Student '$student' not found or missing domain/token in config." >&2
    exit 1
  fi

  local url="https://${domain}/api/v1${endpoint}"
  local all_results="[]"
  local page=1
  local per_page=50

  while true; do
    local separator="?"
    [[ "$url" == *"?"* ]] && separator="&"
    local page_url="${url}${separator}per_page=${per_page}&page=${page}"

    local response
    response=$(curl -s -H "Authorization: Bearer $token" "$@" "$page_url")

    # Check for error response
    if echo "$response" | jq -e '.errors' &>/dev/null 2>&1; then
      echo "API Error: $response" >&2
      exit 1
    fi

    # If response is an array, merge; if object, return directly
    if echo "$response" | jq -e 'type == "array"' &>/dev/null 2>&1; then
      local count
      count=$(echo "$response" | jq 'length')
      all_results=$(echo "$all_results" "$response" | jq -s '.[0] + .[1]')
      if (( count < per_page )); then
        break
      fi
      ((page++))
    else
      echo "$response"
      return
    fi
  done

  echo "$all_results"
}

# --- Commands ---

cmd_courses() {
  local student="$1"
  local name
  name=$(get_student_field "$student" "name")

  echo "📚 Courses for $name"
  echo "---"

  canvas_api "$student" "/courses?enrollment_state=active" | jq -r '
    sort_by(.name) |
    .[] |
    select(.workflow_state == "available") |
    "• \(.name) (\(.course_code // "no code"))"
  '
}

cmd_assignments() {
  local student="$1"
  shift
  local days=14

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local name
  name=$(get_student_field "$student" "name")
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local future_iso
  future_iso=$(date -u -d "+${days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+${days}d +%Y-%m-%dT%H:%M:%SZ)

  echo "📋 Upcoming assignments for $name (next ${days} days)"
  echo "---"

  # Get all active courses first
  local courses
  courses=$(canvas_api "$student" "/courses?enrollment_state=active" | jq -r '
    .[] | select(.workflow_state == "available") | "\(.id)|\(.name)"
  ')

  local found=0
  while IFS='|' read -r course_id course_name; do
    [[ -z "$course_id" ]] && continue

    local assignments
    assignments=$(canvas_api "$student" "/courses/${course_id}/assignments?order_by=due_at&bucket=upcoming" | jq -r --arg now "$now_iso" --arg future "$future_iso" '
      [.[] |
        select(.due_at != null) |
        select(.due_at >= $now and .due_at <= $future)
      ] |
      sort_by(.due_at) |
      .[] |
      "  📅 \(.due_at[:10]) — \(.name) \(if .submission_types | contains(["online_quiz"]) then "🧪" elif .submission_types | contains(["discussion_topic"]) then "💬" else "" end)"
    ')

    if [[ -n "$assignments" ]]; then
      echo ""
      echo "📖 $course_name:"
      echo "$assignments"
      found=1
    fi
  done <<< "$courses"

  if [[ $found -eq 0 ]]; then
    echo "No upcoming assignments in the next ${days} days! 🎉"
  fi
}

cmd_overdue() {
  local student="$1"
  local name
  name=$(get_student_field "$student" "name")

  echo "⚠️ Overdue assignments for $name"
  echo "---"

  local courses
  courses=$(canvas_api "$student" "/courses?enrollment_state=active" | jq -r '
    .[] | select(.workflow_state == "available") | "\(.id)|\(.name)"
  ')

  local found=0
  while IFS='|' read -r course_id course_name; do
    [[ -z "$course_id" ]] && continue

    local assignments
    assignments=$(canvas_api "$student" "/courses/${course_id}/assignments?bucket=overdue" | jq -r '
      [.[] | select(.due_at != null)] |
      sort_by(.due_at) |
      .[] |
      "  ❗ Due \(.due_at[:10]) — \(.name)"
    ')

    if [[ -n "$assignments" ]]; then
      echo ""
      echo "📖 $course_name:"
      echo "$assignments"
      found=1
    fi
  done <<< "$courses"

  if [[ $found -eq 0 ]]; then
    echo "No overdue assignments! 🎉"
  fi
}

cmd_grades() {
  local student="$1"
  local name user_id
  name=$(get_student_field "$student" "name")
  user_id=$(get_student_field "$student" "userId")

  echo "📊 Grades for $name"
  echo "---"

  local courses
  courses=$(canvas_api "$student" "/courses?enrollment_state=active&include[]=total_scores" | jq -r '
    .[] |
    select(.workflow_state == "available") |
    select(.enrollments != null) |
    . as $c |
    .enrollments[] |
    select(.type == "student") |
    "• \($c.name): \(
      if $c.hide_final_grades == true then "🔒 Hidden"
      elif .computed_current_score != null then "\(.computed_current_score)% (\(.computed_current_grade // "N/A"))"
      else "No grade data"
      end
    )"
  ')

  if [[ -n "$courses" ]]; then
    echo "$courses"
  else
    echo "No grade data available."
  fi
}

cmd_summary() {
  local student="$1"
  local name
  name=$(get_student_field "$student" "name")

  echo "═══════════════════════════════════════"
  echo "  📚 Canvas Summary: $name"
  echo "═══════════════════════════════════════"
  echo ""

  cmd_grades "$student"
  echo ""
  cmd_overdue "$student"
  echo ""
  cmd_assignments "$student" --days 7
}

# --- Main ---

COMMAND="${1:-help}"
STUDENT="${2:-}"

case "$COMMAND" in
  courses)
    [[ -z "$STUDENT" ]] && { echo "Usage: canvas.sh courses <student>"; exit 1; }
    cmd_courses "$STUDENT"
    ;;
  assignments)
    [[ -z "$STUDENT" ]] && { echo "Usage: canvas.sh assignments <student> [--days N]"; exit 1; }
    shift 2
    cmd_assignments "$STUDENT" "$@"
    ;;
  overdue)
    [[ -z "$STUDENT" ]] && { echo "Usage: canvas.sh overdue <student>"; exit 1; }
    cmd_overdue "$STUDENT"
    ;;
  grades)
    [[ -z "$STUDENT" ]] && { echo "Usage: canvas.sh grades <student>"; exit 1; }
    cmd_grades "$STUDENT"
    ;;
  summary)
    [[ -z "$STUDENT" ]] && { echo "Usage: canvas.sh summary <student>"; exit 1; }
    cmd_summary "$STUDENT"
    ;;
  help|--help|-h)
    echo "Canvas LMS CLI — Query assignments, grades, and courses"
    echo ""
    echo "Usage: canvas.sh <command> <student_key> [options]"
    echo ""
    echo "Commands:"
    echo "  courses      List active courses"
    echo "  assignments  Upcoming assignments (--days N, default 14)"
    echo "  overdue      Overdue assignments"
    echo "  grades       Current grades"
    echo "  summary      Full digest (grades + overdue + upcoming)"
    echo ""
    echo "Student keys are defined in canvas-config.json"
    ;;
  *)
    echo "Unknown command: $COMMAND (try 'help')" >&2
    exit 1
    ;;
esac

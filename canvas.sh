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

# --- Course Filtering ---

get_skip_courses() {
  jq -r '.skipCourses // [] | .[]' "$CONFIG_FILE" 2>/dev/null
}

should_skip_course() {
  local course_name="$1"
  local pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if [[ "${course_name,,}" == *"${pattern,,}"* ]]; then
      return 0
    fi
  done < <(get_skip_courses)
  return 1
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

cmd_priorities() {
  local student="$1"
  shift
  local limit=10
  local show_all=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --all) show_all=1; shift ;;
      *) shift ;;
    esac
  done

  local name
  name=$(get_student_field "$student" "name")
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "🎯 Priority assignments for $name"
  echo "═══════════════════════════════════════"

  # Get active courses with weighting info
  local courses_json
  courses_json=$(canvas_api "$student" "/courses?enrollment_state=active")

  # Collect all priority items as JSON
  local all_items="[]"

  while IFS='|' read -r course_id course_name is_weighted; do
    [[ -z "$course_id" ]] && continue

    # Skip non-academic courses
    if should_skip_course "$course_name"; then
      continue
    fi

    # Fetch assignment groups for weight info
    local groups_json
    groups_json=$(canvas_api "$student" "/courses/${course_id}/assignment_groups")

    # Fetch assignments with submissions
    local assignments_json
    assignments_json=$(canvas_api "$student" "/courses/${course_id}/assignments?include[]=submission")

    # Process assignments through jq
    local items
    items=$(echo "$assignments_json" | jq -c --arg course "$course_name" \
      --arg weighted "$is_weighted" \
      --arg now "$now_iso" \
      --argjson groups "$groups_json" '
      [.[] |
        # Must have due date and points
        select(.due_at != null) |
        select((.points_possible // 0) > 0) |

        # Check if actionable: not submitted, or missing, or scored 0
        select(
          (.submission.submitted_at == null and .submission.workflow_state != "graded") or
          (.submission.missing == true) or
          (.submission.submitted_at == null and (.submission.score == null or .submission.score == 0))
        ) |

        # Look up group weight
        .assignment_group_id as $gid |
        ($groups | map(select(.id == $gid)) | .[0].group_weight // 0) as $gw |

        # Calculate effective score
        (if $weighted == "true" and $gw > 0
         then .points_possible * ($gw / 100)
         else .points_possible
         end) as $base |

        # Overdue check
        (if .due_at < $now then "overdue" else "upcoming" end) as $status |

        # Priority multiplier: upcoming gets 1.5x (full credit available)
        (if $status == "upcoming" then $base * 1.5 else $base end) as $score |

        {
          course: $course,
          name: .name,
          points: .points_possible,
          group_weight: $gw,
          due_at: .due_at,
          status: $status,
          score: ($score * 100 | round / 100),
          weighted: ($weighted == "true")
        }
      ]')

    if [[ "$items" != "[]" && "$items" != "null" && -n "$items" ]]; then
      all_items=$(echo "$all_items" "$items" | jq -s '.[0] + .[1]')
    fi

  done < <(echo "$courses_json" | jq -r '
    .[] |
    select(.workflow_state == "available") |
    "\(.id)|\(.name)|\(.apply_assignment_group_weights // false)"
  ')

  # Sort and display
  local count
  count=$(echo "$all_items" | jq 'length')

  if [[ "$count" -eq 0 || "$all_items" == "[]" ]]; then
    echo ""
    echo "Nothing actionable found! 🎉"
    return
  fi

  echo ""

  echo "$all_items" | jq -r --argjson limit "$limit" --arg now "$now_iso" '
    sort_by(-.score) |
    to_entries |
    .[:$limit] |
    .[] |
    "\(.key + 1)|\(.value.course)|\(.value.name)|\(.value.points)|\(.value.due_at[:10])|\(.value.status)|\(.value.score)|\(.value.group_weight)|\(.value.weighted)"
  ' | while IFS='|' read -r rank course aname points due status score gw weighted; do
    local status_str
    if [[ "$status" == "upcoming" ]]; then
      status_str="📅 DUE $due"
    else
      status_str="⚠️  OVERDUE (was due $due)"
    fi

    local weight_str=""
    if [[ "$weighted" == "true" && "$gw" != "0" ]]; then
      weight_str=" · ${gw}% weight"
    fi

    echo "#${rank}  ${course}"
    echo "    📝 ${aname}"
    echo "    ${status_str} · ${points} pts${weight_str} · Priority: ${score}"
    echo ""
  done

  local total_upcoming total_overdue
  total_upcoming=$(echo "$all_items" | jq '[.[] | select(.status == "upcoming")] | length')
  total_overdue=$(echo "$all_items" | jq '[.[] | select(.status == "overdue")] | length')

  echo "───────────────────────────────────────"
  echo "📊 ${total_upcoming} upcoming · ${total_overdue} overdue · showing top ${limit}"
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
  priorities)
    [[ -z "$STUDENT" ]] && { echo "Usage: canvas.sh priorities <student> [--limit N] [--all]"; exit 1; }
    shift 2
    cmd_priorities "$STUDENT" "$@"
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
    echo "  priorities   Weighted priority list (--limit N, --all)"
    echo ""
    echo "Student keys are defined in canvas-config.json"
    ;;
  *)
    echo "Unknown command: $COMMAND (try 'help')" >&2
    exit 1
    ;;
esac

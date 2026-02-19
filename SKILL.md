---
name: canvas-lms
description: "Query Canvas LMS for student assignments, grades, and course info. Use when: (1) checking upcoming or overdue assignments, (2) getting grades or course lists, (3) generating homework digests for students. NOT for: submitting assignments, modifying Canvas data, or admin operations."
metadata:
  openclaw:
    emoji: "📚"
    requires:
      bins: ["jq", "curl"]
---

# Canvas LMS Skill

Query the Canvas LMS API to track assignments, grades, and courses for students.

## When to Use

✅ **USE this skill when:**
- Checking what assignments are due soon or overdue
- Getting a student's current grades
- Listing courses for a student
- Generating a homework status digest
- Proactive homework check-ins (heartbeat or cron)

❌ **DON'T use this skill when:**
- Submitting or modifying assignments (read-only)
- Canvas admin operations
- Non-Canvas LMS platforms

## Setup

1. Each student needs a Canvas API access token:
   - Log into Canvas → Account → Settings → Approved Integrations → + New Access Token
2. Create `canvas-config.json` in the workspace:

```json
{
  "students": {
    "student_name": {
      "name": "Display Name",
      "domain": "school.instructure.com",
      "userId": 12345,
      "token": "TOKEN_HERE"
    }
  }
}
```

## Commands

All commands use `canvas.sh` in this skill's directory.

```bash
# List active courses
./canvas.sh courses <student_key>

# Upcoming assignments (next 14 days by default)
./canvas.sh assignments <student_key> [--days N]

# Overdue assignments
./canvas.sh overdue <student_key>

# Grades (where available)
./canvas.sh grades <student_key>

# Full digest: courses + upcoming + overdue
./canvas.sh summary <student_key>

# Weighted priority list — what to work on first
./canvas.sh priorities <student_key> [--limit N] [--all]
```

## Priority Algorithm

The `priorities` command ranks assignments by grade impact:

1. **Effective score** = `points_possible × (group_weight / 100)` for weighted courses, or raw points otherwise
2. **Upcoming bonus** = 1.5× multiplier (full credit still available)
3. **Overdue** = no multiplier (partial credit)
4. Sorted by priority score descending

Non-academic courses (Advisory, Study Hall, theater) are filtered via `skipCourses` in config.

`<student_key>` matches a key in `canvas-config.json` (e.g., `willa`, `clara`).

## Configuration

The config file is at `WORKSPACE/canvas-config.json` where WORKSPACE is the OpenClaw workspace directory.

### Config Schema

```json
{
  "skipCourses": ["Advisory", "Study Hall"],
  "students": {
    "<key>": {
      "name": "string - display name",
      "domain": "string - Canvas instance domain",
      "userId": "number - Canvas user ID",
      "token": "string - API access token"
    }
  }
}
```

## Notes

- Some schools hide final grades via API (`hide_final_grades: true`). Assignment-level grades may still be available.
- Canvas API rate limit: 700 requests per 10 minutes per token. The script handles pagination automatically.
- Tokens don't expire by default but can be revoked. If a token stops working, regenerate from Canvas settings.
- All data is read-only. This skill never modifies Canvas data.

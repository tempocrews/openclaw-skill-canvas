# Canvas LMS Skill for OpenClaw

📚 Query Canvas LMS for student assignments, grades, and course info.

An [OpenClaw](https://openclaw.ai) skill that lets your AI assistant track homework, assignments, and grades across multiple students and Canvas instances.

## Features

- **Multi-student support** — Track multiple children across different schools/Canvas domains
- **Assignment tracking** — Upcoming and overdue assignments
- **Grade monitoring** — Current grades where available
- **Digest summaries** — Combined status reports
- **Proactive check-ins** — Works with OpenClaw heartbeats and cron for automated homework reminders

## Setup

### 1. Get Canvas API Tokens

For each student:
1. Log into Canvas (via your school's login)
2. Go to **Account → Settings**
3. Scroll to **Approved Integrations**
4. Click **+ New Access Token**
5. Copy the token (it's only shown once!)

### 2. Install the Skill

```bash
# Via ClawHub (when published)
clawhub install canvas-lms

# Or clone directly
git clone https://github.com/tempocrews/openclaw-skill-canvas.git
```

### 3. Configure

Copy the example config to your OpenClaw workspace:

```bash
cp canvas-config.example.json ~/.openclaw/workspace/canvas-config.json
```

Edit `canvas-config.json` with your students' details:

```json
{
  "students": {
    "kidname": {
      "name": "Kid Name",
      "domain": "school.instructure.com",
      "userId": 12345,
      "token": "YOUR_TOKEN_HERE"
    }
  }
}
```

## Usage

Your OpenClaw agent will use this skill automatically when you ask about homework, assignments, or grades.

**Example prompts:**
- "What's due this week for Willa?"
- "Any overdue assignments?"
- "How are grades looking?"
- "Give me a homework digest for all students"

### CLI Usage

```bash
./canvas.sh courses <student>        # List courses
./canvas.sh assignments <student>    # Upcoming (14 days)
./canvas.sh assignments <student> --days 7  # Upcoming (7 days)
./canvas.sh overdue <student>        # Overdue work
./canvas.sh grades <student>         # Current grades
./canvas.sh summary <student>        # Full digest
```

## Privacy & Security

- `canvas-config.json` is `.gitignore`'d — tokens never leave your machine
- All API access is **read-only** — the skill never modifies Canvas data
- Student data stays local to your OpenClaw instance

## Requirements

- `curl` and `jq` (usually pre-installed)
- Canvas API access tokens for each student
- OpenClaw (for agent integration)

## License

MIT

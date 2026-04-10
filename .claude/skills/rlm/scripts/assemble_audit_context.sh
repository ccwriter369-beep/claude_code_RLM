#!/usr/bin/env bash
# Assemble targeted context files for RLM security audit passes.
#
# Usage:
#   ./assemble_audit_context.sh <project_path> [pass_name]
#
# If pass_name is omitted, assembles all 4 standard passes.
# Output: .claude/rlm_state/audit_<pass>_context.txt
#
# Each file contains relevant source files concatenated with
# "# ===== FILE: <path> =====" delimiters for the REPL to parse.

set -euo pipefail

PROJECT="${1:?Usage: assemble_audit_context.sh <project_path> [pass_name]}"
PASS="${2:-all}"
OUTDIR=".claude/rlm_state"
mkdir -p "$OUTDIR"

# Detect language extensions
EXTS=""
for f in "$PROJECT"/{package.json,tsconfig.json}; do
  [ -f "$f" ] && EXTS="$EXTS --include=*.js --include=*.ts --include=*.tsx"
done
for f in "$PROJECT"/{pyproject.toml,setup.py,requirements.txt}; do
  [ -f "$f" ] && EXTS="$EXTS --include=*.py"
done
for f in "$PROJECT"/Cargo.toml; do
  [ -f "$f" ] && EXTS="$EXTS --include=*.rs"
done
for f in "$PROJECT"/go.mod; do
  [ -f "$f" ] && EXTS="$EXTS --include=*.go"
done
# Fallback: common web languages
[ -z "$EXTS" ] && EXTS="--include=*.py --include=*.js --include=*.ts --include=*.go --include=*.rs --include=*.rb"

EXCLUDE="--exclude-dir=node_modules --exclude-dir=venv --exclude-dir=.venv --exclude-dir=__pycache__ --exclude-dir=.git --exclude-dir=vendor --exclude-dir=target --exclude-dir=dist --exclude-dir=build"

assemble() {
  local pass_name="$1"
  local pattern="$2"
  local ctx="$OUTDIR/audit_${pass_name}_context.txt"
  > "$ctx"

  local count=0
  while IFS= read -r f; do
    echo "# ===== FILE: $f =====" >> "$ctx"
    cat "$f" >> "$ctx"
    echo "" >> "$ctx"
    count=$((count + 1))
  done < <(eval "grep -rl '$pattern' '$PROJECT' $EXTS $EXCLUDE 2>/dev/null | grep -v test | head -20")

  local chars
  chars=$(wc -c < "$ctx")
  echo "$pass_name: $count files, $chars bytes -> $ctx"
}

if [ "$PASS" = "all" ] || [ "$PASS" = "injection" ]; then
  assemble "injection" \
    'query\|execute\|cursor\|subprocess\|system(\|popen\|raw(\|extra(\|format.*sql\|format.*query'
fi

if [ "$PASS" = "all" ] || [ "$PASS" = "auth" ]; then
  assemble "auth" \
    'auth\|login\|session\|jwt\|bearer\|token\|password\|credential\|permission\|rbac\|middleware'
fi

if [ "$PASS" = "all" ] || [ "$PASS" = "access" ]; then
  assemble "access" \
    'role\|admin\|permission\|authorize\|forbidden\|cors\|allow_origin\|path.*join\|open(\|send_file'
fi

if [ "$PASS" = "all" ] || [ "$PASS" = "data" ]; then
  assemble "data" \
    'log\.\|logger\.\|logging\.\|print(\|console\.log\|response\.\|serialize\|json_response\|render'
fi

echo ""
echo "Context files ready in $OUTDIR/"
echo "Next: python3 .claude/skills/rlm/scripts/rlm_repl.py init $OUTDIR/audit_<pass>_context.txt"

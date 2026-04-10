---
name: rlm
description: Run a Recursive Language Model-style loop for long-context tasks. Uses a persistent local Python REPL and an rlm-subcall subagent as the sub-LLM (llm_query).
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
---

# rlm (Recursive Language Model workflow)

Use this Skill when:
- The user provides (or references) a very large context file (docs, logs, transcripts, scraped webpages) that won't fit comfortably in chat context.
- You need to iteratively inspect, search, chunk, and extract information from that context.
- You can delegate chunk-level analysis to a subagent.

## Mental model

- Main Claude Code conversation = the root LM.
- Persistent Python REPL (`rlm_repl.py`) = the external environment.
- Subagent `rlm-subcall` = the sub-LM used like `llm_query`.

## How to run

### Inputs

This Skill reads `$ARGUMENTS`. Accept these patterns:
- `context=<path>` (required): path to the file containing the large context.
- `query=<question>` (required): what the user wants.
- Optional: `chunk_chars=<int>` (default ~200000) and `overlap_chars=<int>` (default 0).

If the user didn't supply arguments, ask for:
1) the context file path, and
2) the query.

### Step-by-step procedure

1. Initialise the REPL state
   ```bash
   python3 .claude/skills/rlm/scripts/rlm_repl.py init <context_path>
   python3 .claude/skills/rlm/scripts/rlm_repl.py status
   ```

2. Scout the context quickly
   ```bash
   python3 .claude/skills/rlm/scripts/rlm_repl.py exec -c "print(peek(0, 3000))"
   python3 .claude/skills/rlm/scripts/rlm_repl.py exec -c "print(peek(len(content)-3000, len(content)))"
   ```

3. Choose a chunking strategy
   - Prefer semantic chunking if the format is clear (markdown headings, JSON objects, log timestamps).
   - Otherwise, chunk by characters (size around chunk_chars, optional overlap).

4. Materialise chunks as files (so subagents can read them)
   ```bash
   python3 .claude/skills/rlm/scripts/rlm_repl.py exec <<'PY'
   paths = write_chunks('.claude/rlm_state/chunks', size=200000, overlap=0)
   print(len(paths))
   print(paths[:5])
   PY
   ```

5. Subcall loop (delegate to rlm-subcall)
   - For each chunk file, invoke the rlm-subcall subagent with:
     - the user query,
     - the chunk file path,
     - and any specific extraction instructions.
   - Keep subagent outputs compact and structured (JSON preferred).
   - Append each subagent result to buffers (either manually in chat, or by pasting into a REPL add_buffer(...) call).

6. Synthesis
   - Once enough evidence is collected, synthesise the final answer in the main conversation.
   - Optionally ask rlm-subcall once more to merge the collected buffers into a coherent draft.

## Guardrails

- Do not paste large raw chunks into the main chat context.
- Use the REPL to locate exact excerpts; quote only what you need.
- Subagents cannot spawn other subagents. Any orchestration stays in the main conversation.
- Keep scratch/state files under .claude/rlm_state/.

---

## Proven Workflow (from multi-pass security audit, 2026-03-07)

The following patterns produced high-quality results across 8 passes on a real codebase. Treat as the preferred approach for code analysis tasks.

### Context assembly — build it, don't paste it

Before initialising the REPL, assemble a targeted context file from the specific files relevant to the query:

```bash
CTX=.claude/rlm_state/<pass_name>_context.txt
for f in path/to/file1.py path/to/file2.py; do
  echo "# ===== FILE: $f =====" >> "$CTX"
  cat "$f" >> "$CTX"
done
```

Check total size before proceeding — if under 200k chars, it fits in a single chunk and there is no multi-chunk complexity.

### Scout the import graph first (for codebase audits)

Before deciding which files to include in context, map the live call graph:

```bash
# Which files import from a module of interest?
grep -rn "from <module>\|import <module>" /path/to/project \
  --include="*.py" | grep -v "tests/\|venv\|__pycache__" | sort

# Which non-module files are actually wired into the app?
grep -n "include_router\|from routes\|from services" app_prod.py app.py
```

This prevents auditing deprecated or dead-code paths. In one session this revealed that 7 passes had been on a deprecated v1 path while v2 was the live production path — catching it early saves the entire audit from being misdirected.

### Question-driven subcall prompts

Instead of "find bugs in this file", give the subcall agent a numbered list of specific questions to answer with quoted evidence. This produces:
- Precise findings (exact lines, not paraphrases)
- Complete coverage (agent must answer every question, even if "code is correct here")
- Comparable confidence (severity + v1_comparison fields make cross-pass synthesis easy)

Template:
```
Hunt for these specific categories:
Q1: [specific question about one security property]
Q2: [specific question about another property]
...
Output: JSON array to .claude/rlm_state/subcall_<name>_findings.json with fields:
  id, question, title, severity, finding, exact_lines, exploit_scenario
```

### REPL peek before burning a subcall

When a prior finding looks suspicious (truncated code, missing assignment), use the REPL to verify before classifying it:

```bash
python3 .claude/skills/rlm/scripts/rlm_repl.py exec -c "print(peek(0, 2000))"
```

This caught a false positive in pass 1 that would have been written to the master output and required a retraction.

### Parallel subcalls for independent file groups

When auditing multiple independent modules in one pass, dispatch two subcalls simultaneously (one per file group) and merge their JSON outputs:

```bash
# Subcall A: files 1-2 → subcall_a_findings.json
# Subcall B: files 3-4 → subcall_b_findings.json
# Then merge in REPL:
python3 .claude/skills/rlm/scripts/rlm_repl.py exec -c "
import json
a = json.load(open('.claude/rlm_state/subcall_a_findings.json'))
b = json.load(open('.claude/rlm_state/subcall_b_findings.json'))
merged = a + b
json.dump(merged, open('.claude/rlm_state/subcall_merged.json', 'w'), indent=2)
print(len(merged), 'findings merged')
"
```

### Run the test suite before synthesis

After all audit passes, run the project's test suite. Failing tests often reveal that a module is broken (not just untested), which is a stronger finding than a code-level vulnerability. In one session, 29 failures in `test_m98_write_admission.py` revealed that the ontology write admission module didn't satisfy its own specification — the code-level audit alone would not have surfaced this.

```bash
cd /path/to/project && python3 -m pytest tests/ -q --tb=no 2>&1 | tail -20
```

### Output structure for multi-pass work

Each subcall writes JSON to `.claude/rlm_state/subcall_<passname>_findings.json`.
All findings are synthesised into a single master document (never split across files).
The master document grows one section per pass — new passes are inserted before the summary table, not after it.

### Gotchas

- `add_buffer()` takes exactly 1 positional argument (the string). Use `add_buffer(json.dumps(data))` not `add_buffer("name", data)`.
- `state.pkl` is overwritten on each `init` — don't mix findings across passes in the same buffer without manually merging JSONs first.
- Use chunk directories with unique names per pass (e.g. `chunks_lc`, `chunks_v2`) so different passes don't overwrite each other's materialised files.
- For codebase analysis, always exclude `venv/`, `.venv/`, `__pycache__/` from grep patterns.
- Use the Write tool (not bash heredoc) to write large output files — heredoc via Bash tool can be rejected by permission hooks.

---

## Templates

### Security Audit (`templates/security-audit.md`)

Three-tier model escalation: Haiku (extraction) → Sonnet (exploitability) → Opus (exploit chains).
Opus is triggered when the orchestrator sees 2+ critical-trio hits (injection, IDOR, broken auth) plus other categories in the Sonnet findings.

A structured 8-pass OWASP-aligned audit template with:
- Phase 0 recon patterns for mapping attack surface
- Context assembly helper script (`scripts/assemble_audit_context.sh`)
- 4 subcall prompt templates (Injection, Access Control, Crypto, Data Exposure)
- Synthesis, validation, and cross-model verification phases
- Structured JSON finding format with severity, exploit scenarios, and fix recommendations

Quick start:
```bash
# Assemble context for all 4 standard passes
bash .claude/skills/rlm/scripts/assemble_audit_context.sh /path/to/project

# Run a single pass
/rlm context=.claude/rlm_state/audit_injection_context.txt query="Run security audit pass 1 (Injection) using templates/security-audit.md Template A"
```

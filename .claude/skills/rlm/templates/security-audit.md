# RLM Security Audit Template

A structured, multi-pass approach to finding vulnerabilities in a codebase using the RLM
chunked-analysis pipeline. Designed for defensive use: find your own holes before something
else does.

## Prerequisites

- The `/rlm` skill is available
- Target codebase is accessible from this machine
- You know the primary language(s) and framework(s)

## Phase 0: Recon

Before burning any subcall tokens, map the attack surface. Use Grep to find:

1. **Entry points** — route decorators, handler registrations, URL patterns
2. **User input surfaces** — request body/params/query/headers/cookies accessors
3. **Auth/authz** — JWT, session, RBAC, middleware, guard, policy references
4. **Database/external calls** — cursor, query, ORM raw queries, HTTP clients
5. **Secrets surface** — environment variable reads, hardcoded credential patterns

Save the recon output — it determines which passes to run and which files to include.

## Phase 1: Context Assembly

Build targeted context files per audit pass. Never dump the entire repo into one file.

```bash
mkdir -p .claude/rlm_state

# Example: assemble auth-related files
CTX=.claude/rlm_state/audit_auth_context.txt
> "$CTX"
for f in $(grep -rl "auth\|session\|jwt\|login\|permission" /path/to/project/src --include="*.py" | grep -v test | head -15); do
  echo "# ===== FILE: $f =====" >> "$CTX"
  cat "$f" >> "$CTX"
done
wc -c "$CTX"  # check size — aim for <400k per context
```

## Phase 2: Audit Passes

Run one pass per threat category. Each pass = init REPL + subcall loop + findings JSON.

### Pass ordering (highest impact first)

| Pass | Category | OWASP | What to hunt |
|------|----------|-------|-------------|
| 1 | **Injection** | A03 | SQL injection, command injection, template injection, header injection |
| 2 | **Broken Auth** | A07 | Weak password policy, session fixation, token leakage |
| 3 | **Access Control** | A01 | IDOR, missing authz, privilege escalation, path traversal, CORS |
| 4 | **Crypto Failures** | A02 | Hardcoded secrets, weak hashing, missing encryption, insecure random |
| 5 | **Misconfiguration** | A05 | Debug mode in prod, default creds, verbose errors, missing headers |
| 6 | **Vuln Components** | A06 | Known CVEs in deps, outdated packages |
| 7 | **Data Exposure** | A04 | Sensitive data in logs, overly broad API responses, PII in URLs |
| 8 | **SSRF/Deser** | A10/A08 | User-controlled URLs in server fetches, unsafe deserialization |

### Running a pass

```bash
# 1. Init REPL with pass-specific context
python3 .claude/skills/rlm/scripts/rlm_repl.py init .claude/rlm_state/audit_<pass>_context.txt

# 2. Scout — peek at file boundaries
python3 .claude/skills/rlm/scripts/rlm_repl.py exec -c "
files = [m['match'] for m in grep(r'# ===== FILE: (.+) =====')]
print(f'{len(files)} files in context')
for f in files: print(f'  {f}')
"

# 3. Chunk if context >200k chars
python3 .claude/skills/rlm/scripts/rlm_repl.py exec -c "
paths = write_chunks('.claude/rlm_state/chunks_<pass>', size=200000, overlap=2000)
print(f'{len(paths)} chunks written')
"

# 4. Dispatch subcalls (see templates below)
# 5. Merge findings into .claude/rlm_state/subcall_<pass>_findings.json
```

## Phase 3: Subcall Prompt Templates

Each template gives the sub-LLM a numbered list of specific questions. This produces
precise findings with exact code evidence, not vague "this looks risky" output.

**Model**: Always use Sonnet for security subcalls. Do not use Haiku.
Tested on Juice Shop: Sonnet found 11/11 injection-class vulns, Haiku found 7/11.
Haiku misses configuration-level vulns (XXE, SSTI) and multi-hop data flows
(stored XSS via headers, ORM bypass). The cost difference is negligible per chunk.

### Template A: Injection Hunting

```
Read the file at {chunk_path}. This is a defensive security audit.

Hunt for INJECTION vulnerabilities. Answer each question with exact code evidence:

Q1: Are SQL queries built with string formatting instead of parameterized/prepared statements?
Q2: Does user input reach shell/process execution functions without sanitization?
Q3: Are there template rendering calls where user input is interpolated without escaping?
Q4: Does user input reach code execution or deserialization functions?
Q5: Are HTTP headers or redirect URLs constructed from user input without validation?
Q6: Are there ORM "raw query" calls that accept unsanitized input?

Output JSON to {output_path} — array of objects with fields:
  id, question, title, severity (CRITICAL/HIGH/MEDIUM/LOW/INFO/NONE),
  file, line_range, exact_code, exploit_scenario, fix_recommendation, confidence

If a question has no findings, include an entry with severity NONE and a brief explanation.
```

### Template B: Access Control

```
Read the file at {chunk_path}. Defensive security audit.

Hunt for BROKEN ACCESS CONTROL:

Q1: Are there endpoints that act without verifying the requesting user's identity?
Q2: Can a user access another user's resources by changing an ID (IDOR)?
Q3: Are admin endpoints reachable without role verification?
Q4: Can user input influence file paths the server reads/writes (path traversal)?
Q5: Are CORS headers set to allow arbitrary origins?
Q6: Do endpoints return data without filtering by the requesting user's permissions?

Output: same JSON format, IDs prefixed "AC-".
```

### Template C: Cryptographic Failures

```
Read the file at {chunk_path}. Defensive security audit.

Hunt for CRYPTOGRAPHIC and SECRETS vulnerabilities:

Q1: Are secrets, API keys, or tokens hardcoded in source?
Q2: Are passwords hashed with weak/deprecated algorithms instead of bcrypt/scrypt/argon2?
Q3: Is sensitive data stored or transmitted without encryption?
Q4: Are security-critical random values generated with non-cryptographic RNGs?
Q5: Do TLS/SSL settings allow outdated protocols or weak ciphers?
Q6: Are encryption keys derived from predictable sources or co-located with ciphertext?

Output: same JSON format, IDs prefixed "CRYPTO-".
```

### Template D: Data Exposure

```
Read the file at {chunk_path}. Defensive security audit.

Hunt for SENSITIVE DATA EXPOSURE:

Q1: Is sensitive data (passwords, tokens, PII) written to log files?
Q2: Do API responses include fields that should be filtered (hashes, internal IDs)?
Q3: Is PII included in URLs/query parameters (ending up in logs and browser history)?
Q4: Are stack traces or detailed errors returned to users in production?
Q5: Is sensitive data cached without proper controls (headers, cookie flags)?
Q6: Do database queries fetch all columns instead of specific needed fields?

Output: same JSON format, IDs prefixed "DATA-".
```

## Phase 4: Synthesis

After all passes, merge findings in the REPL:

```python
import json, glob

all_findings = []
for path in sorted(glob.glob('.claude/rlm_state/subcall_*_findings.json')):
    try:
        all_findings.extend(json.load(open(path)))
    except Exception as e:
        print(f"WARN: {path}: {e}")

# Deduplicate
seen = set()
deduped = []
for f in all_findings:
    key = (f.get('file',''), f.get('line_range',''), f.get('title',''))
    if key not in seen:
        seen.add(key)
        deduped.append(f)

sev_order = {'CRITICAL': 0, 'HIGH': 1, 'MEDIUM': 2, 'LOW': 3, 'INFO': 4, 'NONE': 5}
deduped.sort(key=lambda x: sev_order.get(x.get('severity','INFO'), 4))

with open('.claude/rlm_state/audit_master_findings.json', 'w') as fh:
    json.dump(deduped, fh, indent=2)

print(f'{len(deduped)} unique findings (from {len(all_findings)} total)')
for sev in ['CRITICAL','HIGH','MEDIUM','LOW','INFO']:
    count = sum(1 for f in deduped if f.get('severity') == sev)
    if count: print(f'  {sev}: {count}')
```

## Phase 4b: Escalation to Opus

After synthesis, the orchestrating model (you, in the main conversation) decides whether
to escalate to an Opus pass. You already have the findings — just apply this rule:

### The critical trio

**Injection, IDOR, broken auth.** These are the categories that chain into full compromise.

### Escalation rule

Escalate to `rlm-subcall-security-opus` if Sonnet found actionable findings (CRITICAL/HIGH/MEDIUM,
confidence high or medium) in:
- All 3 of the critical trio, OR
- 2 of the critical trio + at least 1 other category

Do NOT escalate if:
- 2 of the trio with nothing else (isolated findings, Sonnet is enough)
- 1 or 0 trio hits (low chain risk)

### What Opus does (different from Sonnet)

The Opus pass does NOT re-scan. Feed it the Sonnet findings JSON alongside the source
chunks. It looks for:
1. **Exploit chains** — how findings combine across categories into full attack narratives
2. **Bypass analysis** — can Sonnet's "partial" mitigations be circumvented?
3. **Race conditions** — timing-dependent vulnerabilities
4. **Authorization logic flaws** — multi-step state machine bypasses

## Phase 5: Validate (reduce false positives)

For every CRITICAL and HIGH finding:

1. **REPL peek** — read the exact lines cited. Is the code actually reachable?
2. **Import graph** — is this file wired into the live app, or dead code?
3. **Test suite** — do tests cover this path? A passing test with malicious input confirms it.
4. **Framework protections** — does the framework handle this automatically?

Mark false positives with `"status": "false_positive"` and a reason.

## Phase 6: Cross-Validation (optional, recommended)

Dispatch the same raw source files to independent models for independent review.
Never share one model's findings with another. See the Independent Code Review Protocol.

## Final Report Structure

```
# Security Audit — [Project Name]
## Date | Scope | Methodology

### Executive Summary
- Counts by severity
- Top risk areas

### Findings by Severity
CRITICAL > HIGH > MEDIUM > LOW
Each: title, file:line, description, exploit scenario, fix

### Passes Completed
| Pass | Category | Files | Chunks | Findings |

### False Positives Investigated
### Recommendations
### Limitations
```

## Quick Start

```
/rlm context=.claude/rlm_state/audit_injection_context.txt query="Run security audit pass 1 (Injection) using the template at .claude/skills/rlm/templates/security-audit.md. Use Template A. Output to .claude/rlm_state/subcall_injection_findings.json"
```

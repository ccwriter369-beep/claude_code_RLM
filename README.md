# Claude Code RLM

A minimal implementation of Recursive Language Models (RLM) using Claude Code as the scaffold. Implemented by [Brainqub3](https://brainqub3.com/).

## About

This repository provides a basic RLM setup that enables Claude to process documents and contexts that exceed typical context window limits. It implements the core RLM pattern where a root language model orchestrates sub-LLM calls over chunks of a large document.

**This is a basic implementation** of the RLM paper. For the full research, see:

> **Recursive Language Models**
> Alex L. Zhang, Tim Kraska, Omar Khattab
> MIT CSAIL
> [arXiv:2512.24601](https://arxiv.org/abs/2512.24601)

*Abstract: RLMs treat long prompts as part of an external environment and allow the LLM to programmatically examine, decompose, and recursively call itself over snippets of the prompt. RLMs can handle inputs up to two orders of magnitude beyond model context windows.*

## Architecture

This implementation maps to the RLM paper architecture as follows:

| RLM Concept | Implementation | Model |
|-------------|----------------|-------|
| Root LLM | Main Claude Code conversation | **Claude Opus 4.5** |
| Sub-LLM (`llm_query`) | `rlm-subcall` subagent | **Claude Haiku** |
| External Environment | Persistent Python REPL (`rlm_repl.py`) | Python 3 |

The root LLM (Opus 4.5) orchestrates the overall task, while delegating chunk-level analysis to the faster, lighter sub-LLM (Haiku). The Python REPL maintains state across invocations and provides utilities for chunking, searching, and managing the large context.

## Prerequisites

- **Claude Code account** - You need access to [Claude Code](https://claude.ai/claude-code), Anthropic's official CLI tool
- **Python 3** - For the persistent REPL environment

## Usage

1. **Clone this repository**
   ```bash
   git clone https://github.com/Brainqub3/claude_code_RLM.git
   cd claude_code_RLM
   ```

2. **Start Claude Code in the repository directory**
   ```bash
   claude
   ```

3. **Run the RLM skill**
   ```
   /rlm
   ```

4. **Follow the prompts** - The skill will ask for:
   - A path to your large context file
   - Your query/question about the content

The RLM workflow will then:
- Initialize the REPL with your context
- Chunk the document appropriately
- Delegate chunk analysis to the sub-LLM
- Synthesize results in the main conversation

## Working with Long Files

When using RLM to process large context files, it is recommended to save them in a dedicated `context/` folder within this project directory. This keeps your working files organized and separate from the RLM implementation code.

```bash
mkdir context
# Place your large documents here, e.g.:
# context/my_large_document.txt
# context/codebase_dump.py
```

## Security Warning

**This project is not intended for production use.**

If you plan to run Claude Code in `--dangerously-skip-permissions` mode:

1. **Ensure your setup is correct** - Verify all file paths and configurations before enabling this mode
2. **Run in an isolated folder** - Never run with skipped permissions in directories containing sensitive data, credentials, or system files
3. **Understand the risks** - This mode allows Claude to execute commands without confirmation prompts, which can lead to unintended file modifications or deletions

**Recommended**: Create a dedicated, isolated working directory specifically for RLM tasks when using dangerous mode:

```bash
# Example: Create an isolated workspace
mkdir ~/rlm-workspace
cd ~/rlm-workspace
git clone https://github.com/Brainqub3/claude_code_RLM.git
cd claude_code_RLM
```

## Security Audit Template

The RLM pipeline includes a security audit template (`templates/security-audit.md`) for defensive vulnerability scanning. Validated on OWASP Juice Shop with benchmarked results.

### Pipeline: Sonnet 8-pass + Opus chain analysis

| Stage | Model | Findings | Cost | Time |
|-------|-------|----------|------|------|
| 8 focused OWASP passes | Sonnet | 92 | ~$4.00 | ~6min (parallel) |
| Exploit chain analysis | Opus | 14 new (6 chains, 4 gaps, 4 bypasses) | ~$6.36 | ~7min |
| **Full pipeline** | | **106 total** | **~$10.34** | **~13min** |

### Model comparison (Juice Shop benchmark)

| Model | Pass Type | Findings | Unique | Cost |
|-------|-----------|----------|--------|------|
| Haiku | 1 injection pass | 7/11 (64%) | 0 | $0.07 |
| Sonnet | 1 injection pass | 11/11 (100%) | 0 | $0.56 |
| Sonnet | 8 focused passes | 92 | ~58 vs Opus blind | $3.99 |
| Opus | 1 blind pass | 34 | 7 | $4.04 |
| Opus | Informed (with Sonnet) | 14 new | All 14 new | $6.36 |

**Key finding**: Sonnet 8-pass beats Opus blind (92 vs 34 findings) at the same cost (~$4). Focus beats power. Opus adds value as a closer, not a replacement.

### Ground truth: Juice Shop has 111 known challenges

| Category | Known | Static Analysis Coverage |
|----------|-------|------------------------|
| Injection (SQLi, NoSQLi, SSTI) | 11 | Strong — all vectors found |
| Broken Access Control | 11 | Strong — IDOR, path traversal, missing auth |
| Broken Authentication | 9 | Strong — MD5, hardcoded keys, password reset |
| XSS (DOM, reflected, stored) | 9 | Partial — stored vectors found, DOM/reflected need browser |
| Sensitive Data Exposure | 16 | Strong — config leak, hash leak, API keys |
| Vulnerable Components | 9 | Strong — outdated deps, known CVEs |
| Cryptographic Issues | 5 | Strong — weak hashing, hardcoded secrets |
| XXE | 2 | Full |
| Security Misconfiguration | 4 | Full |
| Insecure Deserialization | 3 | Strong — vm RCE, YAML load |
| Improper Input Validation | 12 | Partial — server-side found, client-side needs browser |
| Unvalidated Redirects | 2 | Full |
| Broken Anti Automation | 4 | Not coverable — requires runtime interaction |
| Observability Failures | 4 | Partial — exposed metrics/logs found |
| Security through Obscurity | 3 | Not coverable — steganography, hidden content |
| Miscellaneous | 7 | Not coverable — chatbot manipulation, scoreboard |

**Static analysis covers ~75 of 111 challenges** (the ones with server-side code signatures). The remaining ~36 require runtime interaction (CAPTCHA bypass, DOM XSS, chatbot abuse, steganography) or client-side browser testing.

### Quick start

```bash
# 1. Assemble context for a target project
bash .claude/skills/rlm/scripts/assemble_audit_context.sh /path/to/project

# 2. Run passes via /rlm skill
/rlm context=.claude/rlm_state/audit_injection_context.txt \
  query="Security audit pass 1 (Injection) using templates/security-audit.md"
```

## Repository Structure

```
.
├── CLAUDE.md                          # Project instructions for Claude Code
├── .claude/
│   ├── agents/
│   │   ├── rlm-subcall.md            # Sub-LLM agent (Haiku, general use)
│   │   ├── rlm-subcall-security.md   # Security sub-LLM (Sonnet, data flow tracing)
│   │   └── rlm-subcall-security-opus.md # Chain analysis (Opus, escalation only)
│   └── skills/
│       └── rlm/
│           ├── SKILL.md              # RLM skill definition
│           ├── templates/
│           │   └── security-audit.md # 8-pass OWASP audit runbook
│           └── scripts/
│               ├── rlm_repl.py       # Persistent Python REPL
│               └── assemble_audit_context.sh # Context assembly helper
├── context/                           # Recommended location for large context files
└── README.md
```

## License

See [LICENSE](LICENSE) for details.

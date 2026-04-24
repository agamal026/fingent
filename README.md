# fingent — Finance Department Full Automation Sandbox

A secure, AI-powered automation sandbox for the Finance Department, built on [OpenClaw](https://openclaw.dev) and [DataSynth](https://github.com/datasynth-rs/datasynth). Automates Accounts Payable invoice processing and Month-End Close with a Human-in-the-Loop approval layer.

---

## Repository Layout

```
fingent/
├── openclaw.json                    # OpenClaw Gateway configuration
├── .env.example                     # Environment variable template
├── config/
│   ├── cron/jobs.json               # Overnight cron schedule
│   └── periods.json                 # Accounting period tracker
├── skills/
│   ├── ap-invoice-pipeline/
│   │   └── SKILL.md                 # AP Invoice Pipeline skill definition
│   └── monthly-close/
│       └── SKILL.md                 # Month-End Reconciliation skill definition
├── scripts/
│   ├── setup.sh                     # VPS provisioning & dependency installation
│   ├── generate-data.sh             # DataSynth synthetic data generation
│   └── validate.sh                  # Repo-native validation checks
├── Makefile                         # Common validate/build/setup commands
├── docker/
│   ├── Dockerfile                   # Ephemeral sandbox container image
│   └── requirements-sandbox.txt     # Python deps for sandbox
├── inbox/
│   └── invoices/                    # Drop incoming vendor PDFs here
├── archive/                         # Posted, duplicate, and error invoices
├── processing/                      # Transient JSON extraction workspace
├── reports/                         # Month-end close reports
├── logs/                            # Audit trail and operational logs
└── data/                            # Synthetic financial dataset (generated)
```

---

## 1. System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       VPS (Tencent Cloud Lighthouse)            │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  OpenClaw Gateway  (bind: 127.0.0.1:3000)                │  │
│  │  ┌────────────────┐   ┌──────────────────────────────┐   │  │
│  │  │ AP Invoice     │   │ Monthly Close Skill           │  │  │
│  │  │ Pipeline Skill │   │ (SKILL.md)                   │   │  │
│  │  └───────┬────────┘   └─────────────┬────────────────┘   │  │
│  │          │ tool calls               │ tool calls          │  │
│  │          ▼                          ▼                      │  │
│  │  ┌──────────────────────────────────────────────────┐     │  │
│  │  │ Docker Sandbox (ephemeral, --network=none)       │     │  │
│  │  │ fingent-sandbox:latest                           │     │  │
│  │  │ built from node:24-alpine + finance deps         │     │  │
│  │  └──────────────────────────────────────────────────┘     │  │
│  │                                                            │  │
│  │  HITL Approval Gate ──► Supervisor Webhook                 │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Key security properties:**
- Gateway bound to loopback (`127.0.0.1`) only
- All skill commands run in ephemeral Docker containers with no network (`--network=none`)
- Unknown senders require manual pairing (`dmPolicy: "pairing"`)
- Payment / email executions blocked pending human approval (`approvals.outbound`)

---

## 2. Quick Start

### Prerequisites
- Ubuntu 22.04 LTS or Debian 12 VPS
- Non-root user with `sudo` privileges
- `curl` installed

### Step 1 — Provision the VPS
```bash
git clone https://github.com/agamal026/fingent.git
cd fingent
bash scripts/setup.sh
```

This installs Node.js 24, Docker, OpenClaw (globally via npm), DataSynth, builds the hardened `fingent-sandbox:latest` image, and registers OpenClaw as a `systemd` service.

### Step 2 — Configure environment variables
```bash
cp .env.example .env
# Edit .env and fill in APPROVAL_WEBHOOK_URL, WEBHOOK_SECRET, etc.
```

If you want the gateway reachable over a secure Tailscale interface instead of loopback, set:
```bash
OPENCLAW_BIND_ADDRESS=100.x.y.z
```

### Step 3 — Generate synthetic financial data
```bash
bash scripts/generate-data.sh
```

Produces 113+ interconnected CSV/JSON files in `./data/`, all satisfying:
- **Double-entry**: Debits = Credits on every journal entry
- **Balance sheet**: Assets = Liabilities + Equity at every period end
- **GDPR-compliant**: fully synthetic, no real personal data

### Step 4 — Start the gateway
```bash
sudo systemctl start openclaw
openclaw status
```

---

## 3. Core Automation Flows

### AP Invoice Pipeline (`skills/ap-invoice-pipeline/SKILL.md`)

Drop vendor PDF invoices into `./inbox/invoices/`. The nightly cron job (02:00 UTC) processes them automatically:

1. **Pre-check** — skip if inbox is empty (no API credits wasted)
2. **Extraction** — structured JSON via `pdfplumber`
3. **Validation** — math checks + duplicate detection against GL
4. **PO Matching** — cross-reference against Purchase Orders & Goods Receipts
5. **Posting** — double-entry GL update *(HITL gate: requires human approval)*
6. **Archiving** — timestamped audit record appended to `logs/audit.log`

### Month-End Reconciliation (`skills/monthly-close/SKILL.md`)

Runs on days 28–31 of each month (02:00 UTC):

1. **Pre-check** — exit if period already closed (`config/periods.json`)
2. **Document verification** — confirm all required period documents exist
3. **Bank reconciliation** — match GL entries to synthetic IBAN transactions
4. **Expense mapping** — auto-classify unmapped cost centres
5. **Variance analysis** — flag >20% period-on-period movements
6. **Integrity assertions** — Debits=Credits and Assets=Liabilities+Equity
7. **Period close** *(HITL gate for material differences)*

---

## 4. Human-in-the-Loop (HITL)

The following actions **always pause** and send a webhook notification to the supervisor before proceeding:

| Trigger | Condition |
|---------|-----------|
| Invoice posting | Every invoice before GL write |
| Payment execution | Configured via `approvals.outbound.tools: ["exec"]` |
| External email | Configured via `approvals.outbound.tools: ["message"]` |
| Period close | When reconciling difference > `MATERIALITY_THRESHOLD` |

Configure your approval webhook URL in `.env`:
```
APPROVAL_WEBHOOK_URL=https://your-supervisor-webhook.example.com/approve
WEBHOOK_SECRET=your-secret-token
```

---

## 5. Overnight Execution

Cron jobs are defined in `config/cron/jobs.json` and deployed to `~/.openclaw/cron/jobs.json` by `setup.sh`.

| Job | Schedule | Pre-check |
|-----|----------|-----------|
| `ap-invoice-nightly` | `0 2 * * *` (02:00 UTC daily) | Inbox not empty |
| `monthly-close` | `0 2 28-31 * *` (02:00 UTC, month-end days) | Period not already closed |

**Idempotency guarantee:** Both skills are designed to produce identical results on repeated runs. Duplicate invoices are detected and skipped; closed periods are detected and skipped.

---

## 6. Development

### Validate the repo
```bash
make validate
```

This checks:
- shell script syntax
- JSON config validity
- OpenClaw skill/cron linkage
- required runtime directories
- Docker sandbox file references

### Build the sandbox Docker image
```bash
make build-sandbox
```

### Run a skill manually
```bash
openclaw run ap-invoice-pipeline
openclaw run monthly-close
```

### View logs
```bash
tail -f logs/audit.log
journalctl -u openclaw -f
```

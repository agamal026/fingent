# AP Invoice Pipeline

## Overview
Automates the full Accounts Payable invoice lifecycle: intake → extraction → validation → matching → posting → archiving.

## Trigger
- **Scheduled**: Nightly via cron at 02:00 UTC (see `config/cron/jobs.json`)
- **Manual**: `openclaw run ap-invoice-pipeline`

## Idempotency
This skill is fully idempotent. Each invoice is identified by its `invoiceNumber`. If a record with the same `invoiceNumber` already exists in the General Ledger, the posting step is skipped and the invoice is moved to `./archive/duplicates/` rather than re-posted.

## Pre-check (Quota Protection)
Before executing any LLM calls, the skill checks whether `./inbox/invoices/` contains at least one PDF. If the directory is empty, the skill exits immediately with status `NO_WORK` and consumes no API credits.

## Steps

### 1. Intake
```
SCAN ./inbox/invoices/ FOR *.pdf
IF count == 0: EXIT with status NO_WORK
```
All discovered PDF files are queued for sequential processing.

### 2. Extraction
For each PDF:
```
EXTRACT from <file>:
  - vendor_name       (string)
  - invoice_number    (string, unique identifier)
  - invoice_date      (ISO-8601 date)
  - due_date          (ISO-8601 date)
  - line_items[]      (description, quantity, unit_price, amount)
  - subtotal          (number)
  - tax_total         (number)
  - grand_total       (number)
  - currency          (ISO-4217 code)

OUTPUT: ./processing/<invoice_number>.json
```

### 3. Validation
```
VALIDATE each <invoice_number>.json:
  a. MATH CHECK: sum(line_items[].amount) == subtotal
  b. MATH CHECK: subtotal + tax_total == grand_total
  c. DUPLICATE CHECK: query GL for existing invoiceNumber
     IF duplicate FOUND: move PDF to ./archive/duplicates/<invoice_number>_<timestamp>.pdf, SKIP to next
  d. If any math check FAILS: move PDF to ./archive/errors/, log error, SKIP to next
```

### 4. PO & Receipt Matching
```
FOR each validated invoice:
  QUERY synthetic database:
    - Find Purchase Order matching vendor_name AND approximate grand_total (±5%)
    - Find Goods Receipt matching PO number AND invoice_date window (±30 days)
  IF PO found:   set match_status = "PO_MATCHED"
  IF receipt found: set match_status = "FULLY_MATCHED"
  ELSE:          set match_status = "UNMATCHED" (flag for human review)
```

### 5. Posting to General Ledger
```
FOR each invoice with match_status in ["PO_MATCHED", "FULLY_MATCHED"]:
  DEBIT:  Accounts Payable Control  grand_total
  CREDIT: Expense Account (derived from PO cost centre)  grand_total
  VERIFY: Debits == Credits (double-entry check)
  INSERT into gl_entries table

FOR each invoice with match_status == "UNMATCHED":
  FLAG for human review via approval webhook
  HALT — do not post until approved
```
> **HITL Gate**: Any posting action uses the `exec` tool and is subject to the outbound approval policy in `openclaw.json`. A webhook notification is sent to the supervisor with invoice details before execution proceeds.

### 6. Archiving
```
FOR each successfully posted invoice:
  MOVE PDF → ./archive/posted/<YYYY-MM>/<invoice_number>_<timestamp>.pdf
  WRITE audit record → ./logs/audit.log:
    {
      "timestamp": "<ISO-8601>",
      "invoiceNumber": "<string>",
      "vendor": "<string>",
      "amount": <number>,
      "currency": "<string>",
      "glEntryId": "<string>",
      "matchStatus": "<string>",
      "status": "POSTED"
    }
```

## Output Artefacts
| Path | Description |
|------|-------------|
| `./processing/<invoice_number>.json` | Extracted structured data (transient) |
| `./archive/posted/<YYYY-MM>/` | Archived PDFs for posted invoices |
| `./archive/duplicates/` | Duplicate invoices (not posted) |
| `./archive/errors/` | Invoices that failed validation |
| `./logs/audit.log` | Append-only NDJSON audit trail |

## Error Handling
- Math validation failure → archive to `errors/`, log, continue with next file
- Duplicate invoice → archive to `duplicates/`, log, continue with next file
- Unmatched invoice → send HITL approval request, pause workflow for that invoice
- GL posting failure → log error, do NOT retry automatically, alert supervisor

## Environment Variables
| Variable | Description |
|----------|-------------|
| `DB_CONNECTION_STRING` | Connection string for the synthetic GL database |
| `APPROVAL_WEBHOOK_URL` | Webhook URL for HITL approval notifications |
| `WEBHOOK_SECRET` | Bearer token for webhook authentication |
| `INVOICE_INBOX_PATH` | Override for invoice inbox directory (default: `./inbox/invoices`) |

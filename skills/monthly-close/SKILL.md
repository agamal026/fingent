# Monthly Close

## Overview
Automates the month-end reconciliation process: period verification → bank statement reconciliation → expense mapping → variance flagging → period close.

## Trigger
- **Scheduled**: Nightly cron on days 28–31 of each month at 02:00 UTC (see `config/cron/jobs.json`). The pre-check ensures the period is only closed once.
- **Manual**: `openclaw run monthly-close`

## Idempotency
This skill is fully idempotent. The current period's status is tracked in `config/periods.json`. If the current period already appears in `closedPeriods`, the skill exits immediately with status `ALREADY_CLOSED` without modifying any data.

## Pre-check (Quota Protection)
```
READ config/periods.json
IF currentPeriod IN closedPeriods: EXIT with status ALREADY_CLOSED
IF today NOT in last 4 days of current month: EXIT with status NOT_PERIOD_END
```

## Steps

### 1. Period Document Verification
```
FOR each required document type in [invoices, receipts, bank_statements, payroll_reports]:
  CHECK that all documents for currentPeriod exist in ./archive/
  REPORT missing documents to ./logs/close_<YYYY-MM>.log
  IF critical documents missing (bank_statements): HALT, alert supervisor
```

### 2. Bank Statement Reconciliation
```
LOAD synthetic bank statement for currentPeriod
  Fields: iban, transaction_date, description, debit, credit, balance

FOR each bank transaction:
  MATCH against GL entries using:
    - Amount (exact match)
    - Date (within ±2 business days)
    - IBAN reference
  IF matched: mark both records as RECONCILED
  IF unmatched: flag as OPEN_ITEM

COMPUTE:
  book_balance    = GL cash account closing balance
  bank_balance    = bank statement closing balance
  difference      = book_balance - bank_balance

IF difference != 0:
  LOG reconciling items to ./logs/close_<YYYY-MM>.log
  IF |difference| > MATERIALITY_THRESHOLD (default $1000):
    HALT, send HITL approval request with reconciliation summary
```
> **HITL Gate**: Any material reconciling difference triggers a human review request before the period can be closed.

### 3. Expense Mapping
```
FOR each GL entry in currentPeriod with cost_centre == NULL OR cost_centre == "UNMAPPED":
  ATTEMPT auto-classification using vendor_name and description
  IF classified: update cost_centre in GL
  ELSE: add to ./logs/unmapped_expenses_<YYYY-MM>.log
```

### 4. Variance Analysis
```
COMPUTE period totals:
  - Total Revenue
  - Total Cost of Goods Sold
  - Total Operating Expenses (by cost centre)
  - Net Income

COMPARE against prior period (currentPeriod - 1 month):
  FOR each category:
    variance_pct = (current - prior) / prior * 100
    IF |variance_pct| > VARIANCE_THRESHOLD (default 20%):
      FLAG in ./logs/variance_<YYYY-MM>.log

VERIFY double-entry integrity:
  total_debits  = SUM of all debit GL entries for period
  total_credits = SUM of all credit GL entries for period
  ASSERT total_debits == total_credits
  IF assertion fails: HALT immediately, alert supervisor (data integrity failure)

VERIFY balance sheet equation:
  assets      = SUM of asset account closing balances
  liabilities = SUM of liability account closing balances
  equity      = SUM of equity account closing balances
  ASSERT assets == (liabilities + equity)
  IF assertion fails: HALT immediately, alert supervisor (data integrity failure)
```

### 5. Period Close
```
IF all checks pass:
  SET period status = CLOSED in synthetic database
  APPEND currentPeriod to config/periods.json closedPeriods[]
  INCREMENT currentPeriod to next month
  GENERATE close report → ./reports/close_report_<YYYY-MM>.json

  WRITE audit record → ./logs/audit.log:
    {
      "timestamp": "<ISO-8601>",
      "event": "PERIOD_CLOSED",
      "period": "<YYYY-MM>",
      "bookBalance": <number>,
      "bankBalance": <number>,
      "totalDebits": <number>,
      "totalCredits": <number>,
      "assets": <number>,
      "liabilities": <number>,
      "equity": <number>,
      "unmappedExpenses": <count>,
      "openReconciliationItems": <count>
    }
```

## Output Artefacts
| Path | Description |
|------|-------------|
| `./logs/close_<YYYY-MM>.log` | Reconciliation working log |
| `./logs/unmapped_expenses_<YYYY-MM>.log` | Expenses that could not be auto-classified |
| `./logs/variance_<YYYY-MM>.log` | Variance analysis flags |
| `./reports/close_report_<YYYY-MM>.json` | Machine-readable close report |
| `./logs/audit.log` | Append-only NDJSON audit trail (shared with AP pipeline) |

## Error Handling
- Missing critical documents → HALT, alert supervisor
- Reconciliation difference above materiality threshold → HITL approval required
- Double-entry integrity failure → HALT immediately, escalate (never auto-resolve)
- Balance sheet equation failure → HALT immediately, escalate

## Environment Variables
| Variable | Description |
|----------|-------------|
| `DB_CONNECTION_STRING` | Connection string for the synthetic GL database |
| `APPROVAL_WEBHOOK_URL` | Webhook URL for HITL approval notifications |
| `WEBHOOK_SECRET` | Bearer token for webhook authentication |
| `MATERIALITY_THRESHOLD` | Dollar threshold for material reconciling items (default: 1000) |
| `VARIANCE_THRESHOLD` | Percentage threshold for variance flags (default: 20) |

#!/usr/bin/env bash
# =============================================================================
# Finance Department Full Automation Sandbox — Synthetic Data Generation
# Uses DataSynth (open-source Rust CLI) to produce GDPR-compliant financial data
# Usage: bash scripts/generate-data.sh [--output-dir ./data]
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-${REPO_DIR}/data}"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Pre-checks
# -----------------------------------------------------------------------------
command -v datasynth-data >/dev/null 2>&1 \
  || die "datasynth-data not found. Run scripts/setup.sh first."

mkdir -p "$OUTPUT_DIR"

# -----------------------------------------------------------------------------
# Generate the full audit-group dataset
# Over 113 interconnected output files covering:
#   - Chart of Accounts, GL entries
#   - Vendors, Purchase Orders, Goods Receipts, AP Invoices
#   - Customers, Sales Orders, AR Invoices
#   - Bank Statements (with synthetic IBANs)
#   - Payroll Reports
#   - Cost Centres, Budget lines
# All records satisfy:
#   - Double-entry: Debits == Credits on every journal
#   - Balance Sheet: Assets == Liabilities + Equity at every period end
#   - GDPR compliance: no real personal data, all synthetic
# -----------------------------------------------------------------------------
log "Starting synthetic data generation (preset: audit-group)..."
log "Output directory: ${OUTPUT_DIR}"

datasynth-data generate \
  --preset audit-group \
  --output "${OUTPUT_DIR}" \
  --seed 42 \
  --locale en_US \
  --periods 12 \
  --vendors 50 \
  --customers 30 \
  --employees 20 \
  --currency USD \
  --validate-accounting-identities \
  --gdpr-compliant

log "Generation complete. Verifying output..."

# Verify minimum expected file count
FILE_COUNT=$(find "$OUTPUT_DIR" -type f | wc -l)
if [[ "$FILE_COUNT" -lt 113 ]]; then
  warn "Expected >=113 output files, found ${FILE_COUNT}. Check DataSynth output above."
else
  log "Verified: ${FILE_COUNT} files generated."
fi

# Verify accounting identities in summary report
SUMMARY="${OUTPUT_DIR}/summary.json"
if [[ -f "$SUMMARY" ]]; then
  DEBITS_OK=$(python3 -c "
import json, sys
s = json.load(open('${SUMMARY}'))
ok = s.get('accountingIdentitiesValid', False)
print('PASS' if ok else 'FAIL')
")
  if [[ "$DEBITS_OK" == "PASS" ]]; then
    log "Accounting identities check: PASS (Debits=Credits, Assets=Liabilities+Equity)"
  else
    warn "Accounting identities check: FAIL — review ${SUMMARY}"
  fi
fi

echo ""
echo "============================================================"
echo " Synthetic data generation complete"
echo " Files: ${FILE_COUNT} in ${OUTPUT_DIR}"
echo "============================================================"
echo " Key files:"
echo "   ${OUTPUT_DIR}/gl_entries.csv        — General Ledger"
echo "   ${OUTPUT_DIR}/ap_invoices.csv       — Accounts Payable invoices"
echo "   ${OUTPUT_DIR}/purchase_orders.csv   — Purchase Orders"
echo "   ${OUTPUT_DIR}/goods_receipts.csv    — Goods Receipts"
echo "   ${OUTPUT_DIR}/bank_statements.csv   — Bank statements (synthetic IBANs)"
echo "   ${OUTPUT_DIR}/vendors.csv           — Vendor master data"
echo "   ${OUTPUT_DIR}/chart_of_accounts.csv — Chart of Accounts"
echo "   ${OUTPUT_DIR}/summary.json          — Dataset summary & validation"
echo "============================================================"

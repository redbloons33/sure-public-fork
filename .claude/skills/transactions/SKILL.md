---
name: transactions
description: Inspect transaction details for a specific date or date range in the Docker environment
user-invocable: true
---

# Transaction Details

Pulls transaction entries from the running Docker instance for a given date or date range.

## Single Date

```bash
docker exec sure-web-1 bin/rails runner "
entries = Entry.joins(\"INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'\")
              .where(date: Date.parse('YYYY-MM-DD'))
              .order(:amount)

entries.each do |e|
  t = e.entryable
  puts \"#{e.date} | #{e.name} | amt=#{e.amount} | kind=#{t.kind} | label=#{t.investment_activity_label} | source=#{e.source} | acct=#{e.account.name}\"
end
"
```

## Date Range

```bash
docker exec sure-web-1 bin/rails runner "
entries = Entry.joins(\"INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'\")
              .where(date: Date.parse('YYYY-MM-DD')..Date.parse('YYYY-MM-DD'))
              .order(:date, :amount)

entries.each do |e|
  t = e.entryable
  puts \"#{e.date} | #{e.name} | amt=#{e.amount} | kind=#{t.kind} | label=#{t.investment_activity_label} | source=#{e.source} | acct=#{e.account.name}\"
end
"
```

## Filter by Account Name (optional)

Add `.joins(:account).where(accounts: { name: 'Cash Plus Account' })` to the query chain.

## Filter by Source (optional)

Add `.where(source: 'snaptrade')` or `.where(source: 'plaid')` to the query chain.

## Key Fields

| Field | Meaning |
|---|---|
| `amt` | Negative = income/inflow, Positive = expense/outflow |
| `kind` | `standard`, `funds_movement`, `investment_contribution`, `cc_payment`, `loan_payment` |
| `label` | Investment activity label: `Dividend`, `Interest`, `Reinvestment`, `Contribution`, `Withdrawal`, etc. |
| `source` | `plaid` or `snaptrade` |

## Notes

- `kind = funds_movement` means the transaction is excluded from budget/income statement calculations.
- `investment_activity_label` is only set on investment-related cash transactions from Plaid/SnapTrade.
- Amounts follow Sure's sign convention: `amount < 0` = income, `amount > 0` = expense.

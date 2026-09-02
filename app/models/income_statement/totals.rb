class IncomeStatement::Totals
  def initialize(family, transactions_scope:, date_range:, include_trades: true, included_account_ids: nil)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @include_trades = include_trades
    @included_account_ids = included_account_ids

    validate_date_range!
  end

  def call
    # No finance accounts means no transactions to report
    return [] if @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(query_sql).map do |row|
      TotalsRow.new(
        parent_category_id: row["parent_category_id"],
        category_id: row["category_id"],
        classification: row["classification"],
        total: row["total"],
        transactions_count: row["transactions_count"],
        is_uncategorized_investment: row["is_uncategorized_investment"]
      )
    end
  end

  private
    TotalsRow = Data.define(:parent_category_id, :category_id, :classification, :total, :transactions_count, :is_uncategorized_investment)

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([
        @include_trades ? combined_query_sql : transactions_only_query_sql,
        sql_params
      ])
    end

    # Combined query that includes both transactions and trades
    def combined_query_sql
      <<~SQL
        SELECT
          category_id,
          parent_category_id,
          classification,
          is_uncategorized_investment,
          SUM(total) as total,
          SUM(entry_count) as transactions_count
        FROM (
          #{transactions_subquery_sql}
          UNION ALL
          #{trades_subquery_sql}
        ) combined
        GROUP BY category_id, parent_category_id, classification, is_uncategorized_investment;
      SQL
    end

    # Original transactions-only query (for backwards compatibility)
    def transactions_only_query_sql
      <<~SQL
        SELECT
          c.id as category_id,
          c.parent_id as parent_category_id,
          #{Transaction.income_classification_sql("at", "ae")} as classification,
          ABS(SUM(#{Transaction.income_amount_sql("at", "ae")})) as total,
          COUNT(ae.id) as transactions_count,
          false as is_uncategorized_investment
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN categories c ON c.id = at.category_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE #{budget_eligible_sql}
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          #{include_finance_accounts_sql}
        GROUP BY c.id, c.parent_id, #{Transaction.income_classification_sql("at", "ae")};
      SQL
    end

    def transactions_subquery_sql
      <<~SQL
        SELECT
          c.id as category_id,
          c.parent_id as parent_category_id,
          #{Transaction.income_classification_sql("at", "ae")} as classification,
          ABS(SUM(#{Transaction.income_amount_sql("at", "ae")})) as total,
          COUNT(ae.id) as entry_count,
          false as is_uncategorized_investment
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN categories c ON c.id = at.category_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE #{budget_eligible_sql}
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          #{include_finance_accounts_sql}
        GROUP BY c.id, c.parent_id, #{Transaction.income_classification_sql("at", "ae")}
      SQL
    end

    def trades_subquery_sql
      # Trades are completely excluded from income/expense budgets
      # Rationale: Trades represent portfolio rebalancing, not cash flow
      # Example: Selling $10k AAPL to buy MSFT = no net worth change, not an expense
      # Contributions/withdrawals are tracked separately as Transactions with activity labels
      <<~SQL
        SELECT NULL as category_id, NULL as parent_category_id, NULL as classification,
               NULL as total, NULL as entry_count, NULL as is_uncategorized_investment
        WHERE false
      SQL
    end

    def sql_params
      params = {
        target_currency: @family.currency,
        family_id: @family.id,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }

      # Add included account IDs for per-user finance scoping
      params[:included_account_ids] = @included_account_ids if @included_account_ids

      params
    end

    # The shared income/expense eligibility rule — see Transaction.budget_eligible_sql.
    # The Transactions tab summary bar uses the same method, which is what keeps the two
    # views from disagreeing about what counts as income or an expense.
    def budget_eligible_sql
      Transaction.budget_eligible_sql(
        txn_alias: "at",
        entry_alias: "ae",
        account_alias: "a",
        tax_advantaged_account_ids: @family.tax_advantaged_account_ids
      )
    end

    # Returns SQL clause to filter to only accounts included in the user's finances.
    def include_finance_accounts_sql
      return "" if @included_account_ids.nil?
      "AND a.id IN (:included_account_ids)"
    end

    def validate_date_range!
      unless @date_range.is_a?(Range)
        raise ArgumentError, "date_range must be a Range, got #{@date_range.class}"
      end

      unless @date_range.begin.respond_to?(:to_date) && @date_range.end.respond_to?(:to_date)
        raise ArgumentError, "date_range must contain date-like objects"
      end
    end
end

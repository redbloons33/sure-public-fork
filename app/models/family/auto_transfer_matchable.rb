module Family::AutoTransferMatchable
  # A bank reference number — Chase's "transaction#: 28091512913", an ACH trace, a check
  # number — is printed verbatim on both legs of the same movement. Two candidate legs that
  # share one are the same transaction as far as the bank is concerned. That outranks every
  # heuristic below and is the only signal allowed to take a leg back from an existing match.
  REFERENCE_TOKEN = /\d{6,}/

  # A reference identifies ONE movement, so it appears on exactly the two legs of that
  # movement. A long digit run printed on many entries is an originator/company ID —
  # Venmo's "WEB ID: 3264681992", a payroll "PPD ID" — and carries no matching signal at
  # all. Anything appearing on more than this many entries is treated as noise.
  MAX_REFERENCE_OCCURRENCES = 2

  # Words that appear on nearly every bank memo, so they say nothing about whether two
  # particular legs belong together.
  MATCH_STOPWORDS = %w[
    the and for from web transaction transfer payment online
    ppd ach ccd deposit withdrawal chk acct account xfer
  ].freeze

  def transfer_match_candidates(date_window: 4, exchange_rate_tolerance: 0.1, include_matched: false)
    scope = Entry.select([
      "inflow_candidates.entryable_id as inflow_transaction_id",
      "outflow_candidates.entryable_id as outflow_transaction_id",
      "inflow_candidates.name as inflow_name",
      "outflow_candidates.name as outflow_name",
      "ABS(inflow_candidates.date - outflow_candidates.date) as date_diff"
    ]).from("entries inflow_candidates")
      .joins("
        JOIN entries outflow_candidates ON (
          inflow_candidates.amount < 0 AND
          outflow_candidates.amount > 0 AND
          inflow_candidates.account_id <> outflow_candidates.account_id AND
          inflow_candidates.date BETWEEN outflow_candidates.date - #{date_window.to_i} AND outflow_candidates.date + #{date_window.to_i}
        )
      ").joins("
        LEFT JOIN transfers existing_transfers ON (
          existing_transfers.inflow_transaction_id = inflow_candidates.entryable_id OR
          existing_transfers.outflow_transaction_id = outflow_candidates.entryable_id
        )
      ")
      .joins("LEFT JOIN rejected_transfers ON (
        rejected_transfers.inflow_transaction_id = inflow_candidates.entryable_id AND
        rejected_transfers.outflow_transaction_id = outflow_candidates.entryable_id
      )")
      .joins("LEFT JOIN exchange_rates ON (
        exchange_rates.date = outflow_candidates.date AND
        exchange_rates.from_currency = outflow_candidates.currency AND
        exchange_rates.to_currency = inflow_candidates.currency
      )")
      .joins("JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id")
      .joins("JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id")
      # Internal broker cash management — a sweep into the settlement fund, an in-kind
      # exchange — moves cash between a holding and the account's own cash balance. Its
      # counterparty is inside the account, never in another one. Left eligible, a sweep of
      # the right size will soak up a real leg's partner and strand that leg as `standard`.
      .joins("JOIN transactions inflow_txns ON inflow_txns.id = inflow_candidates.entryable_id")
      .joins("JOIN transactions outflow_txns ON outflow_txns.id = outflow_candidates.entryable_id")
      .where("inflow_txns.investment_activity_label IS NULL OR inflow_txns.investment_activity_label NOT IN (#{Transaction.internal_movement_labels_sql})")
      .where("outflow_txns.investment_activity_label IS NULL OR outflow_txns.investment_activity_label NOT IN (#{Transaction.internal_movement_labels_sql})")
      .where("inflow_accounts.family_id = ? AND outflow_accounts.family_id = ?", self.id, self.id)
      .where("inflow_accounts.status IN ('draft', 'active')")
      .where("outflow_accounts.status IN ('draft', 'active')")
      .where("inflow_candidates.entryable_type = 'Transaction' AND outflow_candidates.entryable_type = 'Transaction'")
      .where("
        (
          inflow_candidates.currency = outflow_candidates.currency AND
          inflow_candidates.amount = -outflow_candidates.amount
        ) OR (
          inflow_candidates.currency <> outflow_candidates.currency AND
          ABS(inflow_candidates.amount / NULLIF(outflow_candidates.amount * exchange_rates.rate, 0)) BETWEEN #{1 - exchange_rate_tolerance} AND #{1 + exchange_rate_tolerance}
        )
      ")
      .order("date_diff ASC") # Closest matches first

    # Callers that only want new work (the auto-matcher's heuristic pass, the manual match
    # UI) keep the original behaviour of hiding legs that are already spoken for. The
    # reference pass asks for everything so it can displace a weaker match.
    scope = scope.where(existing_transfers: { id: nil }) unless include_matched

    scope
  end

  # Pair up transfer legs across accounts.
  #
  # Ordering matters here, and it used to be by date proximity alone. That is not enough to
  # separate legs when several movements of the SAME amount land on the SAME day: every
  # pairing ties at date_diff 0, the winner is whatever order Postgres happened to return,
  # and a wrong pairing consumes a leg the right pairing needed — leaving the real outflow
  # unmatched and therefore counted as an ordinary expense. It is also not enough over time:
  # a mediocre match made when only half the data had synced was never revisited once the
  # obviously-better leg arrived a day later.
  #
  # So legs are paired best-evidence-first instead:
  #   1. legs sharing a bank reference number  (ground truth; may displace a pending match)
  #   2. everything else, most-similar memo first, date proximity breaking ties
  def auto_match_transfers!
    Transfer.transaction do
      claimed = Set.new

      reference_rows, heuristic_rows = candidate_rows(include_matched: true)
        .partition { |row| shared_reference?(row) }

      reference_rows.sort_by! { |row| row.date_diff.to_i }

      reference_rows.each do |row|
        next if claimed.include?(row.inflow_transaction_id) || claimed.include?(row.outflow_transaction_id)
        next unless claim_legs_for_reference_match!(row)

        apply_match!(row, claimed)
      end

      heuristic_rows
        .sort_by { |row| [ -memo_similarity(row), row.date_diff.to_i ] }
        .each do |row|
          next if claimed.include?(row.inflow_transaction_id) || claimed.include?(row.outflow_transaction_id)
          next if legs_already_matched?(row)

          apply_match!(row, claimed)
        end
    end
  end

  private
    def candidate_rows(include_matched:)
      transfer_match_candidates(include_matched: include_matched)
        .where(rejected_transfers: { id: nil })
        .to_a
        .uniq { |row| [ row.inflow_transaction_id, row.outflow_transaction_id ] }
    end

    def legs_already_matched?(row)
      Transfer.where(
        "inflow_transaction_id = :inflow OR outflow_transaction_id = :outflow",
        inflow: row.inflow_transaction_id, outflow: row.outflow_transaction_id
      ).exists?
    end

    # A reference match beats a match made on date proximity alone, so it is allowed to
    # delete the weaker one and free the leg. Two things are never displaced: a transfer the
    # user confirmed, and another reference match (equally strong evidence).
    def claim_legs_for_reference_match!(row)
      holders = Transfer.where(
        "inflow_transaction_id IN (:ids) OR outflow_transaction_id IN (:ids)",
        ids: [ row.inflow_transaction_id, row.outflow_transaction_id ]
      ).to_a

      return true if holders.empty?
      return false if holders.any? { |transfer| transfer.confirmed? || reference_backed?(transfer) }

      # destroy! resets both legs of the displaced match back to `standard`; the freed leg
      # is re-offered to the heuristic pass below.
      holders.each(&:destroy!)
      true
    end

    def reference_backed?(transfer)
      discriminating_references(
        transfer.inflow_transaction&.entry&.name,
        transfer.outflow_transaction&.entry&.name
      ).any?
    end

    def shared_reference?(row)
      discriminating_references(row.inflow_name, row.outflow_name).any?
    end

    def discriminating_references(inflow_name, outflow_name)
      shared = inflow_name.to_s.scan(REFERENCE_TOKEN) & outflow_name.to_s.scan(REFERENCE_TOKEN)
      shared.select { |token| discriminating_reference?(token) }
    end

    def discriminating_reference?(token)
      @discriminating_reference_cache ||= {}
      return @discriminating_reference_cache[token] if @discriminating_reference_cache.key?(token)

      occurrences = Entry.joins(:account)
        .where(accounts: { family_id: id })
        .where("entries.name LIKE ?", "%#{token}%")
        .limit(MAX_REFERENCE_OCCURRENCES + 1)
        .pluck(:id)
        .size

      @discriminating_reference_cache[token] = occurrences <= MAX_REFERENCE_OCCURRENCES
    end

    # Share of meaningful memo words the two legs have in common, 0.0..1.0. Weak evidence on
    # its own — a bank rarely words both sides the same way — but enough to break a same-day
    # tie in favour of the pairing the memos actually support.
    def memo_similarity(row)
      inflow_tokens = memo_tokens(row.inflow_name)
      outflow_tokens = memo_tokens(row.outflow_name)
      return 0.0 if inflow_tokens.empty? || outflow_tokens.empty?

      (inflow_tokens & outflow_tokens).size.to_f / (inflow_tokens | outflow_tokens).size
    end

    def memo_tokens(name)
      name.to_s.downcase.scan(/[a-z]{3,}/).reject { |token| MATCH_STOPWORDS.include?(token) }.to_set
    end

    def apply_match!(row, claimed)
      begin
        Transfer.find_or_create_by!(
          inflow_transaction_id: row.inflow_transaction_id,
          outflow_transaction_id: row.outflow_transaction_id,
        )
      rescue ActiveRecord::RecordNotUnique
        # Another concurrent job created the transfer; safe to ignore
      end

      inflow_transaction = Transaction.find(row.inflow_transaction_id)
      outflow_transaction = Transaction.find(row.outflow_transaction_id)

      # The kind is determined by the DESTINATION account (inflow), matching Transfer::Creator logic
      destination_account = inflow_transaction.entry.account
      outflow_kind = Transfer.kind_for_account(destination_account)

      inflow_transaction.update!(kind: "funds_movement")
      outflow_transaction.update!(kind: outflow_kind)

      # Assign Investment Contributions category for transfers to investment accounts
      if outflow_kind == "investment_contribution" && outflow_transaction.category_id.blank?
        category = destination_account.family.investment_contributions_category
        outflow_transaction.update!(category: category) if category.present?
      end

      claimed << row.inflow_transaction_id
      claimed << row.outflow_transaction_id
    end
end

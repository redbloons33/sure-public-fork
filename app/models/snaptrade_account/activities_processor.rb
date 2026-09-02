class SnaptradeAccount::ActivitiesProcessor
  include SnaptradeAccount::DataHelpers

  # Map SnapTrade activity types to Sure activity labels
  # SnapTrade types: https://docs.snaptrade.com/reference/get_activities
  SNAPTRADE_TYPE_TO_LABEL = {
    "BUY" => "Buy",
    "SELL" => "Sell",
    "DIVIDEND" => "Dividend",
    "DIV" => "Dividend",
    "CONTRIBUTION" => "Contribution",
    "WITHDRAWAL" => "Withdrawal",
    "TRANSFER_IN" => "Transfer",
    "TRANSFER_OUT" => "Transfer",
    "TRANSFER" => "Transfer",
    "EXCHANGE" => "Exchange",           # Fund-to-fund exchange (internal reallocation)
    "EXCHANGE_IN" => "Exchange",
    "EXCHANGE_OUT" => "Exchange",
    "EXCHANGEIN" => "Exchange",
    "EXCHANGEOUT" => "Exchange",
    "REALIZEDGAINLOSS" => "Other",      # Non-cash accounting line, not income/expense
    "INTEREST" => "Interest",
    "FEE" => "Fee",
    "TAX" => "Fee",
    "REI" => "Reinvestment",      # Reinvestment
    "REINVEST" => "Reinvestment",
    "SPLIT" => "Other",
    "SPLIT_REVERSE" => "Other",   # Reverse stock split
    "MERGER" => "Other",
    "SPIN_OFF" => "Other",
    "STOCK_DIVIDEND" => "Dividend",
    "JOURNAL" => "Other",
    "CASH" => "Contribution",     # Cash deposit (non-retirement)
    "CORP_ACTION" => "Other",     # Corporate action
    "OTHER" => "Other",
    # Option activity types
    "OPTION_BUY" => "Buy",        # Buy to open/close option
    "OPTION_SELL" => "Sell",      # Sell to open/close option
    "EXERCISED" => "Other",       # Option exercised
    "EXPIRED" => "Other",         # Option expired worthless
    "ASSIGNED" => "Other"         # Option assignment
  }.freeze

  # Activity types that result in Trade records (involves securities)
  TRADE_TYPES = %w[BUY SELL REI REINVEST OPTION_BUY OPTION_SELL EXERCISED ASSIGNED].freeze

  # Sell-side activity types (quantity should be negative)
  SELL_SIDE_TYPES = %w[SELL OPTION_SELL ASSIGNED].freeze

  # Activity types that result in Transaction records (cash movements)
  CASH_TYPES = %w[DIVIDEND DIV CONTRIBUTION WITHDRAWAL TRANSFER_IN TRANSFER_OUT TRANSFER INTEREST FEE TAX CASH].freeze

  # Accounting lines that move no cash and change no position value. A brokerage reports
  # them so its own statement reconciles, but they are not activity in Sure's sense: a
  # realized gain/loss is the P&L on a sale that is already recorded as its own SELL, and a
  # split or a worthless option expiry only restates share counts. Imported as ordinary
  # transactions they read as income or expense that never happened, so they are skipped.
  #
  # Deliberately excluded from this list: MERGER, SPIN_OFF and CORP_ACTION, which can carry
  # cash in lieu of fractional shares, and OTHER, which is the catch-all that legitimate
  # cash rows fall into.
  NON_CASH_TYPES = %w[REALIZEDGAINLOSS SPLIT SPLIT_REVERSE EXPIRED].freeze

  # Some brokerages (notably Fidelity workplace plans via SnapTrade) report payroll
  # contributions and withdrawals under the generic "TRANSFER" type, distinguishing them
  # only in the free-text description. Left as a bare "Transfer" they are labelled as an
  # internal movement (kind: funds_movement) and dropped from every cash-flow report, and
  # their sign is never normalized so inflows are recorded as outflows.
  AMBIGUOUS_TRANSFER_TYPES = %w[TRANSFER TRANSFER_IN TRANSFER_OUT].freeze
  CONTRIBUTION_DESCRIPTION = /\b(contrib|deferral)/i
  WITHDRAWAL_DESCRIPTION = /\b(withdraw|distribution|disburse)/i

  def initialize(snaptrade_account)
    @snaptrade_account = snaptrade_account
  end

  def process
    activities_data = @snaptrade_account.raw_activities_payload
    return { trades: 0, transactions: 0 } if activities_data.blank?

    Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Processing #{activities_data.size} activities"

    @trades_count = 0
    @transactions_count = 0

    activities_data.each do |activity_data|
      process_activity(activity_data.with_indifferent_access)
    rescue => e
      Rails.logger.error "SnaptradeAccount::ActivitiesProcessor - Failed to process activity: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
    end

    { trades: @trades_count, transactions: @transactions_count }
  end

  private

    def account
      @snaptrade_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_activity(data)
      # Ensure we have indifferent access
      data = data.with_indifferent_access if data.is_a?(Hash)

      activity_type = (data[:type] || data["type"])&.upcase
      return if activity_type.blank?

      # Get external ID for deduplication
      external_id = (data[:id] || data["id"]).to_s
      return if external_id.blank?

      if NON_CASH_TYPES.include?(activity_type)
        Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Skipping non-cash activity: type=#{activity_type}, id=#{external_id}"
        return
      end

      Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Processing activity: type=#{activity_type}, id=#{external_id}"

      # Determine if this is a trade or cash activity
      if trade_activity?(activity_type)
        process_trade(data, activity_type, external_id)
      else
        process_cash_activity(data, activity_type, external_id)
      end
    end

    def trade_activity?(activity_type)
      TRADE_TYPES.include?(activity_type)
    end

    def process_trade(data, activity_type, external_id)
      # Extract and normalize symbol data
      # SnapTrade activities have DIFFERENT structure than holdings:
      #   activity.symbol.symbol = "MSTR" (ticker string directly)
      #   activity.symbol.description = name
      # Holdings have deeper nesting: symbol.symbol.symbol = ticker
      raw_symbol_wrapper = data["symbol"] || data[:symbol] || {}
      symbol_wrapper = raw_symbol_wrapper.is_a?(Hash) ? raw_symbol_wrapper.with_indifferent_access : {}

      # Get the symbol field - could be a string (ticker) or nested object
      raw_symbol_data = symbol_wrapper["symbol"] || symbol_wrapper[:symbol]

      # Determine ticker based on data type
      if raw_symbol_data.is_a?(String)
        # Activities: symbol.symbol is the ticker string directly
        ticker = raw_symbol_data
        symbol_data = symbol_wrapper # Use the wrapper for description, etc.
      elsif raw_symbol_data.is_a?(Hash)
        # Holdings structure: symbol.symbol is an object with symbol inside
        symbol_data = raw_symbol_data.with_indifferent_access
        ticker = symbol_data["symbol"] || symbol_data[:symbol]
        ticker = symbol_data["raw_symbol"] if ticker.is_a?(Hash)
      else
        ticker = nil
        symbol_data = {}
      end

      # Must have a symbol for trades
      if ticker.blank?
        Rails.logger.warn "SnaptradeAccount::ActivitiesProcessor - Skipping trade without symbol: #{external_id}"
        return
      end

      # Resolve security
      security = resolve_security(ticker, symbol_data)
      return unless security

      # Parse trade values
      quantity = parse_decimal(data[:units]) || parse_decimal(data["units"]) ||
                 parse_decimal(data[:quantity]) || parse_decimal(data["quantity"])
      price = parse_decimal(data[:price]) || parse_decimal(data["price"])

      if quantity.nil?
        Rails.logger.warn "SnaptradeAccount::ActivitiesProcessor - Skipping trade without quantity: #{external_id}"
        return
      end

      # Determine sign based on activity type (sell-side should be negative)
      quantity = if SELL_SIDE_TYPES.include?(activity_type)
        -quantity.abs
      else
        quantity.abs
      end

      # Calculate amount
      amount = if price
        quantity * price
      else
        parse_decimal(data[:amount]) || parse_decimal(data["amount"]) ||
        parse_decimal(data[:trade_value]) || parse_decimal(data["trade_value"])
      end

      if amount.nil?
        Rails.logger.warn "SnaptradeAccount::ActivitiesProcessor - Skipping trade without amount: #{external_id}"
        return
      end

      # Get the activity date
      activity_date = parse_date(data[:settlement_date]) || parse_date(data["settlement_date"]) ||
                      parse_date(data[:trade_date]) || parse_date(data["trade_date"]) || Date.current

      # Extract currency - handle both nested object and string
      currency_data = data[:currency] || data["currency"] || symbol_data[:currency] || symbol_data["currency"]
      currency = if currency_data.is_a?(Hash)
        currency_data.with_indifferent_access[:code]
      elsif currency_data.is_a?(String)
        currency_data
      else
        account.currency
      end

      description = data[:description] || data["description"] || "#{activity_type} #{ticker}"

      Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Importing trade: #{ticker} qty=#{quantity} price=#{price} date=#{activity_date}"

      result = import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: quantity,
        price: price,
        amount: amount,
        currency: currency,
        date: activity_date,
        name: description,
        source: "snaptrade",
        activity_label: label_from_type(activity_type, description)
      )
      @trades_count += 1 if result
    end

    def process_cash_activity(data, activity_type, external_id)
      amount = parse_decimal(data[:amount]) || parse_decimal(data["amount"]) ||
               parse_decimal(data[:net_amount]) || parse_decimal(data["net_amount"])
      return if amount.nil? || amount.zero?

      # Get the activity date
      activity_date = parse_date(data[:settlement_date]) || parse_date(data["settlement_date"]) ||
                      parse_date(data[:trade_date]) || parse_date(data["trade_date"]) || Date.current

      # Build description
      raw_symbol_data = data[:symbol] || data["symbol"] || {}
      symbol_data = raw_symbol_data.is_a?(Hash) ? raw_symbol_data.with_indifferent_access : {}
      symbol = symbol_data[:symbol] || symbol_data["symbol"] || symbol_data[:ticker]
      description = data[:description] || data["description"] || build_description(activity_type, symbol)

      # Normalize amount sign for certain activity types
      activity_label = label_from_type(activity_type, description)
      amount = normalize_cash_amount(amount, activity_type, activity_label)

      # Extract currency - handle both nested object and string
      currency_data = data[:currency] || data["currency"]
      currency = if currency_data.is_a?(Hash)
        currency_data.with_indifferent_access[:code]
      elsif currency_data.is_a?(String)
        currency_data
      else
        account.currency
      end

      Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Importing cash activity: type=#{activity_type} amount=#{amount} date=#{activity_date}"

      result = import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: activity_date,
        name: description,
        source: "snaptrade",
        investment_activity_label: activity_label
      )
      @transactions_count += 1 if result
    end

    # Sure's signage convention: amount > 0 = outflow (expense), amount < 0 = inflow (income).
    # SnapTrade reports inflows and outflows as positive magnitudes per type, so we re-sign
    # them to match Plaid/Sure. Without this, dividends, interest, contributions, etc. get
    # classified as expenses on the income statement.
    def normalize_cash_amount(amount, activity_type, label = nil)
      # A generic TRANSFER resolved to Contribution/Withdrawal by description carries no
      # reliable sign of its own, so key off the resolved label instead of the raw type.
      if AMBIGUOUS_TRANSFER_TYPES.include?(activity_type&.upcase)
        case label
        when "Contribution" then return -amount.abs   # inflow
        when "Withdrawal" then return amount.abs      # outflow
        end
      end

      case activity_type
      when "WITHDRAWAL", "TRANSFER_OUT", "FEE", "TAX"
        amount.abs    # outflow
      when "CONTRIBUTION", "TRANSFER_IN", "DIVIDEND", "DIV", "INTEREST", "CASH"
        -amount.abs   # inflow
      else
        amount
      end
    end

    def build_description(activity_type, symbol)
      type_label = label_from_type(activity_type)
      if symbol.present?
        "#{type_label} - #{symbol}"
      else
        type_label
      end
    end

    # Resolves the activity label, using the description to disambiguate generic
    # TRANSFER rows that are really contributions or withdrawals. See
    # AMBIGUOUS_TRANSFER_TYPES.
    def label_from_type(activity_type, description = nil)
      normalized_type = activity_type&.upcase

      if AMBIGUOUS_TRANSFER_TYPES.include?(normalized_type) && description.present?
        # Withdrawal is checked first: its wording is the more decisive of the two.
        case description
        when WITHDRAWAL_DESCRIPTION then return "Withdrawal"
        when CONTRIBUTION_DESCRIPTION then return "Contribution"
        end
      end

      label = SNAPTRADE_TYPE_TO_LABEL[normalized_type]

      if label.nil? && normalized_type.present?
        # Log unmapped activity types for visibility - helps identify new types to add
        Rails.logger.warn(
          "SnaptradeAccount::ActivitiesProcessor - Unmapped activity type '#{normalized_type}' " \
          "for account #{@snaptrade_account.id}. Consider adding to SNAPTRADE_TYPE_TO_LABEL mapping."
        )
      end

      label || "Other"
    end
end

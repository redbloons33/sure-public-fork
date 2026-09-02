module ReportsHelper
  # Path from a monthly trend row to the Transactions tab, filtered to that month.
  #
  # per_page is carried over from whatever the user last used on the transactions page.
  # Supplying query params suppresses TransactionsController#store_params!'s restore
  # branch, so an omitted per_page would both shrink the list to the pagination default
  # of 10 and overwrite their stored preference on the way through.
  def month_transactions_path(trend, type: nil)
    filtered_transactions_path(trend[:start_date], trend[:end_date], type: type)
  end

  # Path from a breakdown row to the transactions behind it: same period, same side of the
  # statement, narrowed to that category. A parent category's filter also picks up its
  # subcategories, which is what the row's own total already includes.
  def category_transactions_path(item, type:, start_date:, end_date:)
    filtered_transactions_path(start_date, end_date, type: type, categories: [ item[:category_name] ])
  end

  # Trades are not Transactions, so the "Other Investments" row has nothing to show on the
  # transactions page. Leave it unlinked rather than send the user to an empty list.
  def breakdown_row_linkable?(item)
    item[:category_id] != :other_investments
  end

  def filtered_transactions_path(start_date, end_date, type: nil, categories: nil)
    q = { start_date: start_date.to_s, end_date: end_date.to_s }
    q[:types] = [ type.to_s ] if type.present?
    q[:categories] = categories if categories.present?

    transactions_path(page: 1, per_page: stored_transactions_per_page, q: q)
  end

  def stored_transactions_per_page
    Current.session&.prev_transaction_page_params&.dig("per_page").presence || 50
  end

  # Returns CSS classes for tax treatment badge styling
  def tax_treatment_badge_classes(treatment)
    case treatment.to_sym
    when :tax_exempt
      "bg-green-500/10 text-green-600 theme-dark:text-green-400"
    when :tax_deferred
      "bg-blue-500/10 text-blue-600 theme-dark:text-blue-400"
    when :tax_advantaged
      "bg-purple-500/10 text-purple-600 theme-dark:text-purple-400"
    else
      "bg-gray-500/10 text-secondary"
    end
  end

  # Generate SVG polyline points for a sparkline chart
  # Returns empty string if fewer than 2 data points (can't draw a line with 1 point)
  def sparkline_points(values, width: 60, height: 16)
    return "" if values.nil? || values.length < 2 || values.all? { |v| v.nil? || v.zero? }

    nums = values.map(&:to_f)
    max_val = nums.max
    min_val = nums.min
    range = max_val - min_val
    range = 1.0 if range.zero?

    points = nums.each_with_index.map do |val, i|
      x = (i.to_f / [ nums.length - 1, 1 ].max) * width
      y = height - ((val - min_val) / range * (height - 2)) - 1
      "#{x.round(1)},#{y.round(1)}"
    end

    points.join(" ")
  end

  # Calculate cumulative net values from trends data
  def cumulative_net_values(trends)
    return [] if trends.nil?

    running = 0
    trends.map { |t| running += t[:net].to_i; running }
  end

  # Check if trends data has enough points for sparklines (need at least 2)
  def has_sparkline_data?(trends_data)
    trends_data&.length.to_i >= 2
  end
end

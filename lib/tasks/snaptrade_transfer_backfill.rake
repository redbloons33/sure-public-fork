namespace :snaptrade do
  desc "Relabel generic SnapTrade TRANSFER activities that are really contributions/withdrawals (dry run unless APPLY=1)"
  task backfill_ambiguous_transfers: :environment do
    apply = ENV["APPLY"] == "1"
    processor_class = SnaptradeAccount::ActivitiesProcessor

    puts apply ? "APPLYING changes..." : "DRY RUN (set APPLY=1 to write)"
    puts ""

    total_changed = 0

    SnaptradeAccount.find_each do |snaptrade_account|
      activities = Array(snaptrade_account.raw_activities_payload)
      next if activities.empty?

      account = snaptrade_account.current_account
      next if account.nil?

      processor = processor_class.new(snaptrade_account)
      changed_here = 0

      activities.each do |raw|
        activity = raw.with_indifferent_access
        type = activity[:type]&.upcase
        next unless processor_class::AMBIGUOUS_TRANSFER_TYPES.include?(type)

        description = activity[:description]
        new_label = processor.send(:label_from_type, type, description)
        # Only rows the description actually disambiguated are in scope.
        next if new_label == processor.send(:label_from_type, type, nil)

        entry = Entry.find_by(account_id: account.id, external_id: activity[:id].to_s)
        next if entry.nil? || !entry.entryable.is_a?(Transaction)

        transaction = entry.entryable
        amount = processor.send(
          :normalize_cash_amount,
          processor.send(:parse_decimal, activity[:amount]),
          type,
          new_label
        )
        next if amount.nil? || amount.zero?

        new_kind = new_label == "Contribution" ? "investment_contribution" : "standard"

        next if transaction.investment_activity_label == new_label &&
                transaction.kind == new_kind &&
                entry.amount == amount

        if changed_here.zero?
          puts "== #{account.name} (#{snaptrade_account.name})"
        end
        puts format(
          "   %s  %-24s  %-9s -> %-12s  %-15s -> %-24s  %10.2f -> %10.2f",
          entry.date, description.to_s[0, 24],
          transaction.investment_activity_label.to_s, new_label,
          transaction.kind, new_kind,
          entry.amount, amount
        )

        if apply
          ActiveRecord::Base.transaction do
            entry.update!(amount: amount)
            attrs = { investment_activity_label: new_label, kind: new_kind }
            if new_kind == "investment_contribution" && transaction.category_id.blank?
              attrs[:category] = account.family.investment_contributions_category
            end
            transaction.update!(attrs)
          end
        end

        changed_here += 1
      end

      total_changed += changed_here
    end

    puts ""
    puts "#{apply ? 'Updated' : 'Would update'} #{total_changed} transaction(s)."
    puts "Re-run with APPLY=1 to write these changes." unless apply
  end
end

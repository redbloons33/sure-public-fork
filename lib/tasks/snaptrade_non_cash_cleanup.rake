namespace :snaptrade do
  desc "Delete SnapTrade activities imported before non-cash types were skipped (dry run unless APPLY=1)"
  task purge_non_cash_activities: :environment do
    apply = ENV["APPLY"] == "1"
    types = SnaptradeAccount::ActivitiesProcessor::NON_CASH_TYPES

    puts apply ? "APPLYING deletions..." : "DRY RUN (set APPLY=1 to delete)"
    puts "Non-cash types: #{types.join(', ')}"
    puts ""

    total = 0

    SnaptradeAccount.find_each do |snaptrade_account|
      activities = Array(snaptrade_account.raw_activities_payload)
      next if activities.empty?

      account = snaptrade_account.current_account
      next if account.nil?

      external_ids = activities
        .map { |raw| raw.with_indifferent_access }
        .select { |activity| types.include?(activity[:type]&.upcase) }
        .map { |activity| activity[:id].to_s }
        .reject(&:blank?)
      next if external_ids.empty?

      entries = Entry.where(account_id: account.id, external_id: external_ids, entryable_type: "Transaction")
      next if entries.empty?

      puts "== #{account.name}"
      entries.each do |entry|
        puts format("   %s  %-24s %10.2f", entry.date, entry.name.to_s[0, 24], entry.amount)
        entry.destroy! if apply
        total += 1
      end
    end

    puts ""
    puts "#{apply ? 'Deleted' : 'Would delete'} #{total} entr#{total == 1 ? 'y' : 'ies'}."
    puts "Re-run with APPLY=1 to delete." unless apply
  end
end

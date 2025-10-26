# frozen_string_literal: true

module Herd
  module Commands
    # Commands for adding new crontab tasks or replace with given one.
    module Crontab
      def add_cron(entry)
        run(%(crontab -l | { cat; echo "#{entry}"; } | crontab -))
      end

      def crontab(entry)
        run(%(echo "#{entry}" | crontab -))
      end
    end
  end
end

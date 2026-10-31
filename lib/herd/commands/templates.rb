# frozen_string_literal: true

require "erb"

module Herd
  module Commands
    TEMPLATES = "templates"

    # Render templates using ERB
    module Templates
      def template(path, user, group, mode: nil, values: {}, sensitive: false)
        erb = ERB.new(File.read(File.join(TEMPLATES, "#{path}.erb")))
        content = erb.result_with_hash(values)
        file(path, user, group, mode: mode, content: content, sensitive: sensitive)
      end
    end
  end
end

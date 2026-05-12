# frozen_string_literal: true

module Herd
  module Commands
    module Users
      def change_password(username, new_password)
        run("echo '#{username}:#{new_password}' | sudo chpasswd")
        host.password = new_password if username == host.user
      end
    end
  end
end

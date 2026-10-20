# frozen_string_literal: true

register_server "web",
  **common,
  host:          "10.0.0.1",
  port:          2222,
  user:          "deploy",
  password:      "pw",
  root_password: "rootpw",
  repl_password:     nil,
  rustdesk_id:   "123"

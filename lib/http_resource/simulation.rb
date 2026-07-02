# frozen_string_literal: true

# Test-facing, opt-in machinery: exercise an http_resource-based client with NO
# live backend. NOT loaded by `require "http_resource"` — Client requires this
# file lazily, only when built with a truthy `simulation:` kwarg.
require "http_resource/simulation/store"
require "http_resource/simulation/backend"

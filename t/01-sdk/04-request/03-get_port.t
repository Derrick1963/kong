use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
use t::Util;

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: request.get_port() returns server port
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local SDK = require "kong.sdk"; ngx.ctx.kong_phase = require("kong.sdk.private.checks").phases.ACCESS
            local sdk = SDK.new()

            ngx.say("port: ", sdk.request.get_port())
        }
    }
--- request
GET /t
--- response_body_like chomp
port: \d+
--- no_error_log
[error]



=== TEST 2: request.get_port() returns a number
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local SDK = require "kong.sdk"; ngx.ctx.kong_phase = require("kong.sdk.private.checks").phases.ACCESS
            local sdk = SDK.new()

            ngx.say("port type: ", type(sdk.request.get_port()))
        }
    }
--- request
GET /t
--- response_body
port type: number
--- no_error_log
[error]

local cjson = require "cjson.safe"
local checks = require "kong.sdk.private.checks"


local bit = bit
local ngx = ngx
local table_insert = table.insert
local table_sort = table.sort
local table_concat = table.concat
local string_find = string.find
local string_sub = string.sub
local string_lower = string.lower
local normalize_header = checks.normalize_header
local normalize_multi_header = checks.normalize_multi_header
local validate_header = checks.validate_header
local validate_headers = checks.validate_headers
local check_phase = checks.check_phase
local REQUEST_PHASES = bit.bor(checks.phases.ACCESS,
                               checks.phases.REWRITE)

--------------------------------------------------------------------------------
-- Produce a lexicographically ordered querystring, given a table of values.
--
-- @param args A table where keys are strings and values are strings, booleans,
-- or an array of strings or booleans.
-- @return an URL-encoded query string, or nil and an error message
local function make_ordered_args(args)
  local out = {}
  local t = {}
  for k, v in pairs(args) do
    if type(k) ~= "string" then
      return nil, "arg keys must be strings"
    end

    t[k] = v

    local pok, s = pcall(ngx.encode_args, t)
    if not pok then
      return nil, s
    end

    table_insert(out, s)
    t[k] = nil
  end
  table_sort(out)
  return table_concat(out, "&")
end


-- The service request module: functions for dealing with data to be sent
-- to the service, i.e. for connections made by Kong.
local function new(self)

  local request = {}

  -- TODO these constants should be shared with kong.request

  local CONTENT_TYPE           = "Content-Type"

  local CONTENT_TYPE_POST      = "application/x-www-form-urlencoded"
  local CONTENT_TYPE_JSON      = "application/json"
  local CONTENT_TYPE_FORM_DATA = "multipart/form-data"


  ------------------------------------------------------------------------------
  -- Sets the protocol to use when proxying the request to the service.
  --
  -- @param scheme Protocol to use. Supported values are `"http"` and `"https"`.
  -- @return Nothing; throws an error on invalid inputs.
  request.set_scheme = function(scheme)
    check_phase(REQUEST_PHASES)

    if type(scheme) ~= "string" then
      error("scheme must be a string", 2)
    end

    if scheme ~= "http" and scheme ~= "https" then
      error("invalid scheme: " .. scheme, 2)
    end

    ngx.var.upstream_scheme = scheme
  end


  ------------------------------------------------------------------------------
  -- Sets the path component for the request to the service. It is not
  -- normalized in any way and should not include the querystring.
  --
  -- @param path The path string. Example: "/v2/movies"
  -- @return Nothing; throws an error on invalid inputs.
  request.set_path = function(path)
    check_phase(REQUEST_PHASES)

    if type(path) ~= "string" then
      error("path must be a string", 2)
    end

    if string_sub(path, 1, 1) ~= "/" then
      error("path must start with /", 2)
    end

    -- TODO: is this necessary in specific phases?
    -- ngx.req.set_uri(path)
    ngx.var.upstream_uri = path
  end


  ------------------------------------------------------------------------------
  -- Sets the querystring for the request to the service. Input argument is a
  -- raw string that is not processed in any way.
  --
  -- For a higher-level function for setting the query string from a Lua table
  -- of arguments, see `kong.service.request.set_query_args`.
  --
  -- @param query The raw querystring. Example: "foo=bar&bla&baz=hello%20world"
  -- @return Nothing; throws an error on invalid inputs.
  request.set_raw_query = function(query)
    check_phase(REQUEST_PHASES)

    if type(query) ~= "string" then
      error("query must be a string", 2)
    end

    ngx.req.set_uri_args(query)
  end


  do
    local accepted_methods = {
      ["GET"]       = ngx.HTTP_GET,
      ["HEAD"]      = ngx.HTTP_HEAD,
      ["PUT"]       = ngx.HTTP_PUT,
      ["POST"]      = ngx.HTTP_POST,
      ["DELETE"]    = ngx.HTTP_DELETE,
      ["OPTIONS"]   = ngx.HTTP_OPTIONS,
      ["MKCOL"]     = ngx.HTTP_MKCOL,
      ["COPY"]      = ngx.HTTP_COPY,
      ["MOVE"]      = ngx.HTTP_MOVE,
      ["PROPFIND"]  = ngx.HTTP_PROPFIND,
      ["PROPPATCH"] = ngx.HTTP_PROPPATCH,
      ["LOCK"]      = ngx.HTTP_LOCK,
      ["UNLOCK"]    = ngx.HTTP_UNLOCK,
      ["PATCH"]     = ngx.HTTP_PATCH,
      ["TRACE"]     = ngx.HTTP_TRACE,
    }


    ----------------------------------------------------------------------------
    -- Sets the HTTP method for the request that Kong will make to
    -- the service.
    --
    -- @param method The method string, which should be given in all
    -- uppercase. Supported values are: `"GET"`, `"HEAD"`, `"PUT"`, `"POST"`,
    -- `"DELETE"`, `"OPTIONS"`, `"MKCOL"`, `"COPY"`, `"MOVE"`, `"PROPFIND"`,
    -- `"PROPPATCH"`, `"LOCK"`, `"UNLOCK"`, `"PATCH"`, `"TRACE"`.
    -- @return Nothing; throws an error on invalid inputs.
    request.set_method = function(method)
      check_phase(REQUEST_PHASES)

      if type(method) ~= "string" then
        error("method must be a string", 2)
      end

      local method_id = accepted_methods[method]
      if not method_id then
        error("invalid method: " .. method, 2)
      end

      ngx.req.set_method(method_id)
    end
  end


  ------------------------------------------------------------------------------
  -- Defines a query string for the request to the service, given a table of
  -- arguments.
  --
  -- Keys are produced in lexicographical order. The order of entries within the
  -- same key (when values are given as an array) is retained.
  --
  -- If further control of the querystring generation is needed, a raw
  -- querystring can be given as a string with `kong.service.request.set_query`.
  --
  -- @param args A table where each key is a string (corresponding to an
  -- argument name), and each value is either a boolean, a string or an array of
  -- strings or booleans. Any string values given are URL-encoded.
  -- @return Nothing; throws an error on invalid inputs.
  request.set_query = function(args)
    check_phase(REQUEST_PHASES)

    if type(args) ~= "table" then
      error("args must be a table", 2)
    end

    local querystring, err = make_ordered_args(args)
    if not querystring then
      error(err, 2) -- type error inside the table
    end

    ngx.req.set_uri_args(querystring)
  end


  ------------------------------------------------------------------------------
  -- Sets a request header to the given value. It overrides any existing ones:
  -- if one or more headers are already set with header name, they are removed.
  --
  -- @param header The header name. Example: "X-Foo"
  -- @param value The header value. Example: "hello world"
  -- @return Nothing; throws an error on invalid inputs.
  request.set_header = function(header, value)
    check_phase(REQUEST_PHASES)

    validate_header(header, value)

    if string_lower(header) == "host" then
      ngx.var.upstream_host = value
    end

    ngx.req.set_header(header, normalize_header(value))
  end


  ------------------------------------------------------------------------------
  -- Adds a header with the given value to the request to the service,
  -- without removing any existing headers with the same name. The order in
  -- which headers are added is retained.
  --
  -- @param header The header name. Example: "Cache-Control"
  -- @param value The header value. Example: "no-cache"
  -- @return Nothing; throws an error on invalid inputs.
  request.add_header = function(header, value)
    check_phase(REQUEST_PHASES)

    validate_header(header, value)

    if string_lower(header) == "host" then
      ngx.var.upstream_host = value
    end

    local headers = ngx.req.get_headers()[header]
    if type(headers) ~= "table" then
      headers = { headers }
    end

    table_insert(headers, normalize_header(value))

    ngx.req.set_header(header, headers)
  end


  ------------------------------------------------------------------------------
  -- Removes any occurrences of the given header.
  --
  -- @param header The header name. Example: "X-Foo"
  -- @return Nothing; throws an error on invalid inputs.
  -- The function does not throw an error if no header was removed.
  request.clear_header = function(header)
    check_phase(REQUEST_PHASES)

    if type(header) ~= "string" then
      error("header must be a string", 2)
    end

    ngx.req.clear_header(header)
  end


  ------------------------------------------------------------------------------
  -- Sets multiple headers at once.
  --
  -- Headers are produced in lexicographical order. The order of entries within
  -- the same header (when values are given as an array) is retained.
  --
  -- It overrides any existing headers for the given keys: if one or more
  -- headers are already set with a header name, they are removed. Headers that
  -- are not referenced as keys of the `headers` table remain untouched.
  --
  -- If further control on the order of headers is needed, these should be
  -- added one by one using `kong.service.request.set_header` and
  -- `kong.service.request.add_header`.
  --
  -- @param headers A table where each key is a string containing a header name
  -- and each value is either a string or an array of strings.
  -- @return Nothing; throws an error on invalid inputs.
  request.set_headers = function(headers)
    check_phase(REQUEST_PHASES)

    if type(headers) ~= "table" then
      error("headers must be a table", 2)
    end

    -- Check for type errors first

    validate_headers(headers)

    -- Now we can use ngx.req.set_header without pcall

    for k, v in pairs(headers) do
      if string_lower(k) == "host" then
        ngx.var.upstream_host = v
      end

      ngx.req.set_header(k, normalize_multi_header(v))
    end

  end


  ------------------------------------------------------------------------------
  -- Sets the raw body for the request to the service. Input argument is a
  -- raw string that is not processed in any way. Sets the `Content-Length`
  -- header appropriately. To set an empty body, use an empty string (`""`).
  --
  -- For a higher-level function for setting the body based on the request
  -- content type, see `kong.service.request.set_body`.
  --
  -- @param body The raw body, as a string.
  -- @return Nothing; throws an error on invalid inputs.
  request.set_raw_body = function(body)
    check_phase(REQUEST_PHASES)

    if type(body) ~= "string" then
      error("body must be a string", 2)
    end

    -- TODO Can we get the body size limit configured for Kong and check for
    -- length based on that, and fail gracefully before attempting to set
    -- the body?

    -- Ensure client request body has been read.
    -- This function is a nop if body has already been read,
    -- and necessary to write the request to the service if it has not.
    ngx.req.read_body()

    ngx.req.set_body_data(body)
  end


  do
    local set_body_handlers = {

      [CONTENT_TYPE_POST] = function(args, mime)
        if type(args) ~= "table" then
          error("args must be a table", 3)
        end

        local querystring, err = make_ordered_args(args)
        if not querystring then
          error(err, 3) -- type error inside the table
        end

        return querystring, mime
      end,

      [CONTENT_TYPE_JSON] = function(args, mime)
        local encoded, err = cjson.encode(args)
        if not encoded then
          error(err, 3)
        end

        return encoded, mime
      end,

      [CONTENT_TYPE_FORM_DATA] = function(args, mime)
        local keys = {}

        local boundary
        local boundary_ok = false
        local at = string_find(mime, "boundary=", 1, true)
        if at then
          at = at + 9
          if string_sub(mime, at, at) == '"' then
            local till = string_find(mime, '"', at + 1, true)
            boundary = string_sub(mime, at + 1, till - 1)
          else
            boundary = string_sub(mime, at)
          end
          boundary_ok = true
        end

        -- This will only loop in the unlikely event that the
        -- boundary is not acceptable and needs to be regenerated.
        repeat

          if not boundary_ok then
            boundary = tostring(math.random(1e10))
            boundary_ok = true
          end

          local boundary_check = "\n--" .. boundary
          local i = 1
          for k, v in pairs(args) do
            if type(k) ~= "string" then
              error(("invalid key %q: got %s, " ..
                     "expected string"):format(k, type(k)), 3)
            end
            local tv = type(v)
            if tv ~= "string" and tv ~= "number" and tv ~= "boolean" then
              error(("invalid value %q: got %s, " ..
                     "expected string, number or boolean"):format(k, tv), 3)
            end
            keys[i] = k
            i = i + 1
            if string_find(v, boundary_check, 1, true) then
              boundary_ok = false
            end
          end

        until boundary_ok

        table_sort(keys)

        local out = {}
        local i = 1

        for _, k in ipairs(keys) do
          out[i] = "--"
          out[i + 1] = boundary
          out[i + 2] = "\r\n"
          out[i + 3] = 'Content-Disposition: form-data; name="'
          out[i + 4] = k
          out[i + 5] = '"\r\n\r\n'
          local v = args[k]
          out[i + 6] = v
          out[i + 7] = "\r\n"
          i = i + 8
        end
        out[i] = "--"
        out[i + 1] = boundary
        out[i + 2] = "--\r\n"

        local output = table.concat(out)

        return output, CONTENT_TYPE_FORM_DATA .. "; boundary=" .. boundary
      end,

    }

    ----------------------------------------------------------------------------
    -- Sets the body for the request to the service, encoding it based on the
    -- `mimetype` argument (or the `Content-Type` header of the request
    -- if the `mimetype` argument is not given).
    --
    -- * if the request content type is `application/x-www-form-urlencoded`:
    --   * encodes the form arguments: keys are produced in lexicographical
    --     order. The order of entries within the same key (when values are
    --     given as an array) is retained.
    --     Any string values given are URL-encoded.
    -- * if the request content type is `multipart/form-data`:
    --   * encodes the multipart form data
    -- * if the request content type is `application/json`:
    --   * encodes the request as JSON
    --     (same as `kong.service.request.set_raw_body(json.encode(args))`)
    --   * JSON types are converted to matching Lua types
    -- * If none of the above, it returns `nil` and an error message.
    --
    -- If further control of the body generation is needed, a raw body
    -- can be given as a string with `kong.service.request.set_raw_body`.
    --
    -- @param args a table with data to be converted to the appropriate format
    -- and stored in the body.
    -- * If the request content type is `application/x-www-form-urlencoded`:
    --   * input should be a table where each key is a string (corresponding
    --     to an argument name), and each value is either a boolean,
    --     a string or an array of strings or booleans.
    -- * If the request content type is `application/json`:
    --   * the table should be JSON-encodable (all tables should be either
    --     Lua sequences or all keys should be strings).
    -- * if the request content type is `multipart/form-data`:
    --   * the table should be multipart-encodable.
    -- @param mime if given, it should be in the same format as the
    -- value returned by `kong.service.request.get_body`.
    -- The `Content-Type` header will be updated to match the appropriate type.
    -- @return true on success; nil and an error message in case of errors;
    -- throws an error on invalid inputs.
    request.set_body = function(args, mime)
      check_phase(REQUEST_PHASES)

      if type(args) ~= "table" then
        error("args must be a table", 2)
      end
      if mime and type(mime) ~= "string" then
        error("mime must be a string", 2)
      end
      local mime_given = mime ~= nil
      if not mime_given then
        mime = ngx.req.get_headers()[CONTENT_TYPE]
        if not mime then
          return nil, "cannot detect format: no mimetype argument given " ..
                      "and no Content-Type header present"
        end
      end

      local boundaryless_mime = mime
      local s = string_find(mime, ";", 1, true)
      if s then
        boundaryless_mime = string_sub(mime, 1, s - 1)
      end

      local handler_fn = set_body_handlers[boundaryless_mime]
      if not handler_fn then
        if mime_given then
          error("unsupported content type " .. mime, 2)
        else
          return nil, "unsupported value in Content-Type header: " .. mime
        end
      end

      -- Ensure client request body has been read.
      -- This function is a nop if body has already been read,
      -- and necessary to write the request to the service if it has not.
      ngx.req.read_body()

      local body, content_type = handler_fn(args, mime)

      ngx.req.set_body_data(body)
      ngx.req.set_header(CONTENT_TYPE, content_type)

      return true
    end

  end

  return request
end


return {
  new = new,
}

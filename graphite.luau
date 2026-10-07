--!strict
-- Graphite CLI API client. Authenticates with the `gt` CLI's own token
-- (resolved the same way gt 1.8.6 resolves it), and talks to the Graphite
-- REST API. No browser cookie, no `gh`. In fixture mode, requests are
-- served from JSON files on disk instead of the network.

local M = {}

export type Auth = { token: string, api: string, app: string }

export type ApiError = {
	kind: "auth" | "rate" | "network" | "http" | "parse",
	message: string,
	retry_after: number?,
}

export type Ctx = { auth: Auth, fixture_dir: string? }

local DEFAULT_API = "https://api.graphite.com/v1"
local DEFAULT_APP = "https://app.graphite.com"
local UA = "tern-graphite/0.3.0"

-- Read a JSON file as a table, or {} on any failure.
local function read_json_table(path: string): any
	local ok, text = pcall(tern.fs.read, path, 65536)
	if not ok or not text then
		return {}
	end
	local ok2, data = pcall(tern.json.decode, text)
	if not ok2 or type(data) ~= "table" then
		return {}
	end
	return data
end

-- Resolve the gt CLI auth token and hosts, following gt 1.8.6's order:
--   GRAPHITE_AUTH_TOKEN env
--   the named profile's token (GRAPHITE_PROFILE env, else user_config.profile,
--   else the profile named "default")
--   auth.authToken
--   user_config.authToken
-- Returns nil when no non-empty token is found.
function M.resolve_auth(): Auth?
	local config_dir = tern.getenv("XDG_CONFIG_HOME") or (tern.getenv("HOME") and (tern.getenv("HOME") :: string) .. "/.config") or ""
	if config_dir == "" then
		return nil
	end
	config_dir = config_dir .. "/graphite"

	local auth = read_json_table(config_dir .. "/auth")
	local user_config = read_json_table(config_dir .. "/user_config")

	-- Pick a profile name.
	local profile_name = tern.getenv("GRAPHITE_PROFILE") or user_config.profile or "default"

	-- Find the named profile (if any) and record its hosts + token.
	local p_api: string? = nil
	local p_app: string? = nil
	local p_token: string? = nil
	local alts = auth.alternativeProfiles
	if type(alts) == "table" then
		for _, p in alts do
			if type(p) == "table" and p.name == profile_name then
				local t = p.authToken
				if type(t) == "string" and t ~= "" then
					p_token = t
				end
				local hp = p.hostPrefix
				local bh = p.baseHostname
				if type(hp) == "string" and hp ~= "" then
					p_api = "https://api." .. hp .. ".graphite.com/v1"
					p_app = "https://app." .. hp .. ".graphite.com"
				elseif type(bh) == "string" and bh ~= "" then
					p_api = "https://api." .. bh .. "/v1"
					p_app = "https://app." .. bh
				end
				break
			end
		end
	end

	-- Token fallback chain: env → profile → auth.authToken → user_config.authToken.
	local token: string? = tern.getenv("GRAPHITE_AUTH_TOKEN")
	if not token or token == "" then
		token = p_token
	end
	if not token or token == "" then
		local t = auth.authToken
		if type(t) == "string" and t ~= "" then
			token = t
		end
	end
	if not token or token == "" then
		local t = user_config.authToken
		if type(t) == "string" and t ~= "" then
			token = t
		end
	end
	if not token or token == "" then
		return nil
	end

	local api = p_api or DEFAULT_API
	local app = p_app or DEFAULT_APP
	return { token = token :: string, api = api, app = app }
end

-- Perform one HTTP request and decode the JSON body. Calls done(data, err).
local function request(ctx: Ctx, method: string, path: string, body: any?, done: (data: any?, err: ApiError?) -> ())
	local url = ctx.auth.api .. path
	local headers: { [string]: string } = {
		["Authorization"] = "token " .. ctx.auth.token,
		["User-Agent"] = UA,
	}
	local body_text: string? = nil
	if body ~= nil then
		headers["Content-Type"] = "application/json"
		body_text = tern.json.encode(body)
	end
	tern.fetch(url, { method = method, headers = headers, body = body_text, timeout_ms = 30000 }, function(result: FetchResult, _cx)
		if result.error then
			done(nil, { kind = "network", message = "network error: " .. result.error })
			return
		end
		local status = result.status
		if status == 401 or status == 403 then
			done(nil, { kind = "auth", message = "Graphite rejected the CLI token" })
			return
		end
		if status == 429 then
			local ra: number? = nil
			local hv = result.headers["retry-after"]
			if hv then
				ra = tonumber(hv)
			end
			done(nil, { kind = "rate", message = "Graphite rate limit", retry_after = ra })
			return
		end
		if status < 200 or status >= 300 then
			done(nil, { kind = "http", message = "HTTP " .. tostring(status) .. " from " .. path })
			return
		end
		local ok, data = pcall(tern.json.decode, result.body)
		if not ok or type(data) ~= "table" then
			done(nil, { kind = "parse", message = "bad JSON from " .. path })
			return
		end
		done(data, nil)
	end)
end

-- Fixture-mode request: read the canned response from disk.
local function fixture_request(ctx: Ctx, method: string, path: string, body: any?, done: (data: any?, err: ApiError?) -> ())
	local dir = ctx.fixture_dir
	if not dir then
		done(nil, { kind = "http", message = "no fixture dir" })
		return
	end
	local function err_missing(key: string)
		done(nil, { kind = "http", message = "fixture missing " .. key })
	end
	-- GET /graphite/sections-summary?... -> sections_summary.json
	if string.sub(path, 1, #"/graphite/sections-summary") == "/graphite/sections-summary" then
		local data = read_json_table(dir .. "/sections_summary.json")
		if type(data.sections) ~= "table" then
			done(nil, { kind = "parse", message = "bad JSON from sections_summary.json" })
			return
		end
		done(data, nil)
		return
	end
	-- POST /graphite/check-auth -> check_auth.json
	if path == "/graphite/check-auth" then
		local data = read_json_table(dir .. "/check_auth.json")
		done(data, nil)
		return
	end
	-- POST /graphite/cli/pull-request-info -> pull_request_info.json[owner/name]
	if path == "/graphite/cli/pull-request-info" then
		local key = ""
		if type(body) == "table" then
			local o = body.repoOwner or ""
			local n = body.repoName or ""
			key = tostring(o) .. "/" .. tostring(n)
		end
		local all = read_json_table(dir .. "/pull_request_info.json")
		local data = all[key]
		if type(data) ~= "table" then
			err_missing(key)
			return
		end
		done(data, nil)
		return
	end
	-- POST /graphite/mergeability-status -> mergeability_status.json[owner/name]
	if path == "/graphite/mergeability-status" then
		local key = ""
		if type(body) == "table" then
			local o = body.repoOwner or ""
			local n = body.repoName or ""
			key = tostring(o) .. "/" .. tostring(n)
		end
		local all = read_json_table(dir .. "/mergeability_status.json")
		local data = all[key]
		if type(data) ~= "table" then
			err_missing(key)
			return
		end
		done(data, nil)
		return
	end
	done(nil, { kind = "http", message = "fixture missing " .. path })
end

local function do_request(ctx: Ctx, method: string, path: string, body: any?, done: (data: any?, err: ApiError?) -> ())
	if ctx.fixture_dir then
		fixture_request(ctx, method, path, body, done)
	else
		request(ctx, method, path, body, done)
	end
end

-- POST /graphite/check-auth. done(login?, err?)
function M.whoami(ctx: Ctx, done: (login: string?, err: ApiError?) -> ())
	do_request(ctx, "POST", "/graphite/check-auth", {}, function(data, err)
		if err then
			done(nil, err)
			return
		end
		local login = data.githubLogin
		if type(login) ~= "string" or login == "" then
			done(nil, { kind = "auth", message = "Graphite returned no login" })
			return
		end
		done(login, nil)
	end)
end

-- GET /graphite/sections-summary?first=<n>. done(sections?, err?)
function M.sections(ctx: Ctx, first: number, done: (sections: any?, err: ApiError?) -> ())
	do_request(ctx, "GET", "/graphite/sections-summary?first=" .. tostring(first), nil, function(data, err)
		if err then
			done(nil, err)
			return
		end
		local sections = data.sections
		if type(sections) ~= "table" then
			done(nil, { kind = "parse", message = "sections-summary: no sections" })
			return
		end
		done(sections, nil)
	end)
end

-- POST /graphite/cli/pull-request-info. done(byNumber?, err?)
-- Returns a map prNumber -> info for every PR returned, including downstack
-- extras the API adds automatically.
function M.pr_info(ctx: Ctx, owner: string, name: string, numbers: { number }, done: (byNumber: { [number]: any }?, err: ApiError?) -> ())
	local body = { repoOwner = owner, repoName = name, prNumbers = numbers }
	do_request(ctx, "POST", "/graphite/cli/pull-request-info", body, function(data, err)
		if err then
			done(nil, err)
			return
		end
		local result = data.result
		if type(result) == "table" and result.status == "error" then
			local msg = result.message
			done(nil, { kind = "http", message = type(msg) == "string" and msg or "pull-request-info error" })
			return
		end
		if type(result) ~= "table" or type(result.prs) ~= "table" then
			done(nil, { kind = "parse", message = "pull-request-info: no result.prs" })
			return
		end
		local out: { [number]: any } = {}
		for _, pr in result.prs do
			if type(pr) == "table" and pr.prNumber ~= nil then
				out[pr.prNumber] = pr
			end
		end
		done(out, nil)
	end)
end

-- POST /graphite/mergeability-status. done(byNumber?, err?)
function M.mergeability(ctx: Ctx, owner: string, name: string, numbers: { number }, done: (byNumber: { [number]: string }?, err: ApiError?) -> ())
	local body = { repoOwner = owner, repoName = name, prNumbers = numbers }
	do_request(ctx, "POST", "/graphite/mergeability-status", body, function(data, err)
		if err then
			done(nil, err)
			return
		end
		local statuses = data.mergeabilityStatuses
		if type(statuses) ~= "table" then
			done(nil, { kind = "parse", message = "mergeability-status: no mergeabilityStatuses" })
			return
		end
		local out: { [number]: string } = {}
		for _, s in statuses do
			if type(s) == "table" and s.prNumber ~= nil then
				local st = s.mergeabilityStatus
				if type(st) == "string" then
					out[s.prNumber] = st
				end
			end
		end
		done(out, nil)
	end)
end

return M

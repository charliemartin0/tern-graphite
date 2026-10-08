--!strict
-- User-editable config for the graphite plugin. The block reads
-- `tern.plugin.data .. "/config.json"` on every refresh, so edits apply on
-- the next poll. A missing file is created from defaults; invalid JSON
-- falls back to defaults with an error surfaced in the dock.

local M = {}

export type Prompts = {
	review: string,
	address: string,
	stack_line: string,
	review_stack: string,
	address_stack: string,
}

-- "clipboard": the send buttons copy the prompt. "pane": they open the pane picker.
export type SendMode = "clipboard" | "pane"

export type Config = {
	poll_seconds: number,
	max_prs_per_section: number,
	hidden_sections: { string },
	agent_patterns: { string },
	worktree_dir: string,
	worktree_path: string,
	gt_path: string,
	tern_path: string,
	gh_path: string,
	send_submit_default: boolean,
	send_mode: SendMode,
	show_checkout_button: boolean,
	show_diff_button: boolean,
	transition_toast: boolean,
	pr_title_first: boolean,
	pr_metadata_fields: { string },
	pr_branch_max_chars: number,
	prompts: Prompts,
}

local DEFAULTS: Config = {
	poll_seconds = 120,
	max_prs_per_section = 50,
	hidden_sections = tern.json.array({}),
	agent_patterns = { "omp", "claude", "codex", "aider", "gemini", "opencode" },
	worktree_dir = ".gt-worktrees",
	worktree_path = "",
	gt_path = "",
	tern_path = "",
	gh_path = "",
	send_submit_default = false,
	send_mode = "clipboard",
	show_checkout_button = true,
	show_diff_button = true,
	transition_toast = false,
	pr_title_first = true,
	pr_metadata_fields = { "author", "repo", "status", "age" },
	pr_branch_max_chars = 36,
	prompts = {
		review = "Review PR #{number} {title} {url}. Don't post comments, just tell me in chat",
		address = "Address the requested changes on PR #{number} {url}",
		stack_line = "PR #{number} {title} {url}",
		review_stack = "Review this stack (bottom to top):\n{prs}\nDon't post comments, just tell me in chat",
		address_stack = "Address this stack (bottom to top):\n{prs}",
	},
}
M.DEFAULTS = DEFAULTS

-- Read a JSON file as a table, or nil on any failure.
local function read_json(path: string): any?
	local ok, text = pcall(tern.fs.read, path, 1048576)
	if not ok or not text then
		return nil
	end
	local ok2, data = pcall(tern.json.decode, text)
	if not ok2 or type(data) ~= "table" then
		return nil
	end
	return data
end

-- A fresh copy of the defaults (so callers can mutate without touching DEFAULTS).
local function defaults_copy(): Config
	local d = M.DEFAULTS
	return {
		poll_seconds = d.poll_seconds,
		max_prs_per_section = d.max_prs_per_section,
		hidden_sections = tern.json.array({}),
		agent_patterns = { table.unpack(d.agent_patterns) },
		worktree_dir = d.worktree_dir,
		worktree_path = d.worktree_path,
		gt_path = d.gt_path,
		tern_path = d.tern_path,
		gh_path = d.gh_path,
		show_checkout_button = d.show_checkout_button,
		show_diff_button = d.show_diff_button,
		send_submit_default = d.send_submit_default,
		send_mode = d.send_mode,
		transition_toast = d.transition_toast,
		pr_title_first = d.pr_title_first,
		pr_metadata_fields = { table.unpack(d.pr_metadata_fields) },
		pr_branch_max_chars = d.pr_branch_max_chars,
		prompts = {
			review = d.prompts.review,
			address = d.prompts.address,
			stack_line = d.prompts.stack_line,
			review_stack = d.prompts.review_stack,
			address_stack = d.prompts.address_stack,
		},
	}
end

local function num_or(data: any, key: string, default: number, min: number, max: number?): number
	local v = data[key]
	if type(v) ~= "number" or v ~= v then -- NaN check
		v = default
	end
	if v < min then
		v = min
	end
	if max and v > max then
		v = max
	end
	return v
end

local function str_or(data: any, key: string, default: string): string
	local v = data[key]
	if type(v) ~= "string" then
		return default
	end
	return v
end

-- A list key is used only when it is a JSON array whose every item is a
-- string; otherwise the default list applies.
local function list_or(data: any, key: string, default: { string }): { string }
	local v = data[key]
	if type(v) ~= "table" then
		return { table.unpack(default) }
	end
	-- Must be a pure array (all keys are positive integers).
	local n = 0
	for k in pairs(v) do
		if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
			return { table.unpack(default) }
		end
		if k > n then
			n = k
		end
	end
	local out: { string } = {}
	for i = 1, n do
		local item = v[i]
		if type(item) ~= "string" then
			return { table.unpack(default) }
		end
		out[i] = item
	end
	return out
end

local function send_mode_or(data: any, default: SendMode): SendMode
	local v = data.send_mode
	if v == "clipboard" or v == "pane" then
		return v
	end
	return default
end

local function bool_or(data: any, key: string, default: boolean): boolean
	local v = data[key]
	return if type(v) == "boolean" then v else default
end

local function metadata_fields_or(data: any): { string }
	local allowed = { author = true, repo = true, branch = true, status = true, age = true }
	local requested = list_or(data, "pr_metadata_fields", M.DEFAULTS.pr_metadata_fields)
	local result: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, field in requested do
		if allowed[field] and not seen[field] then
			table.insert(result, field)
			seen[field] = true
		end
	end
	return result
end
local function prompts_or(data: any, default: Prompts): Prompts
	local p = data.prompts
	if type(p) ~= "table" then
		return {
			review = default.review,
			address = default.address,
			stack_line = default.stack_line,
			review_stack = default.review_stack,
			address_stack = default.address_stack,
		}
	end
	local function pick(k: string): string
		local v = p[k]
		if type(v) == "string" then
			return v
		end
		return (default :: any)[k]
	end
	return {
		review = pick("review"),
		address = pick("address"),
		stack_line = pick("stack_line"),
		review_stack = pick("review_stack"),
		address_stack = pick("address_stack"),
	}
end

-- Read config.json from the plugin data dir. Returns (config, error?).
-- A missing file is written from defaults and the defaults returned (no error).
-- Invalid JSON returns defaults plus "config.json: <reason>".
-- Present-but-missing/wrong-type keys fall back per key (not an error).
function M.load(): (Config, string?)
	local path = tern.plugin.data .. "/config.json"
	-- Only create the file when it truly doesn't exist; a read failure for
	-- other reasons (symlink, non-regular, oversize) must not overwrite it.
	if not tern.fs.exists(path) then
		pcall(tern.fs.write, path, tern.json.encode(M.DEFAULTS, true))
		return defaults_copy(), nil
	end
	local ok, text = pcall(tern.fs.read, path, 1048576)
	if not ok or not text then
		return defaults_copy(), "config.json: " .. tostring(text)
	end
	local ok2, data = pcall(tern.json.decode, text)
	if not ok2 then
		return defaults_copy(), "config.json: " .. tostring(data)
	end
	if type(data) ~= "table" then
		return defaults_copy(), "config.json: not a JSON object"
	end
	local cfg: Config = {
		poll_seconds = num_or(data, "poll_seconds", M.DEFAULTS.poll_seconds, 30, nil),
		max_prs_per_section = num_or(data, "max_prs_per_section", M.DEFAULTS.max_prs_per_section, 1, 100),
		hidden_sections = list_or(data, "hidden_sections", M.DEFAULTS.hidden_sections),
		agent_patterns = list_or(data, "agent_patterns", M.DEFAULTS.agent_patterns),
		worktree_dir = str_or(data, "worktree_dir", M.DEFAULTS.worktree_dir),
		worktree_path = str_or(data, "worktree_path", M.DEFAULTS.worktree_path),
		gt_path = str_or(data, "gt_path", M.DEFAULTS.gt_path),
		tern_path = str_or(data, "tern_path", M.DEFAULTS.tern_path),
		gh_path = str_or(data, "gh_path", M.DEFAULTS.gh_path),
		show_checkout_button = bool_or(data, "show_checkout_button", M.DEFAULTS.show_checkout_button),
		show_diff_button = bool_or(data, "show_diff_button", M.DEFAULTS.show_diff_button),
		send_submit_default = (function(): boolean
			local v = data.send_submit_default
			if type(v) == "boolean" then return v end
			return M.DEFAULTS.send_submit_default
		end)(),
		send_mode = send_mode_or(data, M.DEFAULTS.send_mode),
		transition_toast = (function(): boolean
			local v = data.transition_toast
			if type(v) == "boolean" then return v end
			return M.DEFAULTS.transition_toast
		end)(),
		pr_title_first = bool_or(data, "pr_title_first", M.DEFAULTS.pr_title_first),
		pr_metadata_fields = metadata_fields_or(data),
		pr_branch_max_chars = num_or(data, "pr_branch_max_chars", M.DEFAULTS.pr_branch_max_chars, 12, 120),
		prompts = prompts_or(data, M.DEFAULTS.prompts),
	}
	return cfg, nil
end

-- Replace `{name}` with vars[name]; unknown names are left as-is. Uses a
-- function replacement so `%` in values (e.g. titles) is treated literally.
function M.render(template: string, vars: { [string]: string }): string
	return (string.gsub(template, "{(%w+)}", function(name: string): string
		local v = vars[name]
		if v == nil then
			return "{" .. name .. "}"
		end
		return v
	end))
end

return M

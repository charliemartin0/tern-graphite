--!strict
-- The `inbox` block: a read-only PR review inbox mirroring the user's
-- Graphite inbox sections (signed in through the gt CLI), plus the focused
-- repo's Graphite stack with the common gt actions.
-- Tabs: 1 = Inbox (default), 2 = Stack.
-- Keys: r refresh, 1 inbox tab, 2 stack tab, Esc cancels a confirm/send picker.

local common = require("./common")
local graphite = require("./graphite")
local config = require("./config")
local ui = tern.ui

type Repo = { path: string, owner: string, name: string, nwo: string }
type Problem = { text: string, detail: string? }
type Confirm = { act: string, label: string, payload: string }
type AgentPane = { id: number, title: string, program: string, focused: boolean, agent: boolean }
type SendTarget = { prs: { common.PR }, mine: boolean, submit: boolean }
type Section = { name: string, id: string, total: number, counts: boolean, prs: { common.PR } }

type State = {
	cx: BlockCx, tab: "inbox" | "stack", repo: Repo?, repo_loading: boolean,
	sections: { Section }, stacks: { common.GtBranch }, fetched: number?, loading: boolean,
	problem: Problem?, rate_limited_until: number?, timer: TimerHandle?, confirm: Confirm?,
	send: SendTarget?, send_panes: { AgentPane }?, send_loading: boolean, stack_problem: Problem?,
	fixture: boolean, me: string?, auth: graphite.Auth?, signin: ("missing" | "rejected")?,
	cfg: config.Config, cfg_error: string?, fixture_signedout: boolean,
	prev_section_keys: { [string]: { [string]: boolean } }, -- section name -> set of "repo/n"
	section_baseline: boolean,
}

local running: { [number]: State } = {}

local function cancel_timer(state: State)
	if state.timer then state.timer:cancel() state.timer = nil end
end
local function retire(state: State)
	if running[state.cx.pane] == state then running[state.cx.pane] = nil end
	cancel_timer(state) state.loading = false
end
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then return false end
	for _, p in tern.pane.list() do if p.pane == state.cx.pane then return true end end
	retire(state) return false
end
local function first_lines(text: string, n: number): string
	local out = {}
	for line in string.gmatch(text, "[^\n]+") do table.insert(out, line) if #out == n then break end end
	return table.concat(out, "\n")
end
local function run(argv: { string }, cwd: string?, timeout_ms: number, done: (status: number, stdout: string, stderr: string, timed_out: boolean) -> ())
	tern.process.run(argv, { cwd = cwd, timeout_ms = timeout_ms }, function(result: ProcessResult, _)
		done(result.status, result.stdout, result.stderr, result.timed_out)
	end)
end
local function clock(t: number): string return os.date("!%H:%M", t) :: string end

local function find_pr(state: State, repo: string, n: number): common.PR?
	for _, sec in state.sections do
		for _, pr in sec.prs do if pr.repo == repo and pr.number == n then return pr end end
	end
	return nil
end

-- ---------- repo detection ----------
local refresh: (State) -> ()
local schedule: (State) -> ()
local prompt_for: ({ common.PR }, boolean, config.Config) -> string

local function detect_repo(state: State)
	state.repo_loading = true state.cx:render()
	local c = state.cx.cwd
	if not c or c == "" then
		state.repo_loading = false state.repo = nil state.cx:render() refresh(state) return
	end
	run({ "git", "-C", c, "remote", "get-url", "origin" }, nil, 5000, function(status, stdout, _stderr, _to)
		if not alive(state) then return end
		if status ~= 0 then
			state.repo_loading = false state.repo = nil state.cx:render() refresh(state) return
		end
		local url = string.match(stdout, "^%s*(%S+)") or ""
		url = string.gsub(url, "%.git$", "") url = string.gsub(url, "/$", "")
		local owner, name = string.match(url, "[:/]([^/:]+)/([^/:]+)$")
		if owner and name and owner ~= "" and name ~= "" then
			run({ "git", "-C", c, "rev-parse", "--show-toplevel" }, nil, 5000, function(s2, out2, _e2, _t2)
				if not alive(state) then return end
				if s2 == 0 then
					local path = string.match(out2, "^%s*(%S+)") or c
					state.repo = { path = path, owner = owner, name = name, nwo = owner .. "/" .. name }
				else
					state.repo = nil
				end
				state.repo_loading = false state.cx:render() refresh(state)
			end)
		else
			state.repo_loading = false state.repo = nil state.cx:render() refresh(state)
		end
	end)
end

-- ---------- stack (gt log) ----------
local function fetch_stack(state: State)
	if not state.repo then return end
	if state.fixture then
		local ok, text = pcall(tern.fs.read, tern.plugin.dir .. "/test/fixtures/gt_log_short.txt", 65536)
		if ok and text then state.stacks = common.parse_gt_log(text) state.stack_problem = nil
		else state.stacks = {} state.stack_problem = { text = "fixture gt_log_short.txt missing" } end
		state.cx:render() return
	end
	run({ common.bin("gt"), "log", "short", "--no-interactive" }, state.repo.path, common.GT_TIMEOUT_MS, function(status, stdout, stderr, to)
		if not alive(state) then return end
		if to then state.stack_problem = { text = "gt log timed out." }
		elseif status ~= 0 then state.stack_problem = { text = "gt log exited " .. tostring(status) .. ".", detail = first_lines(stderr, 4) }
		else state.stacks = common.parse_gt_log(stdout) state.stack_problem = nil end
		state.cx:render()
	end)
end
-- ---------- inbox fetch ----------
local function assign_stacks(owner: string, name: string, info: { [number]: any }, prs: { common.PR })
	local nwo = owner .. "/" .. name
	for _, pr in prs do
		if pr.repo ~= nwo then continue end
		local cur = pr.number local seen: { [number]: boolean } = {} local root = cur local depth = 0
		while cur and not seen[cur] do
			seen[cur] = true
			local ic = info[cur]
			if not ic then break end
			local parent = ic.dependentPrNumber
			if parent == nil or not info[parent] then root = cur break end
			root = parent depth += 1 cur = parent
		end
		pr.stackId = nwo .. "#" .. tostring(root) pr.stackDepth = depth
	end
end

-- Best-effort: fetch the unresolved review-thread count for PRs whose merge
-- status is CHANGES_REQUESTED or UNRESOLVED_COMMENTS, via the gh CLI's
-- GraphQL endpoint. Sets pr.comments and re-renders. No-op when `gh` is
-- missing/unauthed or in fixture mode; the inbox stays usable without it.
local function fetch_comment_counts_impl(state: State, sections: { Section })
	if not alive(state) then return end
	-- Collect candidate PRs (dedup by key).
	local seen: { [string]: boolean } = {}
	local targets: { common.PR } = {}
	for _, sec in sections do
		for _, pr in sec.prs do
			if pr.merge == "CHANGES_REQUESTED" or pr.merge == "UNRESOLVED_COMMENTS" then
				if not seen[pr.key] then seen[pr.key] = true table.insert(targets, pr) end
			end
		end
	end
	if #targets == 0 then return end
	local gh = common.bin("gh")
	local query = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved}}}}}'
	local pending = #targets
	for _, pr in targets do
		local argv = { gh, "api", "graphql", "-f", "owner=" .. pr.owner, "-f", "name=" .. pr.name, "-F", "number=" .. tostring(pr.number), "-f", "query=" .. query }
		run(argv, nil, 15000, function(status, stdout, _stderr, _to)
			if not alive(state) then return end
			pending -= 1
			if status == 0 then
				local ok, data = pcall(tern.json.decode, stdout)
				if ok and type(data) == "table" then
					local threads = (((data.data or {}).repository or {}).pullRequest or {}).reviewThreads or {}
					local nodes = threads.nodes
					if type(nodes) == "table" then
						local unresolved = 0
						for _, t in nodes do
							if type(t) == "table" and t.isResolved ~= true then unresolved += 1 end
						end
						pr.comments = unresolved
					end
				end
			end
			if pending == 0 and alive(state) then state.cx:render() end
		end)
	end
end
fetch_comment_counts = fetch_comment_counts_impl

local function fetch_inbox(state: State)
	if not alive(state) or state.loading then return end
	cancel_timer(state) state.loading = true state.cx:render()
	state.cfg, state.cfg_error = config.load()

	local auth: graphite.Auth?
	if state.fixture then
		if state.fixture_signedout then auth = nil
		else auth = { token = "fixture", api = "https://api.graphite.com/v1", app = "https://app.graphite.com" } end
	else
		auth = graphite.resolve_auth()
	end
	state.auth = auth
	if not auth then
		state.signin = "missing" state.me = nil state.loading = false state.sections = {} state.cx:render() return
	end
	local ctx: graphite.Ctx = { auth = auth :: graphite.Auth, fixture_dir = if state.fixture then tern.plugin.dir .. "/test/fixtures" else nil }

	local function fail(err: graphite.ApiError)
		if not alive(state) then return end
		state.loading = false
		if err.kind == "auth" then
			state.signin = "rejected" state.me = nil state.sections = {} state.cx:render() return
		elseif err.kind == "rate" then
			state.rate_limited_until = os.time() + (err.retry_after or 300)
			state.problem = { text = "Graphite rate limit — retrying in " .. tostring(err.retry_after or 300) .. "s" }
		else
			state.problem = { text = err.message }
		end
		state.cx:render() schedule(state)
	end

	local function after_whoami()
		if not alive(state) then return end
		graphite.sections(ctx, state.cfg.max_prs_per_section, function(sections, err)
			if not alive(state) then return end
			if err then fail(err) return end
			local raw_sections: { Section } = {}
			local by_repo: { [string]: { number } } = {}
			local by_key: { [string]: common.PR } = {}
			for _, s in sections do
				if type(s) ~= "table" then continue end
				local prs: { common.PR } = {}
				local raw_prs = s.prs
				if type(raw_prs) == "table" then
					for _, p in raw_prs do
						if type(p) == "table" and p.number ~= nil then
							local owner = "" local name = ""
							local repo = p.repo
							if type(repo) == "table" then owner = repo.owner or "" name = repo.name or "" end
							local author_login = ""
							local a = p.author
							if type(a) == "table" then author_login = a.login or "" end
							local pkey = owner .. "/" .. name .. "#" .. tostring(p.number)
							local pr = by_key[pkey]
							if pr == nil then
								pr = {
									key = pkey, repo = owner .. "/" .. name,
									owner = owner, name = name, number = p.number, title = p.title or "",
									author = author_login, mine = author_login ~= "" and author_login == (state.me or ""),
									state = p.state or "OPEN", isDraft = false, branch = "", base = "", url = "",
									createdAt = common.epoch(p.createdAt or ""), updatedAt = common.epoch(p.updatedAt or ""),
									reviewDecision = nil, merge = nil, stackId = nil, stackDepth = nil,
								}
								local rd = p.reviewDecision
								if type(rd) == "string" and rd ~= "" then pr.reviewDecision = rd end
								by_key[pkey] = pr
								local key = owner .. "/" .. name
								if not by_repo[key] then by_repo[key] = {} end
								table.insert(by_repo[key], p.number)
							end
							table.insert(prs, pr)
						end
					end
				end
				local total = s.totalUnpaginatedPrs or #prs
				table.insert(raw_sections, {
					name = s.name or "", id = s.sectionId or "",
					total = type(total) == "number" and total or #prs,
					counts = s.includeInTotalCount == true, prs = prs,
				})
			end

			local repo_keys: { string } = {}
			for k in by_repo do table.insert(repo_keys, k) end
			local function commit(raw: { Section })
				-- Ignore stale completed rows left in Graphite's Drafts section.
				local hidden: { [string]: boolean } = {}
				for _, h in state.cfg.hidden_sections do hidden[string.lower(h)] = true end
				local shown: { Section } = {}
				for _, sec in raw do
					if string.lower(sec.name) == "drafts" then
						local open_prs: { common.PR } = {}
						local removed = 0
						for _, pr in sec.prs do
							if pr.state == "OPEN" then
								table.insert(open_prs, pr)
							else
								removed += 1
							end
						end
						sec.prs = open_prs
						sec.total = math.max(#open_prs, sec.total - removed)
					end
					if not hidden[string.lower(sec.name)] then table.insert(shown, sec) end
				end
				state.loading = false state.signin = nil state.rate_limited_until = nil
				state.sections = shown state.fetched = os.time()
				pcall(function()
					local count = 0
					for _, sec in raw do if sec.counts then count += sec.total end end
					tern.kv.set("summary", { at = state.fetched, count = count })
				end)
				-- Transition toast: fire when a PR newly appears in "Needs
				-- your review" or "Returned to you". Off by default.
				if state.cfg.transition_toast and state.section_baseline then
					local watched = { ["needs your review"] = true, ["returned to you"] = true }
					for _, sec in shown do
						local key = string.lower(sec.name)
						if watched[key] then
							local prev = state.prev_section_keys[key] or {}
							for _, pr in sec.prs do
								if not prev[pr.key] then
									state.cx:toast("info", "graphite", pr.key .. " moved into " .. sec.name)
								end
							end
						end
					end
				end
				-- Record this fetch's keys for the next diff.
				local next_keys: { [string]: { [string]: boolean } } = {}
				for _, sec in shown do
					local k = string.lower(sec.name)
					local set: { [string]: boolean } = {}
					for _, pr in sec.prs do set[pr.key] = true end
					next_keys[k] = set
				end
				state.prev_section_keys = next_keys
				state.section_baseline = true
				state.cx:render() schedule(state)
				-- Best-effort comment-count enrichment (gh); fills pr.comments
				-- for CHANGES_REQUESTED / UNRESOLVED_COMMENTS rows.
				if not state.fixture then
					fetch_comment_counts(state, shown)
				end
			end
			if #repo_keys == 0 then
				if not alive(state) then return end
				state.problem = nil
				commit(raw_sections) return
			end
			local pending = #repo_keys * 2
			local info_by_repo: { [string]: { [number]: any } } = {}
			local merge_by_repo: { [string]: { [number]: string } } = {}
			local enrichment_err: graphite.ApiError? = nil
			local function finish_enrichment()
				if not alive(state) then return end
				for _, rk in repo_keys do
					local owner, name = string.match(rk, "^([^/]+)/(.+)$")
					if not owner then continue end
					local info = info_by_repo[rk] local merge = merge_by_repo[rk]
					local repo_prs: { common.PR } = {}
					for _, sec in raw_sections do for _, pr in sec.prs do if pr.repo == rk then table.insert(repo_prs, pr) end end end
					if info then
						for _, pr in repo_prs do
							local i = info[pr.number]
							if i then
								if i.state == "OPEN" or i.state == "MERGED" or i.state == "CLOSED" then
									pr.state = i.state
								end
								pr.branch = i.headRefName or ""
								pr.base = i.baseRefName or ""
								pr.isDraft = i.isDraft == true and pr.state == "OPEN"
								local u = i.url
								pr.url = (type(u) == "string" and u ~= "") and u or common.graphite_url((auth :: graphite.Auth).app, pr.owner, pr.name, pr.number)
							else
								pr.url = common.graphite_url((auth :: graphite.Auth).app, pr.owner, pr.name, pr.number)
							end
							if merge then local m = merge[pr.number] if m then pr.merge = m end end
						end
						assign_stacks(owner, name, info, repo_prs)
					else
						for _, pr in repo_prs do pr.url = common.graphite_url((auth :: graphite.Auth).app, pr.owner, pr.name, pr.number) end
					end
				end
			state.problem = if enrichment_err then { text = "partial fetch: " .. (enrichment_err :: graphite.ApiError).message } else nil
			commit(raw_sections)
		end
			local function one_done() pending -= 1 if pending == 0 then finish_enrichment() end end
			for _, rk in repo_keys do
				local owner, name = string.match(rk, "^([^/]+)/(.+)$")
				if not owner then one_done() one_done() continue end
				local numbers = by_repo[rk]
				graphite.pr_info(ctx, owner, name, numbers, function(byNumber, err)
					if not alive(state) then return end
					if err and not enrichment_err then enrichment_err = err end
					if byNumber then info_by_repo[rk] = byNumber end
					one_done()
				end)
				graphite.mergeability(ctx, owner, name, numbers, function(byNumber, err)
					if not alive(state) then return end
					if err and not enrichment_err then enrichment_err = err end
					if byNumber then merge_by_repo[rk] = byNumber end
					one_done()
				end)
			end
		end)
	end

	if state.me == nil then
		graphite.whoami(ctx, function(login, err)
			if not alive(state) then return end
			if err then
				if err.kind == "auth" then
					state.signin = "rejected" state.me = nil state.loading = false state.sections = {} state.cx:render() return
				end
				fail(err) return
			end
			state.me = login after_whoami()
		end)
	else
		after_whoami()
	end
end

schedule = function(state: State)
	cancel_timer(state)
	if not alive(state) then return end
	local delay_ms = state.cfg.poll_seconds * 1000
	if state.rate_limited_until then
		local remaining = (state.rate_limited_until :: number) - os.time()
		if remaining > 0 then delay_ms = remaining * 1000 else state.rate_limited_until = nil end
	end
	state.timer = tern.timer(delay_ms, function(_cx)
		state.timer = nil
		if not alive(state) then return end
		fetch_inbox(state)
	end)
end

refresh = function(state: State)
	if not alive(state) then return end
	fetch_inbox(state)
	fetch_stack(state)
end
-- ---------- rendering helpers ----------

local function badge(label: string, act: string, tone: string): Node
	local n = ui.badge(label, tone)
	local p: { [string]: any } = n.p or {}
	p.actions = { click = act }
	n.p = p
	return n
end

-- A blank line of vertical breathing room. `ui.col`/`ui.section` only add
-- small gaps; this gives a visible blank line between packed rows.
local function spacer(): Node
	return ui.text({ ui.span(" ") })
end

local MERGE_LABELS: { [string]: { string } } = {
	CHANGES_REQUESTED = { "changes requested", "warning" },
	UNRESOLVED_COMMENTS = { "unresolved comments", "warning" },
	FAILING_REQUIRED = { "CI failing", "error" },
	FAILED_MQ_ENTRY_AT_CURRENT_HEAD = { "CI failing", "error" },
	FAILURE_HANDLING = { "CI failing", "error" },
	MERGE_CONFLICTS = { "conflicts", "error" },
	WAITING_ON_REQUIRED_CI = { "CI running", "muted" },
	RUNNING = { "CI running", "muted" },
	NEEDS_REVIEWERS = { "needs reviewers", "muted" },
	NEEDS_APPROVALS = { "needs approval", "muted" },
	NEEDS_CODEOWNER_APPROVALS = { "needs approval", "muted" },
	WAITING_ON_DOWNSTACK = { "waiting on downstack", "muted" },
	HARD_WAITING_ON_DOWNSTACK = { "waiting on downstack", "muted" },
	CROSS_PARTITION_DOWNSTACK_IN_QUEUE = { "waiting on downstack", "muted" },
	REBASING = { "merging", "accent" },
	WAITING_TO_MERGE = { "merging", "accent" },
	BRANCH_LOCKED = { "branch locked", "muted" },
	STALE = { "stale", "muted" },
}

local function merge_label(status: string): (string, string)
	local e = MERGE_LABELS[status]
	if e then return e[1], e[2] end
	if string.find(status, "READY_TO_MERGE", 1, true) then return "ready", "success" end
	if string.find(status, "NEEDS_RESTACK__", 1, true) then return "needs restack", "warning" end
	return string.lower(string.gsub(status, "_", " ")), "muted"
end

local function pr_title(pr: common.PR): { Span | string }
	return {
		ui.span("#" .. tostring(pr.number), "strong"),
		ui.span(" "),
		ui.link(pr.title, pr.url),
	}
end

local function truncate_middle(text: string, max_chars: number): string
	if #text <= max_chars then return text end
	local kept = max_chars - 1
	local left = math.ceil(kept / 2)
	local right = kept - left
	return string.sub(text, 1, left) .. "…" .. string.sub(text, #text - right + 1)
end

local function metadata_field(state: State, pr: common.PR, now: number, field: string): { Span | string }?
	if field == "author" and pr.author ~= "" then
		return { ui.span(pr.author, "muted") }
	elseif field == "repo" then
		return { ui.span(pr.name, "muted") }
	elseif field == "branch" and pr.branch ~= "" then
		return { ui.span(truncate_middle(pr.branch, state.cfg.pr_branch_max_chars), "muted") }
	elseif field == "status" then
		local out: { Span | string } = {}
		if pr.merge then
			local label, tone = merge_label(pr.merge)
			table.insert(out, ui.span(label, tone))
			if pr.comments ~= nil and pr.comments > 0 and
				(pr.merge == "CHANGES_REQUESTED" or pr.merge == "UNRESOLVED_COMMENTS") then
				table.insert(out, ui.span(tostring(pr.comments), tone))
			end
		end
		if pr.isDraft then table.insert(out, ui.span("draft", "muted")) end
		if pr.state == "MERGED" then
			table.insert(out, ui.span("merged", "muted"))
		elseif pr.state == "CLOSED" then
			table.insert(out, ui.span("closed", "muted"))
		end
		if #out > 0 then return out end
	elseif field == "age" then
		return { ui.span(common.age(pr.updatedAt, now), "dim") }
	end
	return nil
end

local function pr_metadata(state: State, pr: common.PR, now: number): { Span | string }
	local out: { Span | string } = {}
	local has_field = false
	for _, field in state.cfg.pr_metadata_fields do
		local value = metadata_field(state, pr, now, field)
		if value then
			if has_field then table.insert(out, ui.span(" · ", "dim")) end
			for i, span in value do
				if i > 1 then table.insert(out, ui.span(" ")) end
				table.insert(out, span)
			end
			has_field = true
		end
	end
	return out
end

local function pr_actions(state: State, pr: common.PR): Node
	local p = pr.repo .. "/" .. tostring(pr.number)
	local buttons: { Node } = {}
	-- Only offer checkout when this block was opened in the PR's repo.
	-- Keep the handler-side check too; UI visibility is not authorization.
	if state.repo and pr.repo == state.repo.nwo and pr.branch and pr.branch ~= "" then
		table.insert(buttons, badge("Checkout", "checkout:" .. p, "muted"))
	end
	table.insert(buttons, badge("Send to agent", (if pr.mine then "send-mine:" else "send:") .. p, "accent"))
	return ui.row(buttons)
end
local function render_pr(state: State, pr: common.PR, now: number, stacked: boolean): Node
	local title = pr_title(pr)
	local metadata = pr_metadata(state, pr, now)
	if stacked then
		table.insert(title, 1, ui.span("↳ ", "accent"))
	end
	local children: { Node } = {}
	if state.cfg.pr_title_first then
		table.insert(children, ui.text(title))
		if #metadata > 0 then table.insert(children, ui.text(metadata)) end
	else
		if #metadata > 0 then
			table.insert(title, ui.span("  ·  ", "dim"))
			for _, span in metadata do table.insert(title, span) end
		end
		table.insert(children, ui.text(title))
	end
	if pr.state == "OPEN" then
		if stacked then
			table.insert(children, ui.row({ ui.text({ ui.span("   ") }), pr_actions(state, pr) }))
		else
			table.insert(children, pr_actions(state, pr))
		end
	end
	return ui.col(children)
end

-- Group PRs: stack buckets (2+ PRs sharing a stackId) first, ordered by
-- shallowest depth; then one standalone group with the rest, oldest-first.
local function grouped(list: { common.PR }): { { prs: { common.PR }, stack: boolean } }
	local sorted = { table.unpack(list) }
	table.sort(sorted, function(a, b) return a.updatedAt < b.updatedAt end)
	local by_stack: { [string]: { common.PR } } = {}
	local standalone: { common.PR } = {}
	for _, pr in sorted do
		if pr.stackId and pr.stackId ~= "" then
			if not by_stack[pr.stackId] then by_stack[pr.stackId] = {} end
			table.insert(by_stack[pr.stackId], pr)
		else
			table.insert(standalone, pr)
		end
	end
	local groups: { { prs: { common.PR }, stack: boolean } } = {}
	local stack_keys: { string } = {}
	for k, v in by_stack do
		if #v > 1 then table.insert(stack_keys, k)
		else table.insert(standalone, v[1]) end
	end
	table.sort(stack_keys, function(a, b)
		local da, db = 999, 999
		for _, pr in by_stack[a] do da = math.min(da, pr.stackDepth or 999) end
		for _, pr in by_stack[b] do db = math.min(db, pr.stackDepth or 999) end
		if da ~= db then return da < db end
		return by_stack[a][1].updatedAt < by_stack[b][1].updatedAt
	end)
	for _, k in stack_keys do
		local g = by_stack[k]
		table.sort(g, function(a, b) return (a.stackDepth or 0) < (b.stackDepth or 0) end)
		table.insert(groups, { prs = g, stack = true })
	end
	if #standalone > 0 then
		table.sort(standalone, function(a, b) return a.updatedAt < b.updatedAt end)
		table.insert(groups, { prs = standalone, stack = false })
	end
	return groups
end

local function render_section(state: State, sec: Section, now: number): Node
	local children: { Node } = {}
	if #sec.prs == 0 then
		table.insert(children, ui.text({ ui.span("Nothing here.", "muted") }))
	else
		local app = (state.auth and state.auth.app) or "https://app.graphite.com"
		local first = true
		for _, g in grouped(sec.prs) do
			if not first then
				table.insert(children, spacer())
			end
			first = false
			if g.stack then
				local ids: { string } = {}
				local all_mine = true
				for _, pr in g.prs do
					table.insert(ids, pr.repo .. "/" .. tostring(pr.number))
					if not pr.mine then all_mine = false end
				end
				local payload = "send-stack:" .. (if all_mine then "mine" else "rev") .. ":" .. table.concat(ids, ",")
				table.insert(children, ui.row({
					ui.text({ ui.span("Stack · " .. tostring(#g.prs) .. " PRs", "strong accent") }),
					badge("Send stack to agent", payload, "accent"),
				}))
			end
			for _, pr in g.prs do
				table.insert(children, render_pr(state, pr, now, g.stack))
			end
		end
		if sec.total > #sec.prs then
			table.insert(children, ui.text({ ui.link("Showing " .. tostring(#sec.prs) .. " of " .. tostring(sec.total) .. " — open the rest in Graphite", app, "muted") }))
		end
	end
	local node = ui.section({ ui.span(sec.name .. " (" .. tostring(sec.total) .. ")") }, children)
	if #sec.prs == 0 then
		local p: { [string]: any } = node.p or {}
		p.collapsed = true
		node.p = p
	end
	return node
end

local function render_inbox(state: State, now: number): Node
	local children: { Node } = {}
	for i, sec in state.sections do
		if i > 1 then
			table.insert(children, spacer())
		end
		table.insert(children, render_section(state, sec, now))
	end
	return ui.col(children)
end

local function render_signin(state: State): Node
	local body: string
	if state.signin == "missing" then
		body = "This block reads your Graphite inbox using the Graphite CLI login. Install `gt`, open the sign-in page, then paste the `gt auth --token …` command it shows into a terminal."
	else
		body = "Graphite rejected your CLI token. Sign in again: open the sign-in page, then paste the `gt auth --token …` command it shows into a terminal."
	end
	return ui.card({ ui.span("Sign in to Graphite", "strong") }, {
		ui.md(body),
		ui.row({
			badge("Open sign-in page", "signin:open", "accent"),
			badge("Open a terminal", "signin:terminal", "muted"),
			badge("Check again", "refresh", "muted"),
		}),
	})
end
-- ---------- stack tab ----------

local function render_stack_tree(state: State): Node
	if #state.stacks == 0 then
		return ui.text({ ui.span("No tracked branches.", "muted") })
	end
	local order: { string } = {}
	local by_stack: { [string]: { common.GtBranch } } = {}
	for _, b in state.stacks do
		if not by_stack[b.stackId] then by_stack[b.stackId] = {} table.insert(order, b.stackId) end
		table.insert(by_stack[b.stackId], b)
	end
	local roots: { TreeNode } = {}
	for _, sid in order do
		local branches = by_stack[sid]
		local nodes_by_branch: { [string]: TreeNode } = {}
		local root: TreeNode? = nil
		for _, b in branches do
			local label: { Span | string } = { ui.span(b.branch, "strong") }
			if b.state == "frozen" then
				table.insert(label, ui.span(" frozen", "muted"))
			elseif b.state == "needs restack" then
				table.insert(label, ui.span(" needs restack", "warning"))
			end
			if b.pr then
				table.insert(label, ui.span(" #" .. tostring(b.pr), "accent"))
			end
			local node: TreeNode = { label = label, open = true, children = {} }
			nodes_by_branch[b.branch] = node
			if b.depth == 0 or root == nil then
				if root == nil then root = node
				else table.insert((root :: TreeNode).children, node) end
			else
				local parent = root
				for _, pb in branches do
					if pb == b then break end
					if (pb.depth or 0) < (b.depth or 0) then parent = nodes_by_branch[pb.branch] end
				end
				if parent then table.insert((parent :: TreeNode).children, node) end
			end
		end
		if root then table.insert(roots, root) end
	end
	return ui.tree(roots)
end

local function stack_actions(state: State): Node
	local r = state.repo
	if not r then
		return ui.text({ ui.span("Open this block from a pane inside a git repository to see its Graphite stack.", "muted") })
	end
	local function pane(label: string, act: string, tone: string): Node
		return badge(label, act, tone)
	end
	return ui.row({
		pane("Checkout", "gt:checkout", "accent"),
		pane("Up", "gt:up", "muted"),
		pane("Down", "gt:down", "muted"),
		pane("Create", "gt:create", "muted"),
		pane("Modify", "gt:modify", "muted"),
		pane("Submit --draft", "gt:submit", "accent"),
		pane("Sync", "gt:sync", "muted"),
		pane("Restack", "gt:restack", "muted"),
		pane("Move", "gt:move", "muted"),
		pane("Fold", "gt:fold", "muted"),
		pane("Delete", "gt:delete", "error"),
	})
end

-- ---------- confirm bar & send picker ----------

local function render_confirm(state: State): Node
	local c = state.confirm :: Confirm
	local head: { Span | string } = { ui.span("Confirm: ", "strong"), ui.span(c.label, "warning") }
	return ui.card({ ui.span("Confirm") }, { ui.text(head), spacer(), ui.row({ badge("Yes, " .. c.label, "confirm-yes", "error"), badge("Cancel", "confirm-no", "muted") }) })
end

local function render_send_picker(state: State): Node
	local o = state.send :: SendTarget
	local prs = o.prs
	local head: Node
	if #prs == 1 then
		local pr = prs[1]
		head = ui.col({
			ui.text({
				ui.span("Send to agent: ", "strong"),
				ui.span("#" .. tostring(pr.number) .. " ", "strong"),
				ui.link(pr.title, pr.url),
			}),
			ui.row({ badge("Cancel", "send-cancel", "muted") }),
		})
	else
		local spans: { Span | string } = {
			ui.span("Send stack to agent: ", "strong"),
			ui.span(tostring(#prs) .. " PRs  ", "muted"),
		}
		for i, pr in prs do
			if i > 1 then table.insert(spans, ui.span(" → ", "muted")) end
			table.insert(spans, ui.span("#" .. tostring(pr.number), "strong"))
		end
		head = ui.col({
			ui.text(spans),
			ui.row({ badge("Cancel", "send-cancel", "muted") }),
		})
	end
	if state.send_loading then
		return ui.col({ head, ui.progress(nil, "Listing panes…") })
	end
	local panes = state.send_panes or {}
	-- Submit toggle: paste-only (default) vs paste + Enter.
	local submit = state.send.submit
	local toggle_label = if submit then "Submit: paste + Enter  (on)" else "Submit: paste only  (off)"
	local toggle_tone = if submit then "accent" else "muted"
	local toggle = badge(toggle_label, "send-toggle-submit", toggle_tone)
	if #panes == 0 then
		return ui.col({ head, spacer(), ui.row({ toggle }), spacer(), ui.text({ ui.span("No live panes found (run `tern` with a window).", "muted") }) })
	end
	local children: { Node } = { head, spacer(), ui.row({ toggle }), spacer() }
	for _, p in panes do
		local label = (p.title or "(untitled)") .. "  " .. (p.program or "")
		local tone = if p.focused then "accent" else if p.agent then "success" else "muted"
		table.insert(children, badge(label, "send-pick:" .. tostring(p.id), tone))
	end
	return ui.col(children)
end

-- ---------- dock & view ----------

local function tab_button(label: string, act: string, active: boolean): Node
	return badge(label, act, if active then "accent" else "muted")
end

local function dock_view(state: State): Node
	local status: { Span | string } = {}
	if state.fetched then
		table.insert(status, ui.span("updated " .. clock(state.fetched :: number), "strong"))
	end
	if state.loading then
		table.insert(status, ui.span("  refreshing…", "muted"))
	end
	if state.problem then
		table.insert(status, ui.span("  last fetch failed", "warning"))
	end
	if state.cfg_error then
		table.insert(status, ui.span("  " .. state.cfg_error, "warning"))
	end
	local lines: { Node } = {}
	if #status > 0 then
		table.insert(lines, ui.text(status))
	end
	table.insert(lines, ui.text({ ui.span("r refresh   1 inbox   2 stack   Esc cancel", "dim") }))
	return ui.col({ ui.lines(lines), ui.row({ badge("Refresh", "refresh", "accent") }) })
end

local function inbox_view(state: State, now: number): Node
	if state.signin then
		return render_signin(state)
	end
	local parts: { Node } = {}
	if state.problem and #state.sections == 0 then
		local children: { Node } = { ui.md(state.problem.text .. " Press **r** to retry.") }
		if state.problem.detail and state.problem.detail ~= "" then
			table.insert(children, ui.code(state.problem.detail, nil, nil))
		end
		table.insert(parts, ui.card({ ui.span("Could not fetch the inbox", "strong") }, children))
		return ui.col(parts)
	end
	table.insert(parts, render_inbox(state, now))
	return ui.col(parts)
end

local function stack_view(state: State): Node
	local parts: { Node } = {}
	local r = state.repo
	if not r then
		if state.repo_loading then
			return ui.progress(nil, "Detecting repo…")
		end
		return ui.text({ ui.span("Open this block from a pane inside a git repository to see its Graphite stack.", "muted") })
	end
	table.insert(parts, ui.text({ ui.span(r.nwo, "strong"), ui.span("  ", "muted"), ui.span(r.path, "muted") }))
	if state.stack_problem then
		table.insert(parts, ui.text({ ui.span(state.stack_problem.text, "warning") }))
	end
	table.insert(parts, render_stack_tree(state))
	table.insert(parts, spacer())
	table.insert(parts, ui.rule({}))
	table.insert(parts, spacer())
	table.insert(parts, stack_actions(state))
	return ui.col(parts)
end

local function main_view(state: State): Node
	local now = os.time()
	if state.confirm then return render_confirm(state) end
	if state.send then return render_send_picker(state) end
	local body: Node
	if state.tab == "stack" then body = stack_view(state) else body = inbox_view(state, now) end
	local tabs = ui.row({
		tab_button("Inbox", "tab:inbox", state.tab == "inbox"),
		tab_button("Stack", "tab:stack", state.tab == "stack"),
	})
	return ui.col({ tabs, spacer(), ui.rule({}), spacer(), body })
end
-- ---------- actions ----------

local function do_open(cx: BlockCx, url: string)
	cx:open(url)
end

local function open_pane(state: State, cwd: string, command: string)
	run({ common.bin("tern"), "split", "@focused", "--cwd", cwd, "--keep-open", "--", command }, nil, common.TERN_TIMEOUT_MS, function(status, _out, stderr, _to)
		if status ~= 0 then
			state.cx:toast("error", "Could not open pane", first_lines(stderr, 3))
		end
	end)
end

local function do_checkout(state: State, pr: common.PR)
	local r = state.repo
	if not r or pr.repo ~= r.nwo then
		state.cx:toast("error", "Checkout only for the focused repo", "Open " .. pr.repo .. " in a pane to work there.")
		return
	end
	if pr.branch == "" then
		state.cx:toast("error", "No branch for this PR", "Graphite returned no head branch.")
		return
	end
	-- Resolve the worktree path. A non-empty `worktree_path` template wins
	-- (vars: {repo_root}, {repo}, {branch}, {number}); otherwise fall back
	-- to the legacy `{repo_root}/{worktree_dir}/{branch}` layout.
	local wt: string
	if state.cfg.worktree_path and state.cfg.worktree_path ~= "" then
		wt = config.render(state.cfg.worktree_path, {
			repo_root = r.path,
			repo = r.name,
			branch = pr.branch,
			number = tostring(pr.number),
		})
	else
		wt = r.path .. "/" .. state.cfg.worktree_dir .. "/" .. pr.branch
	end
	local function open_wt() open_pane(state, wt, "") end
	local function add_worktree()
		run({ "git", "-C", r.path, "worktree", "add", "-f", wt, pr.branch }, nil, 15000, function(status, _out, stderr, _to)
			if status == 0 then open_wt() return end
			run({ "git", "-C", r.path, "fetch", "origin", pr.branch }, nil, 15000, function(s2, _o2, e2, _t2)
				if s2 ~= 0 then state.cx:toast("error", "git fetch failed", first_lines(e2, 3)) return end
				run({ "git", "-C", r.path, "worktree", "add", "-f", wt, pr.branch }, nil, 15000, function(s3, _o3, e3, _t3)
					if s3 == 0 then open_wt() else state.cx:toast("error", "git worktree add failed", first_lines(e3, 3)) end
				end)
			end)
		end)
	end
	if tern.fs.exists(wt) then open_wt() else add_worktree() end
end

local function list_panes(state: State)
	state.send_loading = true
	state.send_panes = nil
	state.cx:render()
	run({ common.bin("tern"), "ls", "--json" }, nil, common.TERN_TIMEOUT_MS, function(status, stdout, stderr, _to)
		if not alive(state) then return end
		state.send_loading = false
		if status ~= 0 then
			state.cx:toast("error", "tern ls failed", first_lines(stderr, 3))
			state.cx:render() return
		end
		local ok, data = pcall(tern.json.decode, stdout)
		if not ok or type(data) ~= "table" then
			state.cx:toast("error", "tern ls: non-JSON")
			state.cx:render() return
		end
		local patterns = state.cfg.agent_patterns
		local function is_agent(title: string, program: string): boolean
			local tl = string.lower(title)
			local pl = string.lower(program)
			for _, pat in patterns do
				local lp = string.lower(pat)
				if string.find(tl, lp, 1, true) ~= nil or string.find(pl, lp, 1, true) ~= nil then
					return true
				end
			end
			return false
		end
		local panes: { AgentPane } = {}
		local sessions = data.sessions or {}
		for _, sess in sessions do
			local tabs = sess.tabs or {}
			for _, tab in tabs do
				local blocks = tab.blocks or {}
				for _, b in blocks do
					if type(b) == "table" and b.id ~= nil then
						local prog = b.program or ""
						local title = b.title or ""
						table.insert(panes, {
							id = b.id, title = title, program = prog,
							focused = b.focused == true, agent = is_agent(title, prog),
						})
					end
				end
			end
		end
		table.sort(panes, function(a, b)
			local aw = (a.focused and 2 or 0) + (a.agent and 1 or 0)
			local bw = (b.focused and 2 or 0) + (b.agent and 1 or 0)
			return aw > bw
		end)
		state.send_panes = panes
		state.cx:render()
	end)
end

local function send_to_pane(state: State, pane_id: number, text: string, submit: boolean)
	run({ common.bin("tern"), "send", tostring(pane_id), "paste", text }, nil, common.TERN_TIMEOUT_MS, function(status, _out, stderr, _to)
		if not alive(state) then return end
		if status ~= 0 then
			state.cx:toast("error", "tern send failed", first_lines(stderr, 3))
			return
		end
		if not submit then
			state.cx:toast("success", "Sent to agent", "Pasted into pane " .. tostring(pane_id) .. " (Enter not pressed).")
			return
		end
		-- Press Enter in the target pane to submit the prompt.
		run({ common.bin("tern"), "send", tostring(pane_id), "keys", "enter" }, nil, common.TERN_TIMEOUT_MS, function(s2, _o2, e2, _t2)
			if not alive(state) then return end
			if s2 == 0 then
				state.cx:toast("success", "Sent to agent", "Pasted + submitted into pane " .. tostring(pane_id) .. ".")
			else
				state.cx:toast("warning", "Pasted but Enter failed", first_lines(e2, 3))
			end
		end)
	end)
end

local function pr_vars(pr: common.PR): { [string]: string }
	return {
		number = tostring(pr.number),
		title = pr.title,
		url = pr.url,
		author = pr.author,
		branch = pr.branch,
		repo = pr.repo,
		comments = tostring(pr.comments or 0),
	}
end

-- Build the prompt for one PR or a stack, from the user's config templates.
prompt_for = function(prs: { common.PR }, mine: boolean, cfg: config.Config): string
	local p = cfg.prompts
	if #prs == 1 then
		local pr = prs[1]
		return config.render(if mine then p.address else p.review, pr_vars(pr))
	end
	-- Stack: render stack_line per PR bottom-up, join with "\n".
	local ordered = { table.unpack(prs) }
	table.sort(ordered, function(a, b) return (a.stackDepth or 0) < (b.stackDepth or 0) end)
	local lines: { string } = {}
	for _, pr in ordered do
		table.insert(lines, config.render(p.stack_line, pr_vars(pr)))
	end
	local joined = table.concat(lines, "\n")
	return config.render(if mine then p.address_stack else p.review_stack, { prs = joined })
end

local function gt_pane(state: State, args: { string }, confirm: boolean, label: string)
	if not state.repo then
		state.cx:toast("error", "No focused repo")
		return
	end
	if confirm then
		state.confirm = { act = "gt-run", label = label, payload = table.concat(args, "\t") }
		state.cx:render()
		return
	end
	local cmd = "gt " .. table.concat(args, " ")
	open_pane(state, state.repo.path, cmd)
end
-- ---------- event dispatch ----------

local function handle_action(state: State, act: string, cx: BlockCx, ev: UiEvent)
	_ = ev
	if act == "tab:inbox" then
		state.tab = "inbox" state.confirm = nil state.send = nil cx:render() return
	end
	if act == "tab:stack" then
		state.tab = "stack" state.confirm = nil state.send = nil cx:render() return
	end
	if act == "refresh" then
		refresh(state) return
	end
	if act == "signin:open" then
		local app = (state.auth and state.auth.app) or "https://app.graphite.com"
		cx:open(app .. "/activate") return
	end
	if act == "signin:terminal" then
		open_pane(state, tern.getenv("HOME") or "/", "") return
	end
	-- Confirm dialog.
	if act == "confirm-yes" then
		local c = state.confirm
		if c and c.act == "gt-run" then
			local args: { string } = {}
			for a in string.gmatch(c.payload, "[^\t]+") do table.insert(args, a) end
			local cmd = "gt " .. table.concat(args, " ")
			open_pane(state, state.repo and state.repo.path or "", cmd)
		end
		state.confirm = nil cx:render() return
	end
	if act == "confirm-no" then
		state.confirm = nil cx:render() return
	end
	-- Send picker.
	if act == "send-cancel" then
		state.send = nil state.send_panes = nil cx:render() return
	end
	if act == "send-toggle-submit" then
		local o = state.send
		if o then o.submit = not o.submit cx:render() end
		return
	end
	if string.sub(act, 1, 10) == "send-pick:" then
		local id = tonumber(string.sub(act, 11)) or 0
		local o = state.send
		if o and id ~= 0 then
			send_to_pane(state, id, prompt_for(o.prs, o.mine, state.cfg), o.submit)
		end
		state.send = nil state.send_panes = nil cx:render() return
	end
	-- Send a whole stack to agent: "send-stack:<mine|rev>:repo/n,repo/n,...".
	if string.sub(act, 1, 11) == "send-stack:" then
		local rest = string.sub(act, 12)
		local mine_str, list_str = string.match(rest, "^([^:]+):(.+)$")
		if not list_str then return end
		local mine = mine_str == "mine"
		local prs: { common.PR } = {}
		for p in string.gmatch(list_str, "[^,]+") do
			local repo, n = string.match(p, "^([^/]+/[^/]+)/(%d+)$")
			if repo and n then
				local pr = find_pr(state, repo, tonumber(n) or 0)
				if pr then table.insert(prs, pr) end
			end
		end
		if #prs == 0 then return end
		table.sort(prs, function(a, b) return (a.stackDepth or 0) < (b.stackDepth or 0) end)
		state.send = { prs = prs, mine = mine, submit = state.cfg.send_submit_default }
		list_panes(state)
		cx:render() return
	end
	-- Open / send / checkout: parse "kind:repo/number".
	local kind, rest = string.match(act, "^([^:]+):(.+)$")
	if not kind then return end
	local repo, n = string.match(rest or "", "^([^/]+/[^/]+)/(%d+)$")
	if repo == "" or n == nil then return end
	local num = tonumber(n) or 0
	if num == 0 then return end
	local pr = find_pr(state, repo, num)
	if not pr then
		cx:toast("error", "PR not in inbox", repo .. "#" .. tostring(num))
		return
	end
	if kind == "checkout" then
		do_checkout(state, pr) return
	end
	if kind == "send" or kind == "send-mine" then
		state.send = { prs = { pr }, mine = (kind == "send-mine"), submit = state.cfg.send_submit_default }
		list_panes(state)
		cx:render() return
	end
	-- gt actions (stack tab).
	if string.sub(kind, 1, 3) == "gt:" then
		local sub = string.sub(kind, 4)
		if sub == "checkout" then gt_pane(state, { "checkout" }, false, "checkout")
		elseif sub == "up" then gt_pane(state, { "up" }, false, "up")
		elseif sub == "down" then gt_pane(state, { "down" }, false, "down")
		elseif sub == "create" then gt_pane(state, { "create" }, false, "create")
		elseif sub == "modify" then gt_pane(state, { "modify" }, false, "modify")
		elseif sub == "submit" then gt_pane(state, { "submit", "--draft" }, false, "submit --draft")
		elseif sub == "sync" then gt_pane(state, { "sync" }, false, "sync")
		elseif sub == "restack" then gt_pane(state, { "stack", "restack" }, false, "restack")
		elseif sub == "move" then gt_pane(state, { "move" }, false, "move")
		elseif sub == "fold" then gt_pane(state, { "fold" }, false, "fold")
		elseif sub == "delete" then gt_pane(state, { "delete" }, true, "delete") end
		return
	end
end

-- Open actions carry the URL kind in the act itself.
local function handle_open(state: State, act: string, cx: BlockCx)
	local kind, rest = string.match(act, "^([^:]+):(.+)$")
	if not kind then return end
	-- "open:graphite:repo/n"
	if kind ~= "open" then return end
	-- second token: "graphite:repo/n"
	local sub, rest2 = string.match(rest or "", "^([^:]+):(.+)$")
	if sub ~= "graphite" then return end
	local repo, n = string.match(rest2 or "", "^([^/]+/[^/]+)/(%d+)$")
	if not repo then return end
	local pr = find_pr(state, repo, tonumber(n) or 0)
	if not pr then return end
	do_open(cx, pr.url)
end

-- ---------- block ----------

tern.block.define("inbox", {
	init = function(cx: BlockCx, _args: { string }, _saved: any): State
		tern.log.info("graphite host: init pane", cx.pane, "cwd", cx.cwd)
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local cfg, cfg_error = config.load()
		local state: State = {
			cx = cx,
			tab = "inbox",
			repo = nil,
			repo_loading = false,
			sections = {},
			stacks = {},
			fetched = nil,
			loading = false,
			problem = nil,
			rate_limited_until = nil,
			timer = nil,
			confirm = nil,
			send = nil,
			send_panes = nil,
			send_loading = false,
			stack_problem = nil,
			fixture = _args and _args[1] == "fixture",
			me = nil,
			auth = nil,
			signin = nil,
			cfg = cfg,
			cfg_error = cfg_error,
			fixture_signedout = _args and _args[2] == "signedout",
			prev_section_keys = {},
			section_baseline = false,
		}
		running[cx.pane] = state
		common.resolve_bins(state.cfg, function()
			if not alive(state) then return end
			if state.fixture then
				if _args and _args[2] == "stack" then
					state.tab = "stack"
				end
				state.repo = { path = tern.plugin.dir, owner = "acme", name = "widgets", nwo = "acme/widgets" }
				fetch_inbox(state)
				fetch_stack(state)
			else
				detect_repo(state)
			end
		end)
		return state
	end,

	title = function(_state: State): string?
		return "graphite"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		return { main = ui.col({ main_view(state) }), dock = dock_view(state) }
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if k == "r" then
			refresh(state)
			return true
		elseif k == "1" then
			state.tab = "inbox" state.confirm = nil state.send = nil
			return true
		elseif k == "2" then
			state.tab = "stack" state.confirm = nil state.send = nil
			return true
		elseif k == "escape" then
			state.confirm = nil state.send = nil state.send_panes = nil
			return true
		end
		return false
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if ev.ev ~= "action" then
			return
		end
		local act = ev.act or ""
		if string.sub(act, 1, 5) == "open:" then
			handle_open(state, act, cx)
			return
		end
		handle_action(state, act, cx, ev)
	end,
})

return nil

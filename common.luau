--!strict
-- Shared by both halves: time helpers, the gt log short parser, the PR
-- record shape, and an async binary resolver. The block talks to the
-- Graphite CLI API (graphite.luau); there is no `gh` and no browser cookie
-- here.

local M = {}

-- Process timeouts.
M.GT_TIMEOUT_MS = 15 * 1000
M.TERN_TIMEOUT_MS = 10 * 1000

-- A normalized PR. `stackId`/`stackDepth` come from Graphite's
-- `dependentPrNumber` chain (filled in by host.luau).
export type PR = {
	key: string, -- "owner/name#n"
	repo: string, -- "owner/name"
	owner: string,
	name: string,
	number: number,
	title: string,
	author: string, -- login, "" when missing
	mine: boolean,
	state: string, -- "OPEN" | "CLOSED" | "MERGED"
	isDraft: boolean,
	branch: string, -- headRefName
	base: string, -- baseRefName
	url: string, -- Graphite PR page
	createdAt: number, -- epoch seconds
	updatedAt: number,
	reviewDecision: string?, -- "APPROVED"|"REVIEW_REQUIRED"|"CHANGES_REQUESTED"|nil
	merge: string?, -- mergeabilityStatus value
	comments: number?, -- unresolved review-thread count (via gh), when fetched
	stackId: string?,
	stackDepth: number?,
}

-- Parse an ISO 8601 "Z" timestamp to epoch seconds.
function M.epoch(iso: string): number
	local y, mo, d, h, mi, s = string.match(iso, "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return 0
	end
	-- days-from-civil, then seconds; UTC, so no zone offset.
	local function dfc(year: number, month: number, day: number): number
		if month <= 2 then
			year -= 1
		end
		local era = year // 400
		local yoe = year - era * 400
		local doy = (153 * (if month > 2 then month - 3 else month + 9) + 2) // 5 + day - 1
		local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
		return era * 146097 + doe - 719468
	end
	return dfc(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number) * 86400
		+ tonumber(h) :: number * 3600 + tonumber(mi) :: number * 60 + tonumber(s) :: number
end

-- Expand a leading `~` / `~/` to `home`. git and the pane launcher receive the
-- path verbatim (no shell), so an unexpanded `~` would create a directory
-- literally named `~`. Other paths, and `~` with no home set, are unchanged.
function M.expand_home(path: string, home: string?): string
	if home == nil or home == "" then
		return path
	end
	if path == "~" then
		return home
	end
	if string.sub(path, 1, 2) == "~/" then
		return (string.gsub(home, "/+$", "")) .. string.sub(path, 2)
	end
	return path
end

-- Relative age: "3h", "2d", "5w", "3mo".
function M.age(t: number, now: number): string
	local s = math.max(0, now - t)
	local m = s // 60
	if m < 60 then
		return tostring(m) .. "m"
	elseif m < 1440 then
		return tostring(m // 60) .. "h"
	elseif m < 10080 then
		return tostring(m // 1440) .. "d"
	elseif m < 43200 then
		return tostring(m // 10080) .. "w"
	end
	return tostring(m // 43200) .. "mo"
end

-- Build a Graphite PR URL from the app host. Fallback when pull-request-info
-- gives no `url`.
function M.graphite_url(app: string, owner: string, repo: string, n: number): string
	return app .. "/github/pr/" .. owner .. "/" .. repo .. "/" .. tostring(n)
end

-- ---------- binary resolver ----------

-- Resolved absolute paths, filled once per VM by resolve_bins.
local BINS: { [string]: string }? = nil
M.BINS = nil

-- Resolve `gt`, `tern` and `gh` once. Uses cfg.gt_path / cfg.tern_path /
-- cfg.gh_path when set, otherwise `command -v <tool>` via a login shell,
-- otherwise the bare name. Idempotent: a no-op after the first call completes.
function M.resolve_bins(cfg: any, done: () -> ())
	if BINS ~= nil then
		done()
		return
	end
	local bins: { [string]: string } = {}
	local pending = 3
	local function finish_one()
		pending -= 1
		if pending == 0 then
			BINS = bins
			M.BINS = bins
			done()
		end
	end
	local function resolve(tool: string, cfg_path: string, fallback: string)
		if type(cfg_path) == "string" and cfg_path ~= "" then
			bins[tool] = cfg_path
			finish_one()
			return
		end
		local shell = tern.getenv("SHELL") or "/bin/sh"
		tern.process.run({ shell, "-lc", "command -v " .. tool }, { timeout_ms = 5000 }, function(result: ProcessResult, _cx)
			if result.status == 0 then
				-- Take the last stdout line starting with "/".
				local last: string? = nil
				for line in string.gmatch(result.stdout, "[^\r\n]+") do
					if string.sub(line, 1, 1) == "/" then
						last = line
					end
				end
				if last and last ~= "" then
					bins[tool] = last
					finish_one()
					return
				end
			end
			bins[tool] = fallback
			finish_one()
		end)
	end
	resolve("gt", cfg.gt_path, "gt")
	resolve("tern", cfg.tern_path, "tern")
	resolve("gh", cfg.gh_path, "gh")
end

-- Absolute path to a tool, or the bare name as a fallback. Must be called
-- after resolve_bins has completed.
function M.bin(tool: string): string
	if BINS then
		return (BINS :: { [string]: string })[tool] or tool
	end
	return tool
end

-- ---------- gt log short parser ----------

-- A parsed gt log short branch.
export type GtBranch = {
	branch: string,
	depth: number, -- 0 = top-level (own stack), 1+ = nested
	pr: number?, -- from a (pr-NNNN)-style worktree annotation, when gt prints one
	state: string, -- "frozen"|"needs restack"|""
	stackId: string, -- shared across one connected stack
}

-- Parse `gt log short --no-interactive` output into ordered branches with
-- stack grouping. Branches joined by `│` form one stack; top-level `◯` lines
-- with no children are each their own stack. The checked-out branch is drawn
-- with `◉` instead of `◯`; the trunk line (`◯─┴─┘  <trunk>`) is skipped
-- whatever the trunk is called. State words and the PR number are read from
-- the `(...)` annotations only, never from the branch name.
function M.parse_gt_log(text: string): { GtBranch }
	local out: { GtBranch } = {}
	local stackCounter = 0
	local currentStack = ""
	for line in string.gmatch(text, "[^\r\n]+") do
		-- Count leading `│` as depth.
		local prefix, rest = string.match(line, "^([│ ]*)◯%s*(.*)$")
		if not prefix then
			prefix, rest = string.match(line, "^([│ ]*)◉%s*(.*)$")
		end
		-- Skip the trunk line "◯─┴─...─┘  main": connectors follow the node.
		if prefix and rest and not (string.find(rest, "^─") or string.find(rest, "^┴") or string.find(rest, "^┘")) then
			local depth = 0
			for _ in string.gmatch(prefix, "│") do
				depth += 1
			end
			-- Branch is the first token, before any " (...)" annotation.
			local branch = string.match(rest, "^%S+")
			if branch then
				local annotations = string.sub(rest, #branch + 1)
				-- PR annotation: gt prints the branch's worktree name, e.g.
				-- (pr-123), (sb-pr123) or (action-pr-123). The word must be
				-- exactly `pr` so names like (expr-5) don't match.
				local prNum: number? = nil
				for ann in string.gmatch(annotations, "%(([^)]*)%)") do
					local n = string.match(ann, "%f[%a]pr%-?(%d+)$")
					if n then
						prNum = tonumber(n)
					end
				end
				local state = ""
				if string.find(annotations, "frozen", 1, true) then
					state = "frozen"
				elseif string.find(annotations, "needs restack", 1, true) then
					state = "needs restack"
				end
				-- Stack assignment: depth 1 starts a new stack; deeper lines join it.
				-- depth 0 with no following children is its own stack.
				if depth >= 1 then
					if depth == 1 or currentStack == "" then
						stackCounter += 1
						currentStack = "stack" .. tostring(stackCounter)
					end
				else
					stackCounter += 1
					currentStack = "stack" .. tostring(stackCounter)
				end
				table.insert(out, {
					branch = branch,
					depth = depth,
					pr = prNum,
					state = state,
					stackId = currentStack,
				})
			end
		end
	end
	-- Second pass: top-level (depth 0) branches that are immediately followed
	-- by a depth>=1 child should share that child's stack.
	for i = #out, 1, -1 do
		if out[i].depth == 0 and i < #out and out[i + 1].depth >= 1 then
			out[i].stackId = out[i + 1].stackId
		end
	end
	return out
end

return M

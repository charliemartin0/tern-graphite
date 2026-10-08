--!strict
-- The window half: an "Open graphite" palette command and a status line
-- segment with the count of PRs in the user's Graphite inbox. The segment
-- reads only the summary the host half saved in tern.kv; this half never
-- runs any network calls.

local KIND = "graphite.inbox"
local ACTION = "plugin.graphite.open"
local WATCH_MS = 30 * 1000

local function open_panel(cx: WindowCx)
	for _, pane in cx.session:panes() do
		if pane.block == KIND then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(KIND, nil, "beside") == nil then
		cx:toast("error", "graphite is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Open graphite",
	icon = "git-pull",
	run = open_panel,
})

-- Dev: open the inbox against the bundled fixture JSON (no network calls).
local function open_fixture_panel(cx: WindowCx)
	for _, pane in cx.session:panes() do
		if pane.block == KIND then
			cx.layout:focus(pane.pane)
			return
		end
	end
	cx:new_block(KIND, { "fixture" }, "beside")
end

tern.command({
	id = "open_fixture",
	title = "Open graphite (fixture)",
	icon = "git-pull",
	run = open_fixture_panel,
})

-- Dev: open the fixture block in a new tab for offscreen-ish screenshots.
local function open_shot(cx: WindowCx)
	cx:new_block(KIND, { "fixture" }, "tab")
end

tern.command({
	id = "open_shot",
	title = "Open graphite (fixture, new tab)",
	icon = "git-pull",
	run = open_shot,
})

-- Diff button: the host half opens `tern-graphite://diff/<base64url json>`
-- through `cx:open`, which lands here. Opens pr-tour's block in a new tab.
local DIFF_PREFIX = "tern-graphite://diff/"

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #DIFF_PREFIX) ~= DIFF_PREFIX then
		return nil
	end
	local ok, d = pcall(function(): any
		return tern.json.decode(tern.base64.decode(string.sub(link.url, #DIFF_PREFIX + 1)))
	end)
	if not ok or type(d) ~= "table" or type(d.repo) ~= "string" or type(d.number) ~= "string" then
		cx:toast("error", "Bad diff link", "graphite could not decode the diff request.")
		return { handled = true }
	end
	local how: How = "tab"
	if d.how == "beside" or d.how == "below" then
		how = d.how
	end
	local pane = cx:new_block("pr-tour.tour", { d.repo, d.number, d.sha or "", d.title or "" }, how)
	if pane == nil then
		cx:toast("error", "pr-tour plugin isn't installed", "Link it: tern plugin link ~/Dev/tern-plugins/pr-tour")
	end
	return { handled = true }
end)

-- The host half hides the Diff button unless pr-tour is installed, and can't
-- see other plugins itself: publish whether this window's host has its block.
local function publish_pr_tour(cx: WindowCx)
	local found = false
	local ok, types = pcall(function() return cx.session:block_types() end)
	if ok and types then
		for _, t in types do
			if t.kind == "pr-tour.tour" then
				found = true
				break
			end
		end
	end
	local okg, prev = pcall(tern.kv.get, "pr_tour")
	if not okg or prev ~= found then
		pcall(tern.kv.set, "pr_tour", found)
	end
end

local function summary(): { [string]: any }?
	local ok, s = pcall(tern.kv.get, "summary")
	if ok and type(s) == "table" and type(s.at) == "number" then
		return s
	end
	return nil
end

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local s = summary()
	if not s then
		return nil
	end
	local n = tonumber(s.count) or 0
	local text = "graphite " .. n
	local tone = if n > 0 then "warning" else "muted"
	return { { text = text, icon = "git-pull", tone = tone, command = ACTION } }
end)

local watch: TimerHandle? = nil
local seen = ""

local function stamp(): string
	local s = summary()
	return if s then tostring(s.at) .. ":" .. tostring(s.count) else "none"
end

local function arm()
	if watch ~= nil then
		return
	end
	watch = tern.timer(WATCH_MS, function(cx)
		watch = nil
		publish_pr_tour(cx)
		local now = stamp()
		if now ~= seen then
			seen = now
			tern.chrome.refresh()
		end
		arm()
	end)
end

tern.on("window_start", function(cx: WindowCx)
	publish_pr_tour(cx)
	seen = stamp()
	arm()
	-- Dev convenience: offscreen `tern shot` can't open the palette, so an
	-- env var auto-opens the block. No effect in normal interactive use.
	local auto = tern.getenv("GRAPHITE_AUTOOPEN")
	if auto == "fixture" then
		local pane = cx:new_block(KIND, { "fixture" }, "beside")
		if pane == nil then
			tern.log.warn("graphite: new_block fixture returned nil (host half / block not available on this window's host?)")
		else
			tern.log.info("graphite: opened fixture block pane", pane)
		end
	elseif auto == "fixture-stack" then
		local pane = cx:new_block(KIND, { "fixture", "stack" }, "beside")
		if pane == nil then
			tern.log.warn("graphite: new_block fixture-stack returned nil")
		end
	elseif auto == "fixture-signedout" then
		local pane = cx:new_block(KIND, { "fixture", "signedout" }, "beside")
		if pane == nil then
			tern.log.warn("graphite: new_block fixture-signedout returned nil")
		end
	elseif auto == "live" then
		local pane = cx:new_block(KIND, nil, "beside")
		if pane == nil then
			tern.log.warn("graphite: new_block live returned nil")
		end
	end
end)

arm()

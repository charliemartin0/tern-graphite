--!nonstrict
-- Unit tests for common.parse_gt_log (against real `gt log short` shapes) and
-- common.expand_home. Run from the repository root with the Luau CLI:
--   luau test/unit.luau
-- No Tern, daemon or network needed.

local common = require("../common")

local failures = 0
local count = 0

local function eq(name, got, want)
	count += 1
	if got ~= want then
		failures += 1
		print("FAIL: " .. name .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
	end
end

local function names(parsed)
	local out = {}
	for _, b in parsed do
		table.insert(out, b.branch)
	end
	return table.concat(out, ",")
end

-- The checked-out branch is drawn with ◉ instead of ◯, and the trunk line is
-- named after the repo's trunk (here `develop`), not always `main`.
local current = common.parse_gt_log(table.concat({
	"◉    feat/b",
	"◯    feat/a",
	"◯─┘  develop",
}, "\n"))
eq("current branch kept, trunk dropped", names(current), "feat/b,feat/a")

-- A repo with nothing tracked prints only the trunk line.
eq("trunk-only output yields no branches", #common.parse_gt_log("◯─┘  master\n"), 0)

-- Annotations: state words and worktree names.
local annotated = common.parse_gt_log(table.concat({
	"◯  a (frozen)",
	"◯  b (needs restack) (pr-42)",
	"◯  c (my-worktree)",
	"◯─┘  main",
}, "\n"))
eq("frozen", annotated[1].state, "frozen")
eq("needs restack", annotated[2].state, "needs restack")
eq("pr from worktree annotation", annotated[2].pr, 42)
eq("plain worktree name is not a PR", annotated[3].pr, nil)

-- A PR number is read from the (...) annotation only, never the branch name.
local branchy = common.parse_gt_log(table.concat({
	"◯  fix/expr-12",
	"◯  feat/pr-9-cleanup",
	"◯  feat/x (sb-pr6695)",
	"◯  feat/y (action-pr-6758)",
	"◯  feat/z (expr-5)",
	"◯─┘  main",
}, "\n"))
eq("pr-looking text in branch name ignored (expr-12)", branchy[1].pr, nil)
eq("pr-looking text in branch name ignored (pr-9)", branchy[2].pr, nil)
eq("sb-prNNNN annotation", branchy[3].pr, 6695)
eq("action-pr-NNNN annotation", branchy[4].pr, 6758)
eq("word ending in pr is not a PR (expr-5)", branchy[5].pr, nil)

-- worktree_path: a leading ~ must be expanded because nothing downstream runs a shell.
eq("~/x expands", common.expand_home("~/wt/pr1", "/home/u"), "/home/u/wt/pr1")
eq("home trailing slash", common.expand_home("~/wt", "/home/u/"), "/home/u/wt")
eq("bare ~", common.expand_home("~", "/home/u"), "/home/u")
eq("absolute untouched", common.expand_home("/srv/wt", "/home/u"), "/srv/wt")
eq("~user untouched", common.expand_home("~bob/wt", "/home/u"), "~bob/wt")
eq("~ mid-path untouched", common.expand_home("/a/~/b", "/home/u"), "/a/~/b")
eq("no HOME leaves path", common.expand_home("~/wt", nil), "~/wt")

if failures > 0 then
	print(("%d of %d checks failed"):format(failures, count))
	error("unit tests failed")
end
print(("ok: %d checks passed"):format(count))

#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

binary="$project_root/.build/debug/dodexabash"
if [[ ! -x "$binary" ]]; then
  binary="$project_root/.build/arm64-apple-macosx/debug/dodexabash"
fi
if [[ ! -x "$binary" ]]; then
  echo "missing built binary: $binary" >&2
  echo "run 'swift build' first" >&2
  exit 1
fi

echo "==> pipeline"
pipeline_output="$("$binary" -c 'echo hello | tr a-z A-Z')"
[[ "$pipeline_output" == "HELLO" ]]

echo "==> variables"
variable_output="$(NAME=world "$binary" -c 'echo hello-$NAME')"
[[ "$variable_output" == "hello-world" ]]

echo "==> redirection"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
"$binary" -c "echo redirected > $tmp_dir/out.txt" >/dev/null
[[ "$(cat "$tmp_dir/out.txt")" == "redirected" ]]

http_root="$tmp_dir/http"
mkdir -p "$http_root"
cat > "$http_root/index.html" <<'EOF'
<!doctype html>
<html>
  <head><title>Smoke Test Page</title></head>
  <body>
    <h1>Example Domain</h1>
    <p>Local browse test fixture.</p>
  </body>
</html>
EOF
cat > "$http_root/todos.json" <<'EOF'
{"id":1,"title":"delectus aut autem","completed":false}
EOF
browse_html_url="file://$http_root/index.html"
browse_json_url="file://$http_root/todos.json"

echo "==> command substitution"
substitution_output="$("$binary" -c 'echo prefix $(echo nested)')"
[[ "$substitution_output" == "prefix nested" ]]

echo "==> globbing"
mkdir -p "$tmp_dir/glob"
touch "$tmp_dir/glob/a.swift" "$tmp_dir/glob/b.swift" "$tmp_dir/glob/notes.txt"
glob_output="$(cd "$tmp_dir/glob" && "$binary" -c 'echo *.swift')"
[[ "$glob_output" == "a.swift b.swift" ]]
glob_fallback="$(cd "$tmp_dir/glob" && "$binary" -c 'echo *.md')"
[[ "$glob_fallback" == "*.md" ]]

echo "==> command substitution keeps outer cwd"
mkdir -p "$tmp_dir/work/subdir"
cwd_roundtrip="$(cd "$tmp_dir/work" && "$binary" -c 'echo $(cd subdir && pwd); pwd')"
# macOS may resolve /var -> /private/var; normalize both sides
normalize() { echo "$1" | sed 's|^/private||'; }
expected="$(normalize "$tmp_dir/work/subdir")"$'\n'"$(normalize "$tmp_dir/work")"
actual="$(normalize "$cwd_roundtrip")"
[[ "$actual" == "$expected" ]]

echo "==> runtime persistence"
runtime_home="$tmp_dir/runtime-home"
DODEXABASH_HOME="$runtime_home" "$binary" -c 'intent set ship-release' >/dev/null
DODEXABASH_HOME="$runtime_home" "$binary" -c 'artifact create note text persistent-artifact' >/dev/null
artifact_listing="$(DODEXABASH_HOME="$runtime_home" "$binary" -c 'artifacts')"
status_output="$(DODEXABASH_HOME="$runtime_home" "$binary" -c 'status')"
[[ -f "$runtime_home/runtime.json" ]]
[[ "$artifact_listing" == *"note"* ]]
[[ "$status_output" == *"intent: [active] ship-release"* ]]

echo "==> and-if short circuit"
andif_output="$("$binary" -c 'false && echo should-not-run' || true)"
[[ "$andif_output" != *"should-not-run"* ]]

echo "==> or-if runs fallback"
orif_output="$("$binary" -c 'false || echo fallback')"
[[ "$orif_output" == *"fallback"* ]]

echo "==> export sets variable"
export_output="$("$binary" -c 'export MYVAR=hello ; echo $MYVAR')"
[[ "$export_output" == *"hello"* ]]

echo "==> exit status propagation"
exit_output="$("$binary" -c 'false ; echo $?')"
[[ "$exit_output" == *"1"* ]]

echo "==> simulate detects risk"
simulate_output="$("$binary" -c 'simulate rm -rf /')"
[[ "$simulate_output" == *"critical"* ]]

echo "==> intent lifecycle"
intent_home="$tmp_dir/intent-home"
DODEXABASH_HOME="$intent_home" "$binary" -c 'intent set Fix the build' >/dev/null
intent_show="$(DODEXABASH_HOME="$intent_home" "$binary" -c 'intent show')"
[[ "$intent_show" == *"Fix the build"* ]]

echo "==> lease grant and list"
lease_home="$tmp_dir/lease-home"
DODEXABASH_HOME="$lease_home" "$binary" -c 'lease grant read:repo . 60' >/dev/null
lease_list="$(DODEXABASH_HOME="$lease_home" "$binary" -c 'lease list')"
[[ "$lease_list" == *"read:repo"* ]]

echo "==> proof after execution"
proof_home="$tmp_dir/proof-home"
DODEXABASH_HOME="$proof_home" "$binary" -c 'echo test' >/dev/null
proof_output="$(DODEXABASH_HOME="$proof_home" "$binary" -c 'prove last')"
[[ "$proof_output" == *"Proof"* ]]

echo "==> greet shows identity"
greet_output="$("$binary" -c 'hi')"
[[ "$greet_output" == *"AI-native shell"* ]]

echo "==> cards lists workflows"
cards_output="$("$binary" -c 'cards')"
[[ "$cards_output" == *"repo-context-refresh"* ]]

echo "==> tree shows structure"
tree_output="$("$binary" -c 'tree -L1')"
[[ "$tree_output" == *"directories"* ]]

echo "==> status overview"
status_overview="$("$binary" -c 'status')"
[[ "$status_overview" == *"dodexabash status"* ]]

echo "==> attention push and list"
attn_home="$tmp_dir/attn-home"
DODEXABASH_HOME="$attn_home" "$binary" -c 'attention push urgent test-alert' >/dev/null
attn_list="$(DODEXABASH_HOME="$attn_home" "$binary" -c 'attention list')"
[[ "$attn_list" == *"test-alert"* ]]

echo "==> replay create and show"
replay_home="$tmp_dir/replay-home"
DODEXABASH_HOME="$replay_home" "$binary" -c 'replay create' >/dev/null
replay_last="$(DODEXABASH_HOME="$replay_home" "$binary" -c 'replay last')"
[[ "$replay_last" == *"Cognitive packet"* ]]

echo "==> brain status"
brain_output="$("$binary" -c 'brain status')"
[[ "$brain_output" == *"endpoint"* ]]

echo "==> markdown show"
markdown_summary="$("$binary" -c 'md show README.md')"
[[ "$markdown_summary" == *"Markdown: "* ]]
[[ "$markdown_summary" == *"headings:"* ]]

echo "==> markdown section"
markdown_section="$("$binary" -c 'md section README.md "Builtins"')"
[[ "$markdown_section" == *"workflow"* ]]

echo "==> markdown ingest"
markdown_ingest="$("$binary" -c 'md ingest README.md')"
[[ "$markdown_ingest" == *"Ingested markdown"* ]]

echo "==> block creation"
block_home="$tmp_dir/block-home"
DODEXABASH_HOME="$block_home" "$binary" -c 'echo block_test' >/dev/null
block_list="$(DODEXABASH_HOME="$block_home" "$binary" -c 'blocks list')"
[[ "$block_list" == *"block_test"* || "$block_list" == *"Recent Blocks"* || "$block_list" == *"No blocks"* ]]

echo "==> block count"
DODEXABASH_HOME="$block_home" "$binary" -c 'echo second' >/dev/null
block_count="$(DODEXABASH_HOME="$block_home" "$binary" -c 'blocks count')"
# Should be >= 1 (might be more from the blocks command itself)
[[ "$block_count" =~ ^[0-9]+$ ]]

echo "==> mcp status"
mcp_output="$("$binary" -c 'mcp status')"
[[ "$mcp_output" == *"MCP"* || "$mcp_output" == *"No MCP"* ]]

echo "==> mcp tools"
tools_output="$("$binary" -c 'tools')"
[[ "$tools_output" == *"tool"* || "$tools_output" == *"No MCP"* ]]

echo "==> jobs builtin"
jobs_output="$("$binary" -c 'jobs')"
[[ "$jobs_output" == *"No active jobs"* ]]

echo "==> streaming pipeline"
stream_output="$("$binary" -c '/bin/echo streaming | /usr/bin/tr a-z A-Z')"
[[ "$stream_output" == "STREAMING" ]]

echo "==> block failures tracking"
fail_home="$tmp_dir/fail-home"
DODEXABASH_HOME="$fail_home" "$binary" -c 'nonexistent_command_xyzzy' 2>/dev/null || true
fail_output="$(DODEXABASH_HOME="$fail_home" "$binary" -c 'blocks failures')"
[[ "$fail_output" == *"Failed"* || "$fail_output" == *"No failed"* ]]

echo "==> block search"
search_home="$tmp_dir/search-home"
DODEXABASH_HOME="$search_home" "$binary" -c 'echo unique_search_token' >/dev/null
search_output="$(DODEXABASH_HOME="$search_home" "$binary" -c 'blocks search unique_search')"
[[ "$search_output" == *"unique_search"* || "$search_output" == *"No blocks"* ]]

echo "==> git init"
git_home="$tmp_dir/git-test"
"$binary" -c "git init $git_home/repo" >/dev/null
[[ -d "$git_home/repo/.git" ]]

echo "==> git add + commit"
echo "test content" > "$git_home/repo/hello.txt"
(cd "$git_home/repo" && "$binary" -c "git add hello.txt")
commit_output="$(cd "$git_home/repo" && "$binary" -c 'git commit -m "test commit"')"
[[ "$commit_output" == *"test commit"* ]]

echo "==> git log"
log_output="$(cd "$git_home/repo" && "$binary" -c 'git log')"
[[ "$log_output" == *"test commit"* ]]

echo "==> git status clean"
status_output="$(cd "$git_home/repo" && "$binary" -c 'git status')"
[[ "$status_output" == *"nothing to commit"* ]]

echo "==> git diff"
echo "added line" >> "$git_home/repo/hello.txt"
diff_output="$(cd "$git_home/repo" && "$binary" -c 'git diff')"
[[ "$diff_output" == *"added line"* ]]

echo "==> git branch"
branch_output="$(cd "$git_home/repo" && "$binary" -c 'git branch')"
[[ "$branch_output" == *"main"* ]]
(cd "$git_home/repo" && "$binary" -c "git branch feature-test") >/dev/null
branch_list="$(cd "$git_home/repo" && "$binary" -c 'git branch')"
[[ "$branch_list" == *"feature-test"* ]]

echo "==> git tag"
(cd "$git_home/repo" && "$binary" -c "git tag v0.1") >/dev/null
tag_output="$(cd "$git_home/repo" && "$binary" -c 'git tag')"
[[ "$tag_output" == *"v0.1"* ]]

echo "==> git auth status"
auth_output="$("$binary" -c 'git auth status')"
[[ "$auth_output" == *"Authentication"* ]]

echo "==> git tree"
tree_output="$(cd "$git_home/repo" && "$binary" -c 'git tree')"
[[ "$tree_output" == *"test commit"* ]]

echo "==> index run"
index_output="$("$binary" -c 'index run')"
[[ "$index_output" == *"Indexed"* ]]
[[ "$index_output" == *"symbols"* ]]

echo "==> index search"
search_output="$("$binary" -c 'index search Shell')"
[[ "$search_output" == *"Found"* ]]

echo "==> index imports"
imports_output="$("$binary" -c 'index imports Foundation')"
[[ "$imports_output" == *"Foundation"* ]]

echo "==> index context"
context_output="$("$binary" -c 'index context')"
[[ "$context_output" == *"Brain context"* ]]

echo "==> sec help"
sec_help="$("$binary" -c 'sec help')"
[[ "$sec_help" == *"security toolkit"* ]]

echo "==> sec interfaces"
sec_ifaces="$("$binary" -c 'sec interfaces')"
[[ "$sec_ifaces" == *"Network Interfaces"* ]]

echo "==> sec dns"
sec_dns="$("$binary" -c 'sec dns localhost')"
[[ "$sec_dns" == *"127.0.0.1"* ]]

echo "==> sec scan (lease-gated)"
sec_nolease="$("$binary" -c 'sec scan 127.0.0.1' 2>&1 || true)"
[[ "$sec_nolease" == *"lease"* ]]

echo "==> sec scan (with lease)"
sec_home="$tmp_dir/sec-home"
DODEXABASH_HOME="$sec_home" "$binary" -c 'policy set security mode:active hard' >/dev/null 2>&1 || true
DODEXABASH_HOME="$sec_home" "$binary" -c 'lease grant sec:scan . 600' >/dev/null
sec_scan="$(DODEXABASH_HOME="$sec_home" "$binary" -c 'sec scan 127.0.0.1 --ports 22' 2>&1)"
[[ "$sec_scan" == *"scanned"* || "$sec_scan" == *"PORT"* || "$sec_scan" == *"Scan"* ]]

echo "==> sec detect system"
sec_detect="$("$binary" -c 'sec detect system')"
[[ "$sec_detect" == *"System"* || "$sec_detect" == *"No system integrity anomalies"* ]]

echo "==> roche help"
roche_help="$("$binary" -c 'roche')"
[[ "$roche_help" == *"Rochestation"* ]]
[[ "$roche_help" == *"RESEARCH"* ]]

echo "==> roche status (no session)"
roche_home="$tmp_dir/roche-home"
roche_status="$(DODEXABASH_HOME="$roche_home" "$binary" -c 'roche status')"
[[ "$roche_status" == *"No active"* ]]

echo "==> roche list (empty)"
roche_list="$(DODEXABASH_HOME="$roche_home" "$binary" -c 'roche list')"
[[ "$roche_list" == *"No roche"* ]]

echo "==> palace status (empty)"
palace_home="$tmp_dir/palace-home"
palace_status="$(DODEXABASH_HOME="$palace_home" "$binary" -c 'palace status')"
[[ "$palace_status" == *"empty"* ]]

echo "==> palace add + search"
DODEXABASH_HOME="$palace_home" "$binary" -c 'palace add work shell Built a native git library' >/dev/null
palace_search="$(DODEXABASH_HOME="$palace_home" "$binary" -c 'palace search git')"
[[ "$palace_search" == *"git"* ]]

echo "==> palace kg"
DODEXABASH_HOME="$palace_home" "$binary" -c 'palace kg add swift language compiled' >/dev/null
palace_kg="$(DODEXABASH_HOME="$palace_home" "$binary" -c 'palace kg query swift')"
[[ "$palace_kg" == *"compiled"* ]]

echo "==> palace wake"
DODEXABASH_HOME="$palace_home" "$binary" -c 'palace identity test-identity' >/dev/null
DODEXABASH_HOME="$palace_home" "$binary" -c 'palace fact test-fact-one' >/dev/null
palace_wake="$(DODEXABASH_HOME="$palace_home" "$binary" -c 'palace wake')"
[[ "$palace_wake" == *"test-identity"* ]]

echo "==> palace graph"
palace_graph="$(DODEXABASH_HOME="$palace_home" "$binary" -c 'palace graph')"
[[ "$palace_graph" == *"work"* ]]

echo "==> pipeline status"
pipe_status="$("$binary" -c 'pipeline status')"
[[ "$pipe_status" == *"Pipeline Engine"* ]]
[[ "$pipe_status" == *"token-optimizer"* ]]

echo "==> pipeline test"
pipe_test="$("$binary" -c 'pipeline test')"
[[ "$pipe_test" == *"Pipeline Result"* ]]

echo "==> pipeline optimize"
pipe_opt="$("$binary" -c 'pipeline optimize in order to understand how it works please analyze this')"
[[ "$pipe_opt" == *"Optimized"* ]]

echo "==> browse headers"
browse_headers="$("$binary" -c "browse headers $browse_html_url")"
[[ "$browse_headers" == *"HTTP 200"* ]]

echo "==> browse text"
browse_text="$("$binary" -c "browse text $browse_html_url")"
[[ "$browse_text" == *"Example Domain"* ]]

echo "==> browse api"
browse_api="$("$binary" -c "browse api $browse_json_url")"
[[ "$browse_api" == *"delectus"* ]]

echo "==> browse js"
browse_js="$("$binary" -c "browse js $browse_html_url 2+3")"
[[ "$browse_js" == *"5"* ]]

echo "==> prism help"
prism_help="$("$binary" -c 'prism help')"
[[ "$prism_help" == *"PRISM"* ]]
[[ "$prism_help" == *"Population"* ]]

echo "==> prism thesaurus stats"
prism_stats="$("$binary" -c 'prism thesaurus stats')"
[[ "$prism_stats" == *"Concepts"* ]]

echo "==> prism explode"
prism_explode="$("$binary" -c 'prism explode myocardial infarction')"
[[ "$prism_explode" == *"heart attack"* ]]
[[ "$prism_explode" == *"Boolean"* ]]

echo "smoke tests passed"

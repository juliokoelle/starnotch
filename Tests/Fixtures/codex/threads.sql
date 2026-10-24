-- The columns of Codex's `threads` table (state_5.sqlite) the provider reads, with anonymised rows.
-- {ROOT} is the fixture's Codex folder, {NOW} the test's clock in epoch seconds.
CREATE TABLE threads (
    id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    source TEXT NOT NULL, model_provider TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
    sandbox_policy TEXT NOT NULL, approval_mode TEXT NOT NULL, tokens_used INTEGER NOT NULL DEFAULT 0,
    has_user_event INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0, archived_at INTEGER,
    git_sha TEXT, git_branch TEXT, git_origin_url TEXT, cli_version TEXT NOT NULL DEFAULT '',
    first_user_message TEXT NOT NULL DEFAULT '', agent_nickname TEXT, agent_role TEXT,
    memory_mode TEXT NOT NULL DEFAULT 'enabled', model TEXT, reasoning_effort TEXT, agent_path TEXT,
    created_at_ms INTEGER, updated_at_ms INTEGER, thread_source TEXT, preview TEXT NOT NULL DEFAULT '',
    recency_at INTEGER NOT NULL DEFAULT 0, recency_at_ms INTEGER NOT NULL DEFAULT 0,
    history_mode TEXT NOT NULL DEFAULT 'legacy', name TEXT, is_pinned INTEGER NOT NULL DEFAULT 0,
    thread_section_id TEXT, section_position INTEGER, section_entered_at_ms INTEGER, project_id TEXT,
    originator TEXT, daybreak_enabled BOOLEAN, creator_user_id TEXT, creator_account_id TEXT);
INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode, git_branch, model, reasoning_effort, name, thread_source, history_mode, archived)
VALUES
('019a0001-0000-7000-8000-00000000c0de', '{ROOT}/sessions/2026/10/20/rollout-2026-10-20T11-52-48-019a0001-0000-7000-8000-00000000c0de.jsonl', {NOW} - 3600, {NOW} - 600, 'vscode', 'openai', '/Users/ada/projects/harbor', 'Please add a CSV export to the report page.', '{}', 'on-request', 'main', 'gpt-6.1-sol', 'high', 'CSV export for reports', 'user', 'paginated', 0),
('019a0001-0000-7000-8000-00000000b0d1', '{ROOT}/sessions/2026/10/20/rollout-2026-10-20T11-55-00-019a0001-0000-7000-8000-00000000b0d1.jsonl', {NOW} - 900, {NOW} - 30, 'cli', 'openai', '/Users/ada/projects/harbor', 'Fix the flaky export test', '{}', 'on-request', 'fix/export-test', 'gpt-6.1-sol', 'xhigh', 'Flaky export test', 'user', 'paginated', 0),
('019a0001-0000-7000-8000-00000000b0d2', '{ROOT}/sessions/2026/10/20/rollout-2026-10-20T11-56-00-019a0001-0000-7000-8000-00000000b0d2.jsonl', {NOW} - 300, {NOW} - 20, '{"subagent":{"thread_spawn":{"parent_thread_id":"019a0001-0000-7000-8000-00000000b0d1","depth":1,"agent_path":"/root/export_tests","agent_nickname":"Lovelace","agent_role":null}}}', 'openai', '/Users/ada/projects/harbor', 'export tests', '{}', 'never', NULL, 'gpt-6.1-sol', 'medium', NULL, 'subagent', 'paginated', 0),
('019a0001-0000-7000-8000-00000000a0d1', '{ROOT}/sessions/2026/10/20/rollout-2026-10-20T11-53-03-019a0001-0000-7000-8000-00000000a0d1.jsonl', {NOW} - 700, {NOW} - 650, '{"subagent":{"other":"guardian"}}', 'openai', '/Users/ada/projects/harbor', 'Guardian review', '{}', 'never', NULL, 'codex-auto-review', 'low', 'Guardian review', 'guardian_review', 'paginated', 0),
('019a0001-0000-7000-8000-00000000dead', '{ROOT}/sessions/2026/10/19/rollout-2026-10-19T09-00-00-019a0001-0000-7000-8000-00000000dead.jsonl', {NOW} - 90000, {NOW} - 86000, 'vscode', 'openai', '/Users/ada/projects/harbor', 'Yesterday', '{}', 'on-request', NULL, 'gpt-6.1-sol', 'high', 'Old thread', 'user', 'paginated', 0),
('019a0001-0000-7000-8000-00000000a7c4', '{ROOT}/sessions/2026/10/20/rollout-2026-10-20T10-00-00-019a0001-0000-7000-8000-00000000a7c4.jsonl', {NOW} - 7200, {NOW} - 100, 'vscode', 'openai', '/Users/ada/projects/harbor', 'Archived one', '{}', 'on-request', NULL, 'gpt-6.1-sol', 'high', 'Archived', 'user', 'paginated', 1);

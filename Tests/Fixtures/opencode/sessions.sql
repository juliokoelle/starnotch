CREATE TABLE `session` (
  `id` text PRIMARY KEY, `project_id` text NOT NULL, `parent_id` text, `slug` text NOT NULL,
  `directory` text NOT NULL, `title` text NOT NULL, `version` text NOT NULL, `share_url` text,
  `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `time_compacting` integer, `time_archived` integer);
INSERT INTO session VALUES ('ses_0001', 'prj', NULL, 'calm-river', '/Users/me/projects/harbor', 'Speed up the report page', '1.19.4', NULL, {NOW_MS} - 1800000, {NOW_MS} - 120000, NULL, NULL);
INSERT INTO session VALUES ('ses_0002', 'prj', 'ses_0001', 'quiet-lake', '/Users/me/projects/harbor', 'Find slow queries (@explore subagent)', '1.19.4', NULL, {NOW_MS} - 600000, {NOW_MS} - 300000, NULL, NULL);
INSERT INTO session VALUES ('ses_0003', 'prj', NULL, 'old-hill', '/Users/me/projects/harbor', 'Yesterday''s work', '1.19.4', NULL, {NOW_MS} - 90000000, {NOW_MS} - 86400000, NULL, NULL);
INSERT INTO session VALUES ('ses_0004', 'prj', NULL, 'gone-bay', '/Users/me/projects/api', 'Archived', '1.19.4', NULL, {NOW_MS} - 600000, {NOW_MS} - 60000, NULL, {NOW_MS} - 30000);

# Database migration proposal

This document proposes schema and sequencing only. Phase 0 does not execute a migration or open a database for writing.

## Physical-store decision

Preserve the current split:

- `models.sqlite3` becomes the canonical MLX Studio project/artifact/job/evaluation store.
- `vmlx.sqlite3` continues to own chat sessions, messages, drafts, and API-key metadata.
- `settings.sqlite3` continues to own engine/session/chat settings JSON.
- `image_history.sqlite3` continues to own image-generation history.

This retains the current failure isolation. Cross-store artifact references are validated by repositories because SQLite cannot enforce foreign keys across independent files.

## Current schemas

| Store | Version | Current tables | Source |
| --- | ---: | --- | --- |
| `models.sqlite3` | 2 | `models`, `user_dirs` | `Sources/vMLXEngine/Library/ModelLibraryDB.swift` |
| `vmlx.sqlite3` | 4 | `sessions`, `messages`, `chat_drafts`, `api_keys` | `Sources/vMLXApp/Storage/Database.swift` |
| `settings.sqlite3` | 1 | `global_settings`, `session_settings`, `chat_settings` | `Sources/vMLXEngine/Settings/SettingsDB.swift` |
| `image_history.sqlite3` | 0 | `image_generations` | `Sources/vMLXApp/Storage/ImageHistoryStore.swift` |

The installed 0.2.5/2026071302 snapshot matched these source schemas. It contained 11 model rows, 12 chat sessions, and 55 messages at inspection time. Counts are evidence only and are not migration assertions.

### Current table shapes and constraints

The following is the normalized source/live shape used as the migration baseline. `PK` means primary key, `UQ` means unique, and all unmarked columns are nullable.

| Store / table | Columns and constraints |
| --- | --- |
| `vmlx.sessions` | `id TEXT PK`; `title TEXT NOT NULL`; `model_path TEXT`; `model_name TEXT`; `is_pinned INTEGER NOT NULL DEFAULT 0`; `collection_name TEXT`; `created_at REAL NOT NULL`; `updated_at REAL NOT NULL` |
| `vmlx.messages` | `id TEXT PK`; `session_id TEXT NOT NULL FK sessions(id) ON DELETE CASCADE`; `role TEXT NOT NULL`; `content TEXT NOT NULL`; `reasoning TEXT`; `tool_calls_json TEXT`; `created_at REAL NOT NULL`; `is_streaming INTEGER NOT NULL DEFAULT 0`; `image_data BLOB`; `video_paths BLOB`; `tool_statuses BLOB`; `request_context TEXT NOT NULL DEFAULT ''`; `generation_state TEXT`; index `(session_id, created_at)` |
| `vmlx.chat_drafts` | `session_id TEXT PK/FK sessions(id) ON DELETE CASCADE`; `input_text TEXT NOT NULL DEFAULT ''`; `image_data BLOB`; `video_paths BLOB`; `document_data BLOB`; `updated_at REAL NOT NULL` |
| `vmlx.api_keys` | `id TEXT PK`; `label TEXT NOT NULL`; `value TEXT NOT NULL`; `created_at REAL NOT NULL`; `last_used_at REAL` |
| `models.models` | `id TEXT PK`; `canonical_path TEXT NOT NULL UQ`; `display_name TEXT NOT NULL`; `family TEXT NOT NULL`; `modality TEXT NOT NULL`; `total_size_bytes INTEGER NOT NULL`; `is_jang INTEGER NOT NULL`; `is_mxtq INTEGER NOT NULL`; `quant_bits INTEGER`; `detected_at REAL NOT NULL`; `source TEXT NOT NULL`; `capabilities_json TEXT NOT NULL DEFAULT '{}'`; indexes on `family` and `modality` |
| `models.user_dirs` | `url TEXT PK`; `added_at REAL NOT NULL` |
| `settings.global_settings` | `id TEXT PK`; `settings_json TEXT NOT NULL`; `updated_at REAL NOT NULL` |
| `settings.session_settings` | `id TEXT PK`; `settings_json TEXT NOT NULL`; `updated_at REAL NOT NULL` |
| `settings.chat_settings` | `id TEXT PK`; `settings_json TEXT NOT NULL`; `updated_at REAL NOT NULL` |
| `image_history.image_generations` | `id TEXT PK`; `model_alias TEXT NOT NULL`; `prompt TEXT NOT NULL`; `source_image_path TEXT`; `mask_path TEXT`; `settings_json TEXT NOT NULL`; `output_path TEXT`; `created_at REAL NOT NULL`; `duration_ms INTEGER`; `status TEXT NOT NULL`; descending index on `created_at` |

## Canonical artifact schema

All IDs are lowercase UUID strings unless noted. Timestamps are UTC Unix seconds. Structured values that need independent querying use normalized tables; versioned, low-churn payloads may use canonical JSON with a schema column. Foreign keys are enabled and indexed.

| Table | Required columns and constraints |
| --- | --- |
| `model_projects` | `id PK`, `name`, `source_id FK model_sources`, `created_at`, `updated_at`; index `updated_at` |
| `model_sources` | `id PK`, `legacy_model_id UNIQUE NULL`, `local_url`, `repository_id`, `revision`, `architecture`, `parameter_count`, `active_parameter_count`, `expert_topology_json`, `capabilities_json`, `source_format`, `source_precision`, `created_at`; require local URL or repository ID |
| `model_artifacts` | `id PK`, `project_id FK`, `parent_artifact_id FK NULL`, `legacy_model_id UNIQUE NULL`, `name`, `local_url`, `canonical_path UNIQUE`, `format`, `precision`, `state`, `manifest_id UNIQUE NULL`, `verification_status`, `content_hash NULL`, `created_at`, `updated_at`; indexes on project, parent, hash, state |
| `artifact_manifests` | `id PK`, `artifact_id UNIQUE FK`, `schema_version`, `source_revision`, `runtime_version`, `optimizer_version`, `kernel_version`, `pruning_plan_id`, `quantization_recipe_id`, `calibration_suite_id`, `hardware_profile_id FK`, `manifest_hash UNIQUE`, `payload_json`, `created_at` |
| `artifact_source_files` | `manifest_id FK`, `relative_path`, `size_bytes`, `sha256`, composite PK `(manifest_id, relative_path)` |
| `artifact_lineage` | `parent_artifact_id FK`, `child_artifact_id FK`, `operation`, `job_id`, `manifest_id`, `created_at`; composite PK `(parent_artifact_id, child_artifact_id, operation)` and no self-edge |
| `hardware_profiles` | `id PK`, `chip_name`, `unified_memory_bytes`, `os_version`, `gpu_core_count`, `cpu_core_count`, `available_disk_bytes`, `captured_at`, `profile_hash UNIQUE` |
| `analysis_runs` | `id PK`, `project_id FK`, `artifact_id FK`, `strategy_identifier`, `strategy_version`, `suite_id FK`, `job_id FK`, `status`, `result_json`, `started_at`, `ended_at` |
| `expert_evidence` | `analysis_run_id FK`, `layer`, `expert`, percentile/route/gate/contribution/confidence columns, `domain_scores_json`, `warnings_json`; composite PK `(analysis_run_id, layer, expert)` |
| `expert_directives` | `plan_id FK`, `layer`, `expert`, `directive CHECK auto/keep/remove`, `updated_at`; composite PK `(plan_id, layer, expert)` |
| `optimization_plans` | `id PK`, `project_id FK`, `source_artifact_id FK`, `objective_json`, `pruning_configuration_json`, `quantization_recipe_id FK NULL`, `estimated_result_json`, `validation_status`, `schema_version`, `created_at`, `updated_at` |
| `quantization_recipes` | `id PK`, `name`, `technology CHECK jang/jangtq`, `profile`, `tensor_role_rules_json`, `calibration_suite_id FK NULL`, `schema_version`, `created_at` |
| `build_runs` | `id PK`, `plan_id FK`, `job_id UNIQUE FK`, `output_artifact_id FK NULL`, `worker_identifier`, `tool_versions_json`, `command_manifest_json`, `partial_output_policy`, `status`, `started_at`, `ended_at` |
| `verification_reports` | `id PK`, `artifact_id FK`, `job_id FK NULL`, `status`, `checks_json`, `diagnostic_export_url`, `runtime_smoke_generation_id NULL`, `created_at` |
| `evaluation_suites` | `id PK`, `name`, `revision`, `tags_json`, `suite_hash UNIQUE`, `created_at`, `updated_at`; unique `(name, revision)` |
| `evaluation_cases` | `id PK`, `suite_id FK`, `ordinal`, `prompt`, `system_prompt`, `domain`, `tags_json`, `expected_kind`, `expected_value`, `generation_configuration_json`, `weight`, unique `(suite_id, ordinal)` |
| `evaluation_runs` | `id PK`, `suite_id FK`, `hardware_profile_id FK`, `runtime_version`, `kernel_version`, `execution_order_json`, `status`, `started_at`, `ended_at` |
| `evaluation_run_artifacts` | `run_id FK`, `artifact_id FK`, `blind_label`, `artifact_hash`, composite PK `(run_id, artifact_id)`; blind label unique per run |
| `evaluation_results` | `id PK`, `run_id FK`, `case_id FK`, `artifact_id FK`, `generation_id`, `output_text`, `score_kind`, `score_value`, `score_payload_json`, `runtime_metrics_json`, `error_json`, `created_at`; unique `(run_id, case_id, artifact_id)` |
| `human_judgments` | `id PK`, `run_id FK`, `case_id FK`, `assignment_json`, `choice`, `notes`, `revealed_at NULL`, `created_at`; identity is never stored in assignment-facing fields before reveal |
| `jobs` | `id PK`, `type`, `project_id FK NULL`, `artifact_id FK NULL`, `state`, `progress`, `current_stage`, `log_url`, `diagnostic_export_url`, `peak_memory_bytes`, `error_json`, `recovery_instructions`, `created_at`, `started_at`, `ended_at`, `updated_at` |
| `job_events` | `job_id FK`, `sequence`, `event_type`, `payload_json`, `created_at`; composite PK `(job_id, sequence)` |

The existing `models` and `user_dirs` tables remain intact during Phase 1. `artifact_source_files`, `evaluation_run_artifacts`, and `job_events` are supporting tables required to normalize the brief's conceptual models.

## Version sequence

### `models.sqlite3`

1. Version 3: create all project/artifact/manifest/hardware tables and indexes; do not backfill in the DDL transaction.
2. Version 4: idempotently backfill one source, project, artifact, and minimal imported manifest per legacy `models` row. Store legacy `models.id` in unique `legacy_model_id`. A rerun uses that key and never creates a second artifact.
3. Version 5: create analysis/plan/recipe/build/verification tables.
4. Version 6: create evaluation/human-judgment tables.
5. Version 7: create jobs/events and add repair indexes.

Each version runs inside `BEGIN IMMEDIATE`; migration functions throw on any SQL failure and roll back without advancing `user_version`.

### `vmlx.sqlite3`

1. Version 5: add nullable `artifact_id` to `sessions` plus an index. Preserve `model_path` and `model_name`.
2. Backfill through `ModelArtifactRepository` by exact normalized canonical path. Missing/ambiguous matches remain null and produce a repair report; they do not guess.
3. Later removal of path/name compatibility requires a separate ADR and installed-app migration proof; it is outside the initial consolidation.

Server session state is currently app/session configuration rather than a standalone durable server table. If a durable table is added later, it stores the same nullable artifact ID plus a compatibility path during migration.

### Other stores

No Phase 1 schema changes. Future image records may gain a nullable artifact ID, but image-history ownership does not move merely to satisfy physical consolidation.

## Backfill and hashing rules

- Normalize paths with symlink resolution and standardized file URLs before matching.
- Allocate a UUID once for a legacy row and persist the mapping via `legacy_model_id`; never derive identity from the current path at runtime.
- Imported artifacts begin in `discovered` state with verification status `unknown` unless existing evidence can be validated.
- Minimal imported manifests record source metadata and detected format but do not invent optimizer, kernel, or verification claims.
- Full content hashing is an incremental job. Until complete, identity uses the UUID and canonical path; deduplication remains pending.
- Manifest hashing uses canonical JSON and sorted relative file records. Paths outside the artifact are redacted from exported manifests.

## Compatibility and rollback

- New repositories dual-read: prefer artifact tables, fall back to legacy `models` only when no mapped artifact exists.
- Writes during compatibility update artifact tables first and maintain the legacy model index only where old readers require it.
- No destructive table rename/drop occurs before all app consumers use artifact IDs and two consecutive installed-app upgrades have passed.
- Before a release migration, copy the SQLite file and WAL/SHM consistently using the SQLite backup API, not filesystem copying of an open database.
- A failed migration rolls back the current transaction and leaves the prior `user_version`. Startup then uses the prior reader or presents an actionable recovery error; it must not recreate an empty database over user data.

## Required migration tests

- Empty database to latest.
- Versions 1 and 2 with representative MLX/JANG/JANGTQ model rows.
- Re-running every migration produces no duplicates.
- Duplicate canonical path and duplicate legacy ID roll back cleanly.
- Missing artifact folders remain represented but non-runnable.
- Existing chat sessions/messages/drafts and settings remain byte-for-byte readable.
- Chat artifact backfill covers exact matches, missing paths, symlinked paths, and ambiguous duplicates.
- Interrupted migration preserves prior version and succeeds on retry.
- Installed 0.2.5 database copies upgrade and relaunch without altering original test fixtures.

-- name: GetTemplateVersionsByTemplateID :many
SELECT
	*
FROM
	template_version_with_user AS template_versions
WHERE
	template_id = @template_id :: uuid
	AND CASE
		-- If no filter is provided, default to returning ALL template versions.
		-- The called should always provide a filter if they want to omit
		-- deleted versions.
		WHEN sqlc.narg('deleted') :: boolean IS NULL THEN true
		ELSE template_versions.deleted = sqlc.narg('deleted') :: boolean
	END
	AND CASE
		-- This allows using the last element on a page as effectively a cursor.
		-- This is an important option for scripts that need to paginate without
		-- duplicating or missing data.
		WHEN @after_id :: uuid != '00000000-0000-0000-0000-000000000000'::uuid THEN (
			-- The pagination cursor is the last ID of the previous page.
			-- The query is ordered by the created_at field, so select all
			-- rows after the cursor.
			(created_at, id) > (
				SELECT
					created_at, id
				FROM
					template_versions
				WHERE
					id = @after_id
			)
		)
		ELSE true
	END
ORDER BY
	-- Deterministic and consistent ordering of all rows, even if they share
	-- a timestamp. This is to ensure consistent pagination.
	(created_at, id) ASC OFFSET @offset_opt
LIMIT
	-- A null limit means "no limit", so 0 means return all
	NULLIF(@limit_opt :: int, 0);

-- name: GetTemplateVersionByJobID :one
SELECT
	*
FROM
	template_version_with_user AS template_versions
WHERE
	job_id = $1;

-- name: GetTemplateVersionsCreatedAfter :many
SELECT * FROM template_version_with_user AS template_versions WHERE created_at > $1;

-- name: GetTemplateVersionByTemplateIDAndName :one
SELECT
	*
FROM
	template_version_with_user AS template_versions
WHERE
	template_id = $1
	AND "name" = $2;

-- name: GetTemplateVersionByID :one
SELECT
	*
FROM
	template_version_with_user AS template_versions
WHERE
	id = $1;

-- name: GetTemplateVersionsByIDs :many
SELECT
	*
FROM
	template_version_with_user AS template_versions
WHERE
	id = ANY(@ids :: uuid [ ]);

-- name: InsertTemplateVersion :exec
INSERT INTO
	template_versions (
		id,
		template_id,
		organization_id,
		created_at,
		updated_at,
		"name",
		message,
		readme,
		job_id,
		created_by
	)
VALUES
	($1, $2, $3, $4, $5, $6, $7, $8, $9, $10);

-- name: UpdateTemplateVersionByID :exec
UPDATE
	template_versions
SET
	template_id = $2,
	updated_at = $3,
	name = $4,
	message = $5
WHERE
	id = $1;

-- name: UpdateTemplateVersionDescriptionByJobID :exec
UPDATE
	template_versions
SET
	readme = $2,
	updated_at = $3
WHERE
	job_id = $1;

-- name: UpdateTemplateVersionExternalAuthProvidersByJobID :exec
UPDATE
	template_versions
SET
	external_auth_providers = $2,
	updated_at = $3
WHERE
	job_id = $1;

-- name: GetPreviousTemplateVersion :one
SELECT
	*
FROM
	template_version_with_user AS template_versions
WHERE
	created_at < (
		SELECT created_at
		FROM template_version_with_user AS tv
		WHERE tv.organization_id = $1 AND tv.name = $2 AND tv.template_id = $3
	)
	AND organization_id = $1
	AND template_id = $3
ORDER BY created_at DESC
LIMIT 1;


-- name: PruneUnusedTemplateVersions :many
-- Pruning templates is a soft delete action, so is technically reversible.
-- Soft deleting prevents the version from being used and discovered
-- by listing.
-- Only unused template versions will be pruned, which are any versions not
-- referenced by the latest build of a workspace.
UPDATE
	template_versions
SET
	deleted = true,
	updated_at = sqlc.arg('updated_at')
FROM
	-- Delete all versions that are returned from this query.
	(
		SELECT
			scoped_template_versions.id
		FROM
			-- Scope a prune to a single template and ignore already deleted template versions
			(SELECT * FROM template_versions WHERE template_versions.template_id = sqlc.arg('template_id') :: uuid AND deleted = false) AS scoped_template_versions
		LEFT JOIN
			provisioner_jobs ON scoped_template_versions.job_id = provisioner_jobs.id
		LEFT JOIN
			templates ON scoped_template_versions.template_id = templates.id
		WHERE
		-- Actively used template versions (meaning the latest build is using
		-- the version) are never pruned. A "restart" command on the workspace,
		-- even if failed, would use the version. So it cannot be pruned until
		-- the build is outdated.
		NOT EXISTS (
			-- Return all "used" versions, where "used" is defined as being
		    -- used by a latest workspace build.
			SELECT template_version_id FROM (
				SELECT
				    DISTINCT ON (workspace_id) template_version_id, transition
				FROM
				    workspace_builds
				ORDER BY workspace_id, build_number DESC
			) AS used_versions
			WHERE
				-- TODO: This is an issue for "deleted workspaces", since a deleted workspace
				-- 	has a build with the transition "delete". This will prevent that template
				-- 	version from ever being pruned. We need a method to prune deleted workspaces.
-- 				used_versions.transition != 'delete',
				scoped_template_versions.id = used_versions.template_version_id
		)
		  -- Also never delete the active template version
		AND active_version_id != scoped_template_versions.id
		AND CASE
			-- Optionally, only prune versions that match a given
			-- job status like 'failed'.
			WHEN sqlc.narg('job_status') :: provisioner_job_status IS NOT NULL THEN
				provisioner_jobs.job_status = sqlc.narg('job_status') :: provisioner_job_status
			ELSE
				true
		END
		-- Pending or running jobs should not be pruned, as they are "in progress"
		AND provisioner_jobs.job_status != 'running'
		AND provisioner_jobs.job_status != 'pending'
	) AS deleted_versions
WHERE
	template_versions.id IN (deleted_versions.id)
RETURNING template_versions.id;

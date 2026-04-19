local util = require("nvim-dap-unity.util")

local M = {}

local function make_error(code, stage, message, suggestion, detail)
	return {
		code = code,
		stage = stage,
		message = message,
		suggestion = suggestion,
		detail = detail,
	}
end

local function err_to_string(err)
	if type(err) == "string" then
		return err
	end
	if type(err) ~= "table" then
		return tostring(err)
	end

	local parts = {}
	if err.stage and err.code then
		table.insert(parts, ("[%s/%s]"):format(err.stage, err.code))
	elseif err.code then
		table.insert(parts, ("[%s]"):format(err.code))
	end
	if err.message and err.message ~= "" then
		table.insert(parts, err.message)
	end
	if err.suggestion and err.suggestion ~= "" then
		table.insert(parts, ("suggestion: %s"):format(err.suggestion))
	end

	local detail = err.detail
	if detail ~= nil and detail ~= "" then
		local detail_text
		if type(detail) == "string" then
			detail_text = detail
			if #detail_text > 500 then
				detail_text = detail_text:sub(1, 500) .. "..."
			end
		else
			detail_text = vim.inspect(detail)
		end
		if detail_text ~= "" then
			table.insert(parts, ("detail: %s"):format(detail_text))
		end
	end

	if #parts == 0 then
		return vim.inspect(err)
	end
	return table.concat(parts, " ")
end

function M.format_error(err)
	return err_to_string(err)
end

local function now_iso()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function default_vstuc_dir(install_dir)
	return util.joinpath(install_dir, "vstuc")
end

local function manifest_path(vstuc_dir)
	return util.joinpath(vstuc_dir, "manifest.json")
end

local function tmp_dir(root)
	return util.joinpath(root, "tmp")
end

local function ensure_dir(path)
	util.mkdirp(path)
	return path
end

local function list_dirs(path)
	local entries = vim.fs.dir(path)
	local out = {}
	for name, t in entries do
		if t == "directory" then
			table.insert(out, util.joinpath(path, name))
		end
	end
	return out
end

local function find_files_recursive(root, filename)
	local results = {}
	local stack = { root }
	local visited = {}

	while #stack > 0 do
		local dir = table.remove(stack)
		if not visited[dir] then
			visited[dir] = true
			for name, t in vim.fs.dir(dir) do
				local full = util.joinpath(dir, name)
				if t == "file" and name == filename then
					table.insert(results, full)
				elseif t == "directory" then
					table.insert(stack, full)
				end
			end
		end
	end

	return results
end

-- Locate the extension's package.json inside the extracted VSIX. Prefers the
-- shallowest match so we pick `extension/package.json` over deeper hits like
-- `extension/node_modules/<dep>/package.json`.
local function find_package_meta(extracted_dir)
	local matches = find_files_recursive(extracted_dir, "package.json")
	if #matches == 0 then
		return nil
	end
	table.sort(matches, function(a, b) return #a < #b end)

	local content = util.read_file(matches[1])
	if not content or content == "" then
		return nil
	end
	local ok, decoded = pcall(util.json_decode, content)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	return {
		name = decoded.name,
		version = decoded.version,
		publisher = decoded.publisher,
		display_name = decoded.displayName,
	}
end

local function read_manifest(vstuc_dir)
	local path = manifest_path(vstuc_dir)
	local content = util.read_file(path)
	if not content or content == "" then
		return nil
	end

	local ok, decoded = pcall(util.json_decode, content)
	if not ok then
		return nil
	end

	return decoded
end

local function write_manifest(vstuc_dir, manifest)
	local path = manifest_path(vstuc_dir)
	local encoded = util.json_encode(manifest)
	util.write_file_atomic(path, encoded)
end

local function validate_required_files(manifest)
	local missing = {}
	local files = manifest.files or {}

	if not files["UnityDebugAdapter.dll"] or not util.is_file(files["UnityDebugAdapter.dll"]) then
		table.insert(missing, "UnityDebugAdapter.dll")
	end

	return missing
end

local function bin_dir_from_files(files)
	local dll = files["UnityDebugAdapter.dll"]
	if not dll then
		return nil
	end
	return vim.fs.dirname(dll)
end

local function tool_exists(cmd)
	-- Sync — only used during pre-flight inside coroutine; fast (where/command -v).
	if util.is_windows() then
		local r = util.system({ "where", cmd }, { timeout = 2000 })
		return r.code == 0 and r.stdout ~= ""
	end
	local r = util.system({ "sh", "-lc", "command -v " .. cmd }, { timeout = 2000 })
	return r.code == 0
end

local function await_download_file(url, out_path)
	ensure_dir(vim.fs.dirname(out_path))

	if util.is_windows() then
		local ps = table.concat({
			"$ErrorActionPreference = 'Stop'",
			("Invoke-WebRequest -Uri '%s' -OutFile '%s'"):format(url, out_path:gsub("'", "''")),
		}, "; ")
		local r = util.await_system({ "powershell", "-NoProfile", "-Command", ps }, { timeout = 120000 })
		if r.code ~= 0 then
			return nil, make_error(
				"download_failed",
				"download",
				"failed to download vstuc package",
				"check your network or try again later",
				r.stderr ~= "" and r.stderr or r.stdout
			)
		end
		return out_path
	end

	if not tool_exists("curl") then
		return nil, make_error("missing_tool", "download", "curl not found", "please install curl", "")
	end

	-- Use --compressed to automatically decompress gzip/deflate responses from VS Marketplace
	local r = util.await_system({ "sh", "-lc", ("curl -fL --compressed --retry 2 --retry-delay 1 -o %q %q"):format(out_path, url) }, {
		timeout = 120000,
	})
	if r.code ~= 0 then
		return nil, make_error(
			"download_failed",
			"download",
			"failed to download vstuc package",
			"check your network or try again later",
			r.stderr ~= "" and r.stderr or r.stdout
		)
	end

	return out_path
end

local function await_unzip_package(zip_path, out_dir)
	ensure_dir(out_dir)

	if util.is_windows() then
		local ps = table.concat({
			"$ErrorActionPreference = 'Stop'",
			("Expand-Archive -Path '%s' -DestinationPath '%s' -Force"):format(zip_path:gsub("'", "''"), out_dir:gsub("'", "''")),
		}, "; ")
		local r = util.await_system({ "powershell", "-NoProfile", "-Command", ps }, { timeout = 120000 })
		if r.code ~= 0 then
			return nil, make_error(
				"unzip_failed",
				"unzip",
			"failed to unzip vstuc package",
			"ensure PowerShell Expand-Archive works (Windows) or retry; if it fails try updating PowerShell or .NET",

				r.stderr ~= "" and r.stderr or r.stdout
			)
		end
		return out_dir
	end

	if not tool_exists("unzip") then
		return nil, make_error("missing_tool", "unzip", "unzip not found", "please install unzip", "")
	end

	local r = util.await_system({ "sh", "-lc", ("unzip -o %q -d %q"):format(zip_path, out_dir) }, { timeout = 120000 })
	if r.code ~= 0 then
		return nil, make_error(
			"unzip_failed",
			"unzip",
			"failed to unzip vstuc package",
			"ensure unzip is available and the downloaded file is valid",
			r.stderr ~= "" and r.stderr or r.stdout
		)
	end

	return out_dir
end

local function await_rm_rf(path)
	if not path or path == "" then
		return
	end
	if util.is_windows() then
		util.await_system({ "powershell", "-NoProfile", "-Command", ("Remove-Item -LiteralPath '%s' -Recurse -Force -ErrorAction SilentlyContinue"):format(path:gsub("'", "''")) }, {
			timeout = 120000,
		})
		return
	end
	util.await_system({ "sh", "-lc", ("rm -rf %q"):format(path) }, { timeout = 120000 })
end

local function await_replace_dir_atomic(from_dir, to_dir)
	-- Best-effort atomic replace: move old aside, move new in.
	local backup = to_dir .. ".bak"
	await_rm_rf(backup)

	local had_old = util.is_dir(to_dir)
	if had_old then
		local ok = os.rename(to_dir, backup)
		if not ok then
			return false, make_error(
				"permissions",
				"replace",
				"failed to move existing install aside",
				"close programs using the directory and ensure permissions",
				("from=%s to=%s"):format(to_dir, backup)
			)
		end
	end

	local ok = os.rename(from_dir, to_dir)
	if not ok then
		if had_old and util.is_dir(backup) then
			os.rename(backup, to_dir)
		end
		return false, make_error(
			"permissions",
			"replace",
			"failed to move new install into place",
			"ensure the destination directory is writable",
			("from=%s to=%s"):format(from_dir, to_dir)
		)
	end

	await_rm_rf(backup)
	return true
end

local function build_status(install_dir, vstuc_dir, manifest, legacy)
	local missing = validate_required_files(manifest)
	local bin_dir = nil
	if manifest.files then
		bin_dir = bin_dir_from_files(manifest.files)
	end

	return {
		installed = #missing == 0,
		install_dir = install_dir,
		vstuc_dir = vstuc_dir,
		bin_dir = bin_dir,
		missing = missing,
		manifest = manifest,
		legacy = legacy or nil,
	}
end

function M.status(opts)
	local install_dir = opts.install_dir
	local vstuc_dir = default_vstuc_dir(install_dir)
	local manifest = read_manifest(vstuc_dir)
	if manifest then
		return build_status(install_dir, vstuc_dir, manifest, false)
	end

	-- Read-only fallback: older versions of this plugin installed under
	-- stdpath('data')/lazy/nvim-dap-unity/. Use that install if present so
	-- existing users don't have to re-download. Future installs/updates always
	-- write to opts.install_dir, which lets the legacy copy decay naturally.
	for _, legacy_dir in ipairs(opts.legacy_install_dirs or {}) do
		local legacy_vstuc = default_vstuc_dir(legacy_dir)
		local legacy_manifest = read_manifest(legacy_vstuc)
		if legacy_manifest and #validate_required_files(legacy_manifest) == 0 then
			return build_status(legacy_dir, legacy_vstuc, legacy_manifest, true)
		end
	end

	return {
		installed = false,
		install_dir = install_dir,
		vstuc_dir = vstuc_dir,
		bin_dir = nil,
		missing = { "manifest.json" },
		manifest = nil,
	}
end

local function build_manifest(opts, install_dir, extracted_dir)
	local dlls = find_files_recursive(extracted_dir, "UnityDebugAdapter.dll")
	local probes = find_files_recursive(extracted_dir, "UnityAttachProbe.dll")

	local files = {}
	if #dlls > 0 then
		files["UnityDebugAdapter.dll"] = dlls[1]
	end
	if #probes > 0 then
		files["UnityAttachProbe.dll"] = probes[1]
	end

	local manifest = {
		installed_at = now_iso(),
		source_url = opts.download_url,
		install_dir = install_dir,
		requested_version = opts.vstuc_version,
		package = find_package_meta(extracted_dir),
		files = files,
	}
	manifest.bin_dir = bin_dir_from_files(files)
	return manifest
end

local function validate_manifest(manifest)
	local missing = validate_required_files(manifest)
	if #missing > 0 then
		return false, make_error(
			"validate_failed",
			"validate",
			("missing required files: %s"):format(table.concat(missing, ", ")),
			"the vstuc package layout may have changed; try updating again later",
			missing
		)
	end
	if not manifest.bin_dir or manifest.bin_dir == "" then
		return false, make_error(
			"validate_failed",
			"validate",
			"bin_dir not found",
			"the vstuc package layout may have changed; try updating again later",
			""
		)
	end
	return true
end

local function noop() end

local TOTAL_STEPS = 4

local function step_msg(n, msg)
	return ("[%d/%d] %s"):format(n, TOTAL_STEPS, msg)
end

-- Runs inside a coroutine. Returns (status, err).
local function do_install_co(opts, force, on_progress)
	local install_dir = opts.install_dir
	local vstuc_dir = default_vstuc_dir(install_dir)

	local s = M.status(opts)
	if not force then
		-- Legacy installs report installed=true but live at the old path;
		-- proceed with the install so they get migrated to opts.install_dir.
		if s.installed and not s.legacy then
			on_progress("done", "already installed")
			return s
		end
	elseif force and opts.vstuc_version and opts.vstuc_version ~= "" and opts.vstuc_version ~= "latest" then
		-- For pinned versions we can short-circuit when the local install already
		-- matches; "latest" still has to round-trip because we don't query the
		-- marketplace API for the resolved version.
		local installed_version = s.installed and not s.legacy
			and s.manifest and s.manifest.package and s.manifest.package.version
		if installed_version == opts.vstuc_version then
			on_progress("done", "already at version " .. opts.vstuc_version)
			return s
		end
	end

	ensure_dir(install_dir)
	local tmp_root = util.joinpath(tmp_dir(install_dir), "vstuc")
	-- Always start from a clean temp directory.
	await_rm_rf(tmp_root)
	tmp_root = ensure_dir(tmp_root)

	local pkg_name = util.is_windows() and "vstuc.zip" or "vstuc.vsix"
	local pkg_path = util.joinpath(tmp_root, pkg_name)
	local extract_root = util.joinpath(tmp_root, "extract")
	local stage_dir = util.joinpath(tmp_root, "stage")

	on_progress("download", step_msg(1, "Downloading vstuc package..."))
	local downloaded, err = await_download_file(opts.download_url, pkg_path)
	if not downloaded then
		return nil, err
	end

	on_progress("unzip", step_msg(2, "Extracting package..."))
	local extracted, unzip_err = await_unzip_package(pkg_path, extract_root)
	if not extracted then
		return nil, unzip_err
	end

	on_progress("validate", step_msg(3, "Validating files..."))
	-- VSIX usually contains an extension root; we keep the whole extracted tree and discover DLLs.
	ensure_dir(stage_dir)
	-- Move extracted into stage to make replace_dir_atomic easy.
	local moved = os.rename(extract_root, util.joinpath(stage_dir, "content"))
	if not moved then
		return nil, make_error(
			"permissions",
			"stage",
			"failed to move extracted files into staging directory",
			"ensure the install directory is writable",
			("from=%s to=%s"):format(extract_root, util.joinpath(stage_dir, "content"))
		)
	end

	local manifest = build_manifest(opts, install_dir, util.joinpath(stage_dir, "content"))
	local ok, validate_err = validate_manifest(manifest)
	if not ok then
		return nil, validate_err
	end

	-- Late short-circuit: when force=true and the freshly downloaded package
	-- carries the same version as the local install, skip the directory replace.
	-- Network was already spent (we'd need a marketplace API call to skip the
	-- download itself), but we avoid touching the live install dir, preserve the
	-- original installed_at timestamp, and give the user an honest "no change"
	-- message instead of a misleading "updated".
	if force and not s.legacy and s.installed
		and s.manifest and s.manifest.package and s.manifest.package.version
		and manifest.package and manifest.package.version
		and s.manifest.package.version == manifest.package.version
	then
		await_rm_rf(tmp_root)
		on_progress("done", "already at latest (" .. tostring(manifest.package.version) .. ")")
		s.no_change = true
		return s
	end

	-- Write manifest into stage content directory (final location will be vstuc_dir)
	local final_stage_dir = util.joinpath(stage_dir, "final")
	ensure_dir(final_stage_dir)
	-- Flatten to a stable layout: final_dir contains content/ + manifest.json
	local staged = os.rename(util.joinpath(stage_dir, "content"), util.joinpath(final_stage_dir, "content"))
	if not staged then
		return nil, make_error(
			"permissions",
			"stage",
			"failed to prepare final staging directory",
			"ensure the install directory is writable",
			("from=%s to=%s"):format(util.joinpath(stage_dir, "content"), util.joinpath(final_stage_dir, "content"))
		)
	end

	local write_ok, write_err = pcall(write_manifest, final_stage_dir, manifest)
	if not write_ok then
		return nil, make_error(
			"permissions",
			"manifest",
			"failed to write manifest.json",
			"ensure the install directory is writable",
			write_err
		)
	end

	on_progress("replace", step_msg(4, "Installing into final location..."))
	-- Replace final directory atomically
	local replaced, replace_err = await_replace_dir_atomic(final_stage_dir, vstuc_dir)
	if not replaced then
		return nil, replace_err
	end

	-- Rebuild manifest based on final install paths.
	local final_manifest = build_manifest(opts, install_dir, util.joinpath(vstuc_dir, "content"))
	local final_ok, final_validate_err = validate_manifest(final_manifest)
	if not final_ok then
		return nil, final_validate_err
	end
	local final_write_ok, final_write_err = pcall(write_manifest, vstuc_dir, final_manifest)
	if not final_write_ok then
		return nil, make_error(
			"permissions",
			"manifest",
			"failed to write manifest.json after install",
			"ensure the install directory is writable",
			final_write_err
		)
	end

	-- Clean up tmp content after a successful install.
	await_rm_rf(tmp_root)

	on_progress("done", "Installed")
	return M.status(opts)
end

local function spawn_install(opts, force, on_progress, on_done)
	on_progress = on_progress or noop
	on_done = on_done or noop

	local co = coroutine.create(function()
		local ok, status, err = xpcall(function()
			return do_install_co(opts, force, on_progress)
		end, debug.traceback)
		if not ok then
			-- xpcall propagates traceback string in `status` slot
			on_done(nil, make_error("internal", "install", "unexpected error", "please report this issue", tostring(status)))
		else
			on_done(status, err)
		end
	end)

	local ok, err = coroutine.resume(co)
	if not ok then
		on_done(nil, make_error("internal", "install", "failed to start install", "please report this issue", tostring(err)))
	end
end

function M.install_async(opts, on_progress, on_done)
	spawn_install(opts, false, on_progress, on_done)
end

function M.update_async(opts, on_progress, on_done)
	spawn_install(opts, true, on_progress, on_done)
end

return M

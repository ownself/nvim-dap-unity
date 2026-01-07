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
	if util.is_windows() then
		local r = util.system({ "where", cmd }, { timeout = 2000 })
		return r.code == 0 and r.stdout ~= ""
	end
	local r = util.system({ "sh", "-lc", "command -v " .. cmd }, { timeout = 2000 })
	return r.code == 0
end

local function download_file(url, out_path)
	ensure_dir(vim.fs.dirname(out_path))

	if util.is_windows() then
		local ps = table.concat({
			"$ErrorActionPreference = 'Stop'",
			("Invoke-WebRequest -Uri '%s' -OutFile '%s'"):format(url, out_path:gsub("'", "''")),
		}, "; ")
		local r = util.system({ "powershell", "-NoProfile", "-Command", ps }, { timeout = 120000 })
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

	local r = util.system({ "sh", "-lc", ("curl -fL --retry 2 --retry-delay 1 -o %q %q"):format(out_path, url) }, {
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

local function unzip_package(zip_path, out_dir)
	ensure_dir(out_dir)

	if util.is_windows() then
		local ps = table.concat({
			"$ErrorActionPreference = 'Stop'",
			("Expand-Archive -Path '%s' -DestinationPath '%s' -Force"):format(zip_path:gsub("'", "''"), out_dir:gsub("'", "''")),
		}, "; ")
		local r = util.system({ "powershell", "-NoProfile", "-Command", ps }, { timeout = 120000 })
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

	local r = util.system({ "sh", "-lc", ("unzip -o %q -d %q"):format(zip_path, out_dir) }, { timeout = 120000 })
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

local function rm_rf(path)
	if not path or path == "" then
		return
	end
	if util.is_windows() then
		util.system({ "powershell", "-NoProfile", "-Command", ("Remove-Item -LiteralPath '%s' -Recurse -Force -ErrorAction SilentlyContinue"):format(path:gsub("'", "''")) }, {
			timeout = 120000,
		})
		return
	end
	util.system({ "sh", "-lc", ("rm -rf %q"):format(path) }, { timeout = 120000 })
end

local function replace_dir_atomic(from_dir, to_dir)
	-- Best-effort atomic replace: move old aside, move new in.
	local backup = to_dir .. ".bak"
	rm_rf(backup)

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

	rm_rf(backup)
	return true
end

function M.status(opts)
	local install_dir = opts.install_dir
	local vstuc_dir = default_vstuc_dir(install_dir)
	local manifest = read_manifest(vstuc_dir)
	if not manifest then
		return {
			installed = false,
			install_dir = install_dir,
			vstuc_dir = vstuc_dir,
			bin_dir = nil,
			missing = { "manifest.json" },
			manifest = nil,
		}
	end

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

local function do_install(opts, force)
	local install_dir = opts.install_dir
	local vstuc_dir = default_vstuc_dir(install_dir)

	if not force then
		local s = M.status(opts)
		if s.installed then
			return s
		end
	end

	ensure_dir(install_dir)
	local tmp_root = util.joinpath(tmp_dir(install_dir), "vstuc")
	-- Always start from a clean temp directory.
	rm_rf(tmp_root)
	tmp_root = ensure_dir(tmp_root)

	local pkg_name = util.is_windows() and "vstuc.zip" or "vstuc.vsix"
	local pkg_path = util.joinpath(tmp_root, pkg_name)
	local extract_root = util.joinpath(tmp_root, "extract")
	local stage_dir = util.joinpath(tmp_root, "stage")

	local downloaded, err = download_file(opts.download_url, pkg_path)
	if not downloaded then
		return nil, err
	end

	local extracted, unzip_err = unzip_package(pkg_path, extract_root)
	if not extracted then
		return nil, unzip_err
	end

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

	local ok, write_err = pcall(write_manifest, final_stage_dir, manifest)
	if not ok then
		return nil, make_error(
			"permissions",
			"manifest",
			"failed to write manifest.json",
			"ensure the install directory is writable",
			write_err
		)
	end

	-- Replace final directory atomically
	local replaced, replace_err = replace_dir_atomic(final_stage_dir, vstuc_dir)
	if not replaced then
		return nil, replace_err
	end

	-- Rebuild manifest based on final install paths.
	local final_manifest = build_manifest(opts, install_dir, util.joinpath(vstuc_dir, "content"))
	local final_ok, final_validate_err = validate_manifest(final_manifest)
	if not final_ok then
		return nil, final_validate_err
	end
	local write_ok, final_write_err = pcall(write_manifest, vstuc_dir, final_manifest)
	if not write_ok then
		return nil, make_error(
			"permissions",
			"manifest",
			"failed to write manifest.json after install",
			"ensure the install directory is writable",
			final_write_err
		)
	end

	-- Clean up tmp content after a successful install.
	rm_rf(tmp_root)

	return M.status(opts)
end

function M.install(opts)
	return do_install(opts, false)
end

function M.update(opts)
	return do_install(opts, true)
end

return M

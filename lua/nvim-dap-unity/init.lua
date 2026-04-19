local util = require("nvim-dap-unity.util")
local installer = require("nvim-dap-unity.installer")
local dap_integration = require("nvim-dap-unity.dap")

local M = {}

local defaults = {
	vstuc_version = "latest",	-- marketplace version or "latest"
	download_url = nil,	-- if set, overrides vstuc_version URL
	install_dir = nil,	-- base dir (default: stdpath('data')/nvim-dap-unity)
	auto_setup_dap = true,	-- inject dap adapter if possible
	auto_install_on_start = false,	-- auto install vstuc if missing
	add_default_cs_configuration = false,	-- force: append dap.configurations.cs template
	auto_add_cs_configuration_if_missing = true,	-- default: add template only when cs configs missing
	enable_unity_cs_configuration = true,	-- default: append unity cs config even when cs configs exist
	-- backward compat
	ensure_unity_cs_configuration = nil,
}


local state = {
	opts = vim.deepcopy(defaults),
	last_error = nil,
	installing = false,
	updating = false,
}

local function resolve_install_dir(opts)
	if opts.install_dir and opts.install_dir ~= "" then
		return opts.install_dir, {}
	end

	local data = util.stdpath_data()
	local primary = util.joinpath(data, "nvim-dap-unity")
	-- Older versions of this plugin defaulted to the Lazy plugin directory when
	-- detected. We no longer write there (Lazy's git operations can wipe the
	-- subdir), but fall back to reading it so existing users don't have to
	-- re-download until their next :NvimDapUnityUpdate.
	local legacy = { util.joinpath(data, "lazy", "nvim-dap-unity") }
	return primary, legacy
end

local function build_download_url(opts)
	if opts.download_url and opts.download_url ~= "" then
		return opts.download_url
	end
	local version = opts.vstuc_version or "latest"
	if version == "" then
		version = "latest"
	end
	return (
		"https://marketplace.visualstudio.com/_apis/public/gallery/publishers/visualstudiotoolsforunity/vsextensions/vstuc/%s/vspackage"
	):format(version)
end

local function normalize_opts(opts)
	opts = opts or {}
	opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

	-- backward compat
	if opts.enable_unity_cs_configuration == nil and opts.ensure_unity_cs_configuration ~= nil then
		opts.enable_unity_cs_configuration = opts.ensure_unity_cs_configuration
	end

	opts.download_url = build_download_url(opts)
	local primary, legacy = resolve_install_dir(opts)
	opts.install_dir = primary
	opts.legacy_install_dirs = legacy
	return opts
end

local function ensure_opts()
	state.opts = normalize_opts(state.opts)
	return state.opts
end

function M.setup(opts)
	state.opts = normalize_opts(opts)

	local s = installer.status(state.opts)

	if state.opts.auto_install_on_start and not s.installed then
		vim.schedule(function()
			-- Auto-install on start — non-blocking, progress shown via vim.notify.
			if not state.installing then
				M.install_async()
			end
		end)
	end

	if state.opts.auto_setup_dap then
		local ok, err = dap_integration.setup(state.opts, s)
		if not ok and err and err ~= "nvim-dap not available" then
			vim.notify("nvim-dap-unity dap setup skipped: " .. tostring(err), vim.log.levels.DEBUG)
		end
	end

	return state.opts
end

local function error_level(err)
	if type(err) == "table" then
		if err.code == "missing_tool" then
			return vim.log.levels.WARN
		end
		if err.code == "validate_failed" then
			return vim.log.levels.ERROR
		end
		if err.code == "permissions" then
			return vim.log.levels.ERROR
		end
		if err.code == "download_failed" or err.code == "unzip_failed" then
			return vim.log.levels.ERROR
		end
	end
	return vim.log.levels.ERROR
end

local function format_error(err)
	if installer.format_error then
		return installer.format_error(err)
	end
	if type(err) == "table" then
		return vim.inspect(err)
	end
	return tostring(err)
end

local function set_last_error(err)
	local formatted = format_error(err)
	state.last_error = formatted
	return formatted
end

local function after_success(status, verb)
	state.last_error = nil
	if state.opts.auto_setup_dap then
		dap_integration.setup(state.opts, status)
	end
	vim.notify("nvim-dap-unity " .. verb, vim.log.levels.INFO)
	return status
end

-- Build a progress reporter that reuses one notification slot when the
-- backend supports it (nvim-notify: `replace`; snacks.notify: `id`). Plain
-- vim.notify falls back to multiple lines, which is acceptable.
local function make_progress_reporter()
	local notify_handle = nil
	return function(_stage, message)
		local opts = {
			title = "nvim-dap-unity",
			id = "nvim-dap-unity-install",
		}
		if notify_handle ~= nil then
			opts.replace = notify_handle
		end
		local handle = vim.notify(message, vim.log.levels.INFO, opts)
		if handle ~= nil then
			notify_handle = handle
		end
	end
end

local VERB_INFO = {
	install = { lock = "installing", past = "installed" },
	update = { lock = "updating", past = "updated" },
}

local function run(verb, runner)
	local info = VERB_INFO[verb]
	if state[info.lock] then
		vim.notify("nvim-dap-unity " .. verb .. " already running", vim.log.levels.INFO)
		return
	end
	state[info.lock] = true
	ensure_opts()

	local on_progress = make_progress_reporter()
	on_progress(verb, "Starting " .. verb .. "...")

	runner(state.opts, on_progress, function(status, err)
		state[info.lock] = false
		if not status then
			local msg = set_last_error(err)
			vim.notify("nvim-dap-unity " .. verb .. " failed: " .. msg, error_level(err))
			return
		end
		after_success(status, info.past)
	end)
end

-- Non-blocking install/update. Returns immediately; progress and result are
-- delivered via vim.notify. Used by `:NvimDapUnityInstall/Update` and by the
-- `auto_install_on_start` startup path so the UI is never frozen.
function M.install_async()
	run("install", installer.install_async)
end

function M.update_async()
	run("update", installer.update_async)
end

-- Blocking install/update intended for use as a Lazy `build` hook, where the
-- caller (Lazy) needs to know when the install actually finishes so its panel
-- shows real progress. Uses vim.wait so the event loop keeps pumping — this is
-- not a hard CPU block, vim.system callbacks still fire.
local function run_sync(verb, runner, timeout_ms)
	local info = VERB_INFO[verb]
	if state[info.lock] then
		vim.notify("nvim-dap-unity " .. verb .. " already running", vim.log.levels.INFO)
		return false
	end
	state[info.lock] = true
	ensure_opts()

	local on_progress = make_progress_reporter()
	on_progress(verb, "Starting " .. verb .. "...")

	local done, ok_result = false, false
	runner(state.opts, on_progress, function(status, err)
		state[info.lock] = false
		if not status then
			set_last_error(err)
			vim.notify(
				"nvim-dap-unity " .. verb .. " failed: " .. format_error(err),
				error_level(err)
			)
		else
			after_success(status, info.past)
			ok_result = true
		end
		done = true
	end)

	-- Default 5min timeout — vstuc download is the slow part.
	vim.wait(timeout_ms or 300000, function() return done end, 100)
	return ok_result
end

function M.install(timeout_ms)
	return run_sync("install", installer.install_async, timeout_ms)
end

function M.update(timeout_ms)
	return run_sync("update", installer.update_async, timeout_ms)
end


function M.status()
	ensure_opts()
	local status = installer.status(state.opts)
	status.download_url = state.opts.download_url
	status.vstuc_version = state.opts.vstuc_version
	status.last_error = state.last_error
	status.dap = {
		auto_install_on_start = state.opts.auto_install_on_start,
		auto_setup_dap = state.opts.auto_setup_dap,
		add_default_cs_configuration = state.opts.add_default_cs_configuration,
		auto_add_cs_configuration_if_missing = state.opts.auto_add_cs_configuration_if_missing,
		enable_unity_cs_configuration = state.opts.enable_unity_cs_configuration,
	}


	status.deps = {
		dotnet = util.tool_exists("dotnet"),
		powershell = util.is_windows() and util.tool_exists("powershell") or nil,
		curl = (not util.is_windows()) and util.tool_exists("curl") or nil,
		unzip = (not util.is_windows()) and util.tool_exists("unzip") or nil,
	}

	return status
end

return M

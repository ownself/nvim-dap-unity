local util = require("nvim-dap-unity.util")

local M = {}

-- dotnet cold start (NGEN/JIT, file cache miss) can take 3–5s. Keep this loose
-- enough to cover that on a fresh boot; warm runs typically finish in <500ms.
local PROBE_TIMEOUT_MS = 8000

local function get_dap()
	local ok, dap = pcall(require, "dap")
	if not ok then
		return nil
	end
	return dap
end

local function is_dotnet_available()
	local cmd = util.is_windows() and { "where", "dotnet" } or { "sh", "-lc", "command -v dotnet" }
	local r = util.system(cmd, { timeout = 2000 })
	return r.code == 0
end

local function is_non_empty_string(value)
	return type(value) == "string" and value ~= ""
end

local function ensure_table(value)
	if type(value) ~= "table" then
		return {}
	end
	return value
end

local function find_unity_project_root()
	local path = vim.fn.expand("%:p")
	if not path or path == "" then
		path = vim.fn.getcwd()
	end
	if not path or path == "" then
		return ""
	end

	path = vim.fs.dirname(path)
	while true do
		local parent = vim.fs.dirname(path)
		if not parent or parent == path then
			return ""
		end
		path = parent
		if util.is_dir(util.joinpath(path, "Assets")) then
			return path
		end
	end
end

local function endpoint_from_process(process)
	if type(process) ~= "table" then
		return nil
	end
	-- Asset import workers and other headless helpers are reported alongside the
	-- real Editor; attaching to one of those is never what the user wants.
	if process.isBackground ~= false then
		return nil
	end
	if process.isValidForAttachment == false then
		return nil
	end
	if not process.address or not process.debuggerPort then
		return nil
	end
	return tostring(process.address) .. ":" .. tostring(process.debuggerPort)
end

-- The probe speaks JSON-RPC, so targets live under params.processes. Older
-- assumptions about a bare array are still honoured.
local function endpoint_from_targets(decoded)
	local processes = decoded.params and decoded.params.processes
	if type(processes) ~= "table" then
		processes = decoded
	end

	for _, process in pairs(processes) do
		local endpoint = endpoint_from_process(process)
		if endpoint then
			return endpoint
		end
	end

	return nil
end

local function parse_probe_stdout(stdout)
	stdout = stdout or ""
	if stdout == "" then
		return ""
	end

	for line in vim.gsplit(stdout, "\n") do
		line = vim.trim(line)
		if line ~= "" then
			local ok, decoded = pcall(vim.json.decode, line)
			if ok and type(decoded) == "table" then
				local endpoint = endpoint_from_targets(decoded)
				if endpoint then
					return endpoint
				end
			elseif line:match("^%S+:%d+$") then
				return line
			end
		end
	end

	return ""
end

-- Run UnityAttachProbe.dll. Yields if called from a coroutine (nvim-dap evaluates
-- configuration values inside one), so the UI is not frozen while we wait.
-- Returns (endpoint, nil) on success, (nil, system_result) on failure.
local function probe_endpoint(probe_path)
	local co = coroutine.running()
	local state = { buffer = "", done = false }
	local proc

	local function finish(endpoint, err)
		if state.done then
			return
		end
		state.done = true
		state.endpoint = endpoint
		state.err = err

		if proc then
			pcall(function()
				proc:kill(15)
			end)
		end

		if co and coroutine.status(co) == "suspended" then
			coroutine.resume(co)
		end
	end

	local ok, err = pcall(function()
		proc = vim.system({ "dotnet", probe_path }, {
			text = true,
			stdout = function(_, data)
				if state.done or not data then
					return
				end
				state.buffer = state.buffer .. data
				local endpoint = parse_probe_stdout(state.buffer)
				if endpoint ~= "" then
					vim.schedule(function()
						finish(endpoint)
					end)
				end
			end,
		}, function(res)
			vim.schedule(function()
				finish(nil, {
					code = res.code or 1,
					stdout = state.buffer,
					stderr = res.stderr or "",
				})
			end)
		end)
	end)

	if not ok then
		return nil, { code = 127, stdout = "", stderr = tostring(err) }
	end

	vim.defer_fn(function()
		finish(nil, {
			code = 124,
			stdout = state.buffer,
			stderr = ("no attachable Unity target within %dms"):format(PROBE_TIMEOUT_MS),
		})
	end, PROBE_TIMEOUT_MS)

	if co then
		if not state.done then
			coroutine.yield()
		end
	else
		vim.wait(PROBE_TIMEOUT_MS + 500, function()
			return state.done
		end, 50)
	end

	if state.endpoint then
		return state.endpoint
	end

	return nil, state.err or { code = 1, stdout = state.buffer, stderr = "" }
end

function M.ensure_adapter(status)
	local dap = get_dap()
	if not dap then
		return false, "nvim-dap not available"
	end

	dap.adapters = ensure_table(dap.adapters)

	if dap.adapters.unity then
		return true
	end

	if not status or not status.installed or not is_non_empty_string(status.bin_dir) then
		return false, "vstuc not installed; run :NvimDapUnityInstall"
	end

	if not is_dotnet_available() then
		return false, "dotnet not found in PATH"
	end

	dap.adapters.unity = {
		type = "executable",
		command = "dotnet",
		args = { util.joinpath(status.bin_dir, "UnityDebugAdapter.dll") },
		name = "Attach to Unity",
	}

	return true
end

local function has_configuration(configs, name)
	configs = ensure_table(configs)
	for _, cfg in ipairs(configs) do
		if type(cfg) == "table" and cfg.name == name then
			return true
		end
	end
	return false
end

local function is_empty_list(value)
	if type(value) ~= "table" then
		return true
	end
	return next(value) == nil
end

function M.add_default_cs_configuration(status)
	local dap = get_dap()
	if not dap then
		return false, "nvim-dap not available"
	end

	if not status or not status.installed or not is_non_empty_string(status.bin_dir) then
		return false, "vstuc not installed; run :NvimDapUnityInstall"
	end

	dap.configurations = ensure_table(dap.configurations)
	dap.configurations.cs = ensure_table(dap.configurations.cs)

	local config_name = "Attach to Unity"
	if has_configuration(dap.configurations.cs, config_name) then
		return true
	end

	local probe_path = util.joinpath(status.bin_dir, "UnityAttachProbe.dll")
	local has_probe = util.is_file(probe_path)

	local cfg = {
		type = "unity",
		name = config_name,
		request = "attach",
		logFile = util.joinpath(util.stdpath_data(), "vstuc.log"),
		projectPath = function()
			return find_unity_project_root()
		end,
		endPoint = function()
			local endpoint, probe_err

			-- Try UnityAttachProbe first (works on Windows/macOS, and on Linux when
			-- the probe binary is present). Runs async via coroutine yield, so the
			-- UI stays responsive while dotnet warms up.
			if has_probe then
				endpoint, probe_err = probe_endpoint(probe_path)
			end

			-- Fallback: scan listening ports on Linux when probe didn't yield a hit.
			if not endpoint and util.is_linux() then
				local linux_ep = util.find_unity_endpoint_linux()
				if linux_ep ~= "" then
					endpoint = linux_ep
				end
			end

			if endpoint then
				return endpoint
			end

			-- Surface a clear error to the user instead of returning an empty string,
			-- which would otherwise let nvim-dap try to connect to a bogus address
			-- and produce a confusing low-level failure.
			local msg
			if not has_probe then
				msg = "nvim-dap-unity: UnityAttachProbe.dll not found. Run :NvimDapUnityInstall, "
					.. "or set this configuration's `endPoint` manually."
			else
				msg = "nvim-dap-unity: No Unity instance detected. "
					.. "Make sure Unity Editor is running with this project open."
				if probe_err and probe_err.stderr and probe_err.stderr ~= "" then
					msg = msg .. " (probe: " .. vim.trim(probe_err.stderr) .. ")"
				end
			end
			vim.notify(msg, vim.log.levels.ERROR)
			error(msg, 0)
		end,
	}

	table.insert(dap.configurations.cs, cfg)
	return true
end

function M.setup(opts, status)
	opts = opts or {}
	if opts.auto_setup_dap == false then
		return false
	end

	local ok, err = M.ensure_adapter(status)
	if not ok then
		return false, err
	end

	local should_add = false
	if opts.add_default_cs_configuration then
		should_add = true
	elseif opts.enable_unity_cs_configuration then
		should_add = true
	elseif opts.auto_add_cs_configuration_if_missing ~= false then
		local dap = get_dap()
		if dap then
			local cs = dap.configurations and dap.configurations.cs
			should_add = cs == nil or is_empty_list(cs)
		end
	end

	if should_add then
		local cfg_ok, cfg_err = M.add_default_cs_configuration(status)
		if not cfg_ok then
			return false, cfg_err
		end
	end

	return true
end

return M

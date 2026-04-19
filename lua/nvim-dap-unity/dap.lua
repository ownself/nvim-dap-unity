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
				for _, p in pairs(decoded) do
					if type(p) == "table" and p.isBackground == false then
						if p.address and p.debuggerPort then
							return tostring(p.address) .. ":" .. tostring(p.debuggerPort)
						end
					end
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
	local res
	if co then
		util.system_async({ "dotnet", probe_path }, { timeout = PROBE_TIMEOUT_MS }, function(r)
			coroutine.resume(co, r)
		end)
		res = coroutine.yield()
	else
		res = util.system({ "dotnet", probe_path }, { timeout = PROBE_TIMEOUT_MS })
	end
	if res.code ~= 0 then
		return nil, res
	end
	local endpoint = parse_probe_stdout(res.stdout)
	if endpoint == "" then
		return nil, res
	end
	return endpoint
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
			if not endpoint and not util.is_windows() then
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

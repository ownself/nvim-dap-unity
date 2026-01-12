local util = require("nvim-dap-unity.util")

local M = {}

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
			local endpoint = ""

			-- Try UnityAttachProbe first (works on Windows/macOS)
			if has_probe then
				local r = util.system({ "dotnet", probe_path }, { timeout = 2000 })
				if r.code == 0 then
					endpoint = parse_probe_stdout(r.stdout)
				end
			end

			-- Fallback: scan ports on Linux if UnityAttachProbe didn't find anything
			if endpoint == "" and not util.is_windows() then
				endpoint = util.find_unity_endpoint_linux()
			end

			if endpoint == "" then
				if not has_probe then
					vim.notify(
						"nvim-dap-unity: UnityAttachProbe.dll not found and no Unity instance detected. "
							.. "Please set dap.configurations.cs[].endPoint manually.",
						vim.log.levels.WARN
					)
				else
					vim.notify("nvim-dap-unity: No endpoint found (is Unity running?)", vim.log.levels.WARN)
				end
			end
			return endpoint
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

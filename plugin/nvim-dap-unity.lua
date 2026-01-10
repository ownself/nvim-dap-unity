vim.api.nvim_create_user_command("NvimDapUnityInstall", function()
	require("nvim-dap-unity").install()
end, {})

vim.api.nvim_create_user_command("NvimDapUnityUpdate", function()
	require("nvim-dap-unity").update()
end, {})

vim.api.nvim_create_user_command("NvimDapUnityStatus", function()
	local s = require("nvim-dap-unity").status()
	local lines = {
		("installed: %s"):format(tostring(s.installed)),
		("install_dir: %s"):format(tostring(s.install_dir)),
		("vstuc_version: %s"):format(tostring(s.vstuc_version)),
		("download_url: %s"):format(tostring(s.download_url)),
	}
	if s.bin_dir then
		table.insert(lines, ("bin_dir: %s"):format(tostring(s.bin_dir)))
	end
	if s.last_error then
		table.insert(lines, ("last_error: %s"):format(tostring(s.last_error)))
	end
	if s.deps then
		table.insert(lines, "deps:")
		if s.deps.dotnet ~= nil then
			table.insert(lines, "  - dotnet: " .. tostring(s.deps.dotnet))
		end
		if s.deps.powershell ~= nil then
			table.insert(lines, "  - powershell: " .. tostring(s.deps.powershell))
		end
		if s.deps.curl ~= nil then
			table.insert(lines, "  - curl: " .. tostring(s.deps.curl))
		end
		if s.deps.unzip ~= nil then
			table.insert(lines, "  - unzip: " .. tostring(s.deps.unzip))
		end
	end
	if s.missing and #s.missing > 0 then
		table.insert(lines, "missing:")
		for _, item in ipairs(s.missing) do
			table.insert(lines, "  - " .. item)
		end
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, {})

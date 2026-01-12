local M = {}

local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

function M.is_windows()
	return is_windows
end

function M.joinpath(...)
	return vim.fs.joinpath(...)
end

function M.stdpath_data()
	return vim.fn.stdpath("data")
end

function M.is_dir(path)
	local stat = vim.uv.fs_stat(path)
	return stat ~= nil and stat.type == "directory"
end

function M.is_file(path)
	local stat = vim.uv.fs_stat(path)
	return stat ~= nil and stat.type == "file"
end

function M.mkdirp(path)
	vim.fn.mkdir(path, "p")
end

local function normalize_system_output(result)
	local code = result.code or 1
	local stdout = result.stdout or ""
	local stderr = result.stderr or ""

	if type(stdout) == "table" then
		stdout = table.concat(stdout, "")
	end
	if type(stderr) == "table" then
		stderr = table.concat(stderr, "")
	end

	return {
		code = code,
		stdout = stdout,
		stderr = stderr,
	}
end

function M.system(cmd, opts)
	opts = opts or {}
	opts.text = true

	local proc = vim.system(cmd, opts)
	local result = proc:wait(opts.timeout)
	return normalize_system_output(result)
end

function M.json_decode(text)
	return vim.json.decode(text)
end

function M.json_encode(value)
	return vim.json.encode(value)
end

function M.read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

function M.write_file_atomic(path, content)
	local dir = vim.fs.dirname(path)
	if dir and dir ~= "" then
		M.mkdirp(dir)
	end

	local tmp = path .. ".tmp"
	local f = assert(io.open(tmp, "wb"))
	f:write(content)
	f:close()

	os.remove(path)
	assert(os.rename(tmp, path))
end

function M.tool_exists(cmd)
	if M.is_windows() then
		local r = M.system({ "where", cmd }, { timeout = 2000 })
		return r.code == 0 and r.stdout ~= ""
	end
	local r = M.system({ "sh", "-lc", "command -v " .. cmd }, { timeout = 2000 })
	return r.code == 0
end

--- Find Unity debugger endpoint on Linux by scanning listening ports.
--- Unity typically listens on ports in the 56xxx range for debugging.
--- @return string endpoint in "host:port" format, or empty string if not found
function M.find_unity_endpoint_linux()
	if M.is_windows() then
		return ""
	end

	-- Try ss first (modern Linux), then netstat
	local ss_result = M.system({ "ss", "-tlnp" }, { timeout = 2000 })
	local output = ""
	if ss_result.code == 0 then
		output = ss_result.stdout
	else
		local netstat_result = M.system({ "netstat", "-tlnp" }, { timeout = 2000 })
		if netstat_result.code == 0 then
			output = netstat_result.stdout
		end
	end

	if output == "" then
		return ""
	end

	-- Parse output looking for Unity.bin or Unity listening on ports 56xxx-57xxx
	-- ss output format: tcp LISTEN 0 16 127.0.0.1:56784 0.0.0.0:* users:(("Unity.bin",pid=9784,fd=138))
	-- netstat format:   tcp 0 0 127.0.0.1:56784 0.0.0.0:* LISTEN 9784/Unity.bin
	for line in vim.gsplit(output, "\n") do
		-- Check if line contains Unity process
		local is_unity = line:match("Unity%.bin") or line:match("Unity")
		if is_unity then
			-- Extract port from the listening address
			-- Match patterns like 127.0.0.1:56784 or [::1]:56784 or *:56784
			local host, port = line:match("(%d+%.%d+%.%d+%.%d+):(%d+)")
			if not port then
				-- Try IPv6 or wildcard format
				port = line:match("%*:(%d+)")
				if port then
					host = "127.0.0.1"
				end
			end

			if port then
				local port_num = tonumber(port)
				-- Unity debugger ports are typically in the 56xxx-57xxx range
				if port_num and port_num >= 56000 and port_num <= 57999 then
					return (host or "127.0.0.1") .. ":" .. port
				end
			end
		end
	end

	return ""
end

return M

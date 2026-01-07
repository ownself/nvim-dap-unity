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

return M

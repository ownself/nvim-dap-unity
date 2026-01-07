# nvim-dap-unity

## English

### Overview

`nvim-dap-unity` is a Neovim plugin that:

- Downloads and installs Unity’s `vstuc` debug adapter (VSIX/vspackage) into your Neovim data directory.
- Integrates with `mfussenegger/nvim-dap` by injecting:
  - `dap.adapters.unity` (only if you didn’t define it yourself)
  - a default `dap.configurations.cs` entry for “Attach to Unity” (merge-friendly)

This plugin does **not** bundle `nvim-dap`; you install `nvim-dap` yourself.

### Requirements

- Neovim 0.10+
- `dotnet` in PATH
- On Windows: `powershell` (for download/unzip)
- On Linux/macOS: `curl` + `unzip`

### Installation (lazy.nvim)

#### Install as a standalone plugin

```lua
{
  "ownself/nvim-dap-unity",
  dependencies = { "mfussenegger/nvim-dap" },
  config = function()
    require("nvim-dap-unity").setup({})
  end,
}
```

#### Install as a dependency of nvim-dap (recommended)

If you already configure everything under `mfussenegger/nvim-dap`, put `nvim-dap-unity` inside `dependencies` and use `build` to install the Unity debug adapter during `:Lazy sync` / `:Lazy install`.

```lua
return {
  "mfussenegger/nvim-dap",
  dependencies = {
    "nvim-neotest/nvim-nio",
    "rcarriga/nvim-dap-ui",
    {
      "ownself/nvim-dap-unity",
      build = function()
        require("nvim-dap-unity").install()
      end,
      opts = {
        auto_install_on_start = false,
      },
    },
  },
  config = function()
    require("dapui").setup()
  end,
}
```

Note: if you set `dap.configurations.cs = { ... }` in your own config, it will overwrite configurations appended by this plugin. Prefer `dap.configurations.cs = dap.configurations.cs or {}` + `table.insert(...)`, or call `require("nvim-dap-unity").setup()` after your DAP configuration code.

### How it works with your existing `nvim-dap` config

- Adapter injection is safe:
  - If `dap.adapters.unity` already exists, the plugin will not overwrite it.
- C# configurations are merge-friendly:
  - The plugin appends a configuration named `Attach to Unity` to `dap.configurations.cs`.
  - If a configuration with the same `name` already exists, it will not add a duplicate.

### Default options

```lua
require("nvim-dap-unity").setup({
  -- Download
  vstuc_version = "latest", -- or a fixed version for vstuc/<version>/vspackage
  download_url = nil, -- if set, overrides vstuc_version URL

  -- Install location
  install_dir = nil, -- default: stdpath('data')/lazy/nvim-dap-unity (when lazy detected)

  -- Behavior
  auto_install_on_start = false, -- default: auto install if missing
  auto_setup_dap = true, -- default: inject dap adapter/config

  -- DAP configuration injection
  add_default_cs_configuration = false, -- force append "Attach to Unity" template
  auto_add_cs_configuration_if_missing = true, -- auto add only when cs configs are missing
  enable_unity_cs_configuration = true, -- also append when cs configs already exist

  -- Backward compatibility
  -- ensure_unity_cs_configuration = true,
})
```

### Commands

- `:NvimDapUnityInstall` — Install/repair `vstuc`
- `:NvimDapUnityUpdate` — Force reinstall/update
- `:NvimDapUnityStatus` — Show status, paths, and dependency checks

---

## 中文

### 简介

`nvim-dap-unity` 是一个 Neovim 插件，用于：

- 自动下载并安装 Unity 的 `vstuc` 调试适配器（VSIX/vspackage），安装到 Neovim 的 data 目录下。
- 与 `mfussenegger/nvim-dap` 集成：
  - 注入 `dap.adapters.unity`（仅当用户未自定义时）
  - 以“合并、不覆盖”的方式向 `dap.configurations.cs` 追加 `Attach to Unity` 配置

本插件 **不会**自动安装 `nvim-dap`，需要你自行安装 `mfussenegger/nvim-dap`。

### 依赖

- Neovim 0.10+
- PATH 中可用的 `dotnet`
- Windows: `powershell`（用于下载/解压）
- Linux/macOS: `curl` + `unzip`

### 安装（lazy.nvim）

#### 作为独立插件安装

```lua
{
  "ownself/nvim-dap-unity",
  dependencies = { "mfussenegger/nvim-dap" },
  config = function()
    require("nvim-dap-unity").setup({})
  end,
}
```

#### 作为 nvim-dap 的依赖安装（推荐）

如果你习惯把 DAP 相关的配置都放在 `mfussenegger/nvim-dap` 下面，可以把 `nvim-dap-unity` 写到 `dependencies` 里，并通过 `build` 在 `:Lazy sync` / `:Lazy install` 时完成 Unity 调试适配器的安装。

```lua
return {
  "mfussenegger/nvim-dap",
  dependencies = {
    "nvim-neotest/nvim-nio",
    "rcarriga/nvim-dap-ui",
    {
      "ownself/nvim-dap-unity",
      build = function()
        require("nvim-dap-unity").install()
      end,
      opts = {
        auto_install_on_start = false,
      },
    },
  },
  config = function()
    require("dapui").setup()
  end,
}
```

注意：如果你在自己的配置里写了 `dap.configurations.cs = { ... }`（整表赋值），会把本插件追加进去的配置覆盖掉。建议改成 `dap.configurations.cs = dap.configurations.cs or {}` 再 `table.insert(...)`，或者把 `require("nvim-dap-unity").setup()` 放到你 DAP 配置代码之后执行。

### 与你现有的 `nvim-dap` 配置的关系

- adapter 注入不会破坏用户配置：
  - 如果用户已定义 `dap.adapters.unity`，插件不会覆盖。
- C# 配置以合并方式追加：
  - 会向 `dap.configurations.cs` 追加名为 `Attach to Unity` 的配置。
  - 若已存在同名配置，则不会重复追加。

### 默认参数

```lua
require("nvim-dap-unity").setup({
  -- 下载
  vstuc_version = "latest", -- 也可以指定具体版本（vstuc/<version>/vspackage）
  download_url = nil, -- 若设置则优先使用该 URL

  -- 安装目录
  install_dir = nil, -- 默认：检测到 lazy 时为 stdpath('data')/lazy/nvim-dap-unity

  -- 行为
  auto_install_on_start = false, -- 默认：首次启动若未安装则自动安装
  auto_setup_dap = true, -- 默认：自动注入 dap adapter/config

  -- DAP 配置注入策略
  add_default_cs_configuration = false, -- 强制追加 "Attach to Unity" 模板
  auto_add_cs_configuration_if_missing = true, -- 仅当 cs 配置不存在时自动追加
  enable_unity_cs_configuration = true, -- 即使已有 cs 配置也追加（合并，不覆盖）

  -- 兼容旧字段名
  -- ensure_unity_cs_configuration = true,
})
```

### 命令

- `:NvimDapUnityInstall`：安装/修复适配器
- `:NvimDapUnityUpdate`：强制重装/更新
- `:NvimDapUnityStatus`：查看安装状态、关键路径与依赖检查

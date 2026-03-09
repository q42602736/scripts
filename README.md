# scripts

用于给 `XBoard` / `V2Board` 面板一键应用“专用客服端模式”补丁脚本。

当前脚本：

- `panel_patch.sh`

## 功能说明

脚本会交互式完成以下操作：

- 选择要修改的面板类型：`XBoard` / `V2Board`
- 自动扫描宝塔常见目录，优先列出 `/www/wwwroot` 下的候选站点目录；如果终端支持交互，可用上下键选择；也支持手动输入项目根目录
- 备份目标文件 `ClientController.php`
- 自动写入“专用客服端模式”相关补丁
- `XBoard` 会额外移除“过滤掉X条线路”的伪节点提示
- 可选执行 Laravel 缓存清理

## 运行环境

服务器需要具备以下命令：

- `bash`
- `php`
- `curl` 或 `wget`

## 服务器一键运行

### 方式一：直接远程执行（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/q42602736/scripts/main/panel_patch.sh)
```

如果服务器没有 `curl`，可以使用：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/q42602736/scripts/main/panel_patch.sh)
```

### 方式二：先下载，再执行

```bash
curl -fsSL https://raw.githubusercontent.com/q42602736/scripts/main/panel_patch.sh -o panel_patch.sh
bash panel_patch.sh
```

或：

```bash
wget -O panel_patch.sh https://raw.githubusercontent.com/q42602736/scripts/main/panel_patch.sh
bash panel_patch.sh
```

## 使用流程

运行脚本后，按提示操作：

1. 选择面板类型
2. 使用上下键选择自动扫描到的站点目录，或手动输入面板根目录
3. 确认是否执行 Laravel 缓存清理
4. 如线上仍未生效，手动重载 `PHP-FPM` 或重启容器刷新 `OPcache`

## 宝塔面板说明

宝塔常见项目目录一般为：

- `/www/wwwroot/你的站点目录`

脚本会优先扫描这些目录：

- `/www/wwwroot`
- `/www/server/panel/vhost`
- `/home/wwwroot`
- `/data/wwwroot`
- 当前目录
- 当前用户家目录

如果没有扫描到目标项目，直接手动输入项目根目录即可。

## 备份说明

脚本修改前会自动生成备份文件，格式如下：

```bash
ClientController.php.bak.20260309_163000
```

如果补丁后需要恢复，可直接用备份文件覆盖原文件。

## 注意事项

- 脚本按常见原始文件结构打补丁
- 如果目标文件被深度二次修改，脚本可能提示“未找到补丁锚点”并停止，这属于保护机制
- Laravel 缓存清理不等于 `OPcache` 清理
- 如果代码已变更但页面仍未生效，请重载 `PHP-FPM`

## 本地运行

仓库克隆到本地后，也可以直接执行：

```bash
bash panel_patch.sh
```

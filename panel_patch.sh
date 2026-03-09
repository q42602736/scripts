#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() {
  printf '%s\n' "$*"
}

fail() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

require_php() {
  command -v php >/dev/null 2>&1 || fail '未找到 php 命令，请先安装 PHP CLI 后再运行。'
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local suffix='[Y/n]'
  if [ "$default" = "n" ]; then
    suffix='[y/N]'
  fi
  while true; do
    printf '%s %s ' "$prompt" "$suffix"
    read -r answer || true
    answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
    if [ -z "$answer" ]; then
      answer="$default"
    fi
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) log '请输入 y 或 n。' ;;
    esac
  done
}

choose_panel() {
  log ''
  log '请选择要修改的面板：'
  log '  1) XBoard'
  log '  2) V2Board'
  log '  3) 全部'
  while true; do
    printf '请输入序号 [1-3]: '
    read -r choice || true
    case "$choice" in
      1) PANEL_CHOICE='xboard'; return ;;
      2) PANEL_CHOICE='v2board'; return ;;
      3) PANEL_CHOICE='all'; return ;;
      *) log '输入无效，请重新输入。' ;;
    esac
  done
}

collect_candidates() {
  local panel="$1"
  local marker='app/Http/Controllers/V1/Client/ClientController.php'
  local -a roots=(
    "$PWD"
    "/www/wwwroot"
    "/www/server/panel/vhost"
    "/home/wwwroot"
    "$HOME"
    "/data/wwwroot"
  )
  local result=''
  local root file base

  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      base=${file%/$marker}
      [ -f "$base/artisan" ] || continue
      [ -f "$base/app/Protocols/ClashMeta.php" ] || continue
      case "$panel" in
        xboard)
          if [ -f "$base/app/Support/ProtocolManager.php" ]; then
            result+="$base"$'\n'
          fi
          ;;
        v2board)
          if [ ! -f "$base/app/Support/ProtocolManager.php" ]; then
            result+="$base"$'\n'
          fi
          ;;
      esac
    done < <(find "$root" -maxdepth 5 -type f -path "*/$marker" 2>/dev/null)
  done

  printf '%s' "$result" | awk 'NF && !seen[$0]++'
}

choose_root() {
  local panel="$1"
  local candidates raw_count index selected
  candidates=$(collect_candidates "$panel")
  raw_count=$(printf '%s\n' "$candidates" | awk 'NF{count++} END{print count+0}')

  if [ "$raw_count" -gt 0 ]; then
    log ''
    log "检测到以下 ${panel} 目录："
    index=1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      log "  ${index}) ${line}"
      index=$((index + 1))
    done <<< "$candidates"
    log "  ${index}) 手动输入路径"

    while true; do
      printf '请选择目录序号: '
      read -r selected || true
      if [[ "$selected" =~ ^[0-9]+$ ]]; then
        if [ "$selected" -ge 1 ] && [ "$selected" -le "$raw_count" ]; then
          ROOT_PATH=$(printf '%s\n' "$candidates" | awk 'NF' | sed -n "${selected}p")
          return
        fi
        if [ "$selected" -eq "$index" ]; then
          break
        fi
      fi
      log '输入无效，请重新输入。'
    done
  fi

  while true; do
    printf '请输入 %s 项目根目录: ' "$panel"
    read -r ROOT_PATH || true
    [ -n "$ROOT_PATH" ] || { log '路径不能为空。'; continue; }
    [ -f "$ROOT_PATH/app/Http/Controllers/V1/Client/ClientController.php" ] || {
      log '未找到 app/Http/Controllers/V1/Client/ClientController.php，请确认路径。'
      continue
    }
    [ -f "$ROOT_PATH/app/Protocols/ClashMeta.php" ] || {
      log '未找到 app/Protocols/ClashMeta.php，请确认路径。'
      continue
    }
    [ -f "$ROOT_PATH/artisan" ] || {
      log '未找到 artisan，请确认这是 Laravel 面板根目录。'
      continue
    }
    return
  done
}

backup_file() {
  local file="$1"
  local backup_path="${file}.bak.${TIMESTAMP}"
  cp "$file" "$backup_path"
  log "已备份：$backup_path"
}

apply_patch_by_php() {
  local panel="$1"
  local file="$2"
  php - "$panel" "$file" <<'PHP'
<?php
$panel = $argv[1] ?? '';
$file = $argv[2] ?? '';
$code = @file_get_contents($file);
if ($code === false) {
    fwrite(STDERR, "读取文件失败：{$file}\n");
    exit(1);
}

function replace_once_or_fail(string $code, string $search, string $replace, string $label): string
{
    $pos = strpos($code, $search);
    if ($pos === false) {
        fwrite(STDERR, "未找到补丁锚点：{$label}\n");
        exit(2);
    }
    return substr($code, 0, $pos) . $replace . substr($code, $pos + strlen($search));
}

if ($panel === 'v2board') {
    if (strpos($code, 'private const EXCLUSIVE_CLIENT_FLAGS') !== false && strpos($code, '$protocolFlag = $flag;') !== false) {
        echo "already_patched\n";
        exit(0);
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
class ClientController extends Controller
{
    public function subscribe(Request $request)
CODE,
        <<<'CODE'
class ClientController extends Controller
{
    /**
     * 专用客户端标识列表
     * 只有匹配这些标识的客户端才能获取带 exclusive 标签的节点
     */
    private const EXCLUSIVE_CLIENT_FLAGS = [
        'xboardmihomo',  // 专用客户端标识
    ];

    /**
     * 专用节点标签名
     */
    private const EXCLUSIVE_TAG = '客服端专用';

    public function subscribe(Request $request)
CODE,
        'v2board-class-header'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
        $flag = strtolower($flag);
        $user = $request->user;
CODE,
        <<<'CODE'
        $flag = strtolower($flag);
        $protocolFlag = $flag;
        $user = $request->user;
CODE,
        'v2board-protocol-flag'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
            $servers = $serverService->getAvailableServers($user);
            if($flag) {
                if (!strpos($flag, 'sing')) {
                    $this->setSubscribeInfoToServers($servers, $user);
                    foreach (array_reverse(glob(app_path('Protocols') . '/*.php')) as $file) {
                        $file = 'App\\Protocols\\' . basename($file, '.php');
                        $class = new $file($user, $servers);
                        if (strpos($flag, $class->flag) !== false) {
                            return $class->handle();
                        }
                    }
                }
                if (strpos($flag, 'sing') !== false) {
                    $version = null;
                    if (preg_match('/sing-box\s+([0-9.]+)/i', $flag, $matches)) {
CODE,
        <<<'CODE'
            $servers = $serverService->getAvailableServers($user);

            // 根据客户端类型过滤节点
            if ($this->isExclusiveClient($flag)) {
                // 专用客户端：只获取带"客服端专用"标签的节点
                $servers = $this->filterToExclusiveServersOnly($servers);
                // 专用客户端仍需走 ClashMeta 协议生成 YAML 配置
                if (strpos($protocolFlag, 'meta') === false) {
                    $protocolFlag .= '|meta';
                }
            } else {
                // 普通客户端：过滤掉带"客服端专用"标签的节点
                $servers = $this->filterExclusiveServers($servers);
            }
            if($protocolFlag) {
                if (strpos($protocolFlag, 'sing') === false) {
                    $this->setSubscribeInfoToServers($servers, $user);
                    foreach (array_reverse(glob(app_path('Protocols') . '/*.php')) as $file) {
                        $file = 'App\\Protocols\\' . basename($file, '.php');
                        $class = new $file($user, $servers);
                        // 支持多个 flag，用 | 分隔
                        $flags = explode('|', $class->flag);
                        foreach ($flags as $classFlag) {
                            if (strpos($protocolFlag, trim($classFlag)) !== false) {
                                return $class->handle();
                            }
                        }
                    }
                }
                if (strpos($protocolFlag, 'sing') !== false) {
                    $version = null;
                    if (preg_match('/sing-box\s+([0-9.]+)/i', $protocolFlag, $matches)) {
CODE,
        'v2board-subscribe-core'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
        array_unshift($servers, array_merge($servers[0], [
            'name' => "剩余流量：{$remainingTraffic}",
        ]));
    }
}
CODE,
        <<<'CODE'
        array_unshift($servers, array_merge($servers[0], [
            'name' => "剩余流量：{$remainingTraffic}",
        ]));
    }

    /**
     * 检查是否是专用客户端
     *
     * @param string $flag User-Agent 标识
     * @return bool
     */
    private function isExclusiveClient(string $flag): bool
    {
        $exclusiveFlags = self::EXCLUSIVE_CLIENT_FLAGS;

        foreach ($exclusiveFlags as $exclusiveFlag) {
            if (stripos($flag, $exclusiveFlag) !== false) {
                return true;
            }
        }

        return false;
    }

    /**
     * 过滤掉专用节点（带"客服端专用"标签的节点）
     * 用于普通客户端
     *
     * @param array $servers 服务器列表
     * @return array 过滤后的服务器列表
     */
    private function filterExclusiveServers(array $servers): array
    {
        $exclusiveTag = self::EXCLUSIVE_TAG;

        return array_values(array_filter($servers, function ($server) use ($exclusiveTag) {
            $tags = $server['tags'] ?? [];
            if (is_string($tags)) {
                $tags = json_decode($tags, true) ?? [];
            }
            return !in_array($exclusiveTag, $tags);
        }));
    }

    /**
     * 只保留专用节点（带"客服端专用"标签的节点）
     * 用于专用客户端
     *
     * @param array $servers 服务器列表
     * @return array 过滤后的服务器列表
     */
    private function filterToExclusiveServersOnly(array $servers): array
    {
        $exclusiveTag = self::EXCLUSIVE_TAG;

        return array_values(array_filter($servers, function ($server) use ($exclusiveTag) {
            $tags = $server['tags'] ?? [];
            if (is_string($tags)) {
                $tags = json_decode($tags, true) ?? [];
            }
            return in_array($exclusiveTag, $tags);
        }));
    }
}
CODE,
        'v2board-helper-methods'
    );

    file_put_contents($file, $code);
    echo "patched\n";
    exit(0);
}

if ($panel === 'xboard') {
    if (strpos($code, 'private const EXCLUSIVE_CLIENT_FLAGS') !== false && strpos($code, 'ClashMeta::class') !== false) {
        echo "already_patched\n";
        exit(0);
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
use App\Http\Controllers\Controller;
use App\Models\Server;
use App\Protocols\General;
CODE,
        <<<'CODE'
use App\Http\Controllers\Controller;
use App\Models\Server;
use App\Protocols\ClashMeta;
use App\Protocols\General;
CODE,
        'xboard-import'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
class ClientController extends Controller
{
    /**
     * Protocol prefix mapping for server names
CODE,
        <<<'CODE'
class ClientController extends Controller
{
    /**
     * 专用客户端标识
     */
    private const EXCLUSIVE_CLIENT_FLAGS = [
        'xboardmihomo',
    ];

    /**
     * 专用节点标签
     */
    private const EXCLUSIVE_TAG = '客服端专用';

    /**
     * Protocol prefix mapping for server names
CODE,
        'xboard-class-header'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
        $clientInfo = $this->getClientInfo($request);

        $requestedTypes = $this->parseRequestedTypes($request->input('types'));
        $filterKeywords = $this->parseFilterKeywords($request->input('filter'));

        $protocolClassName = app('protocols.manager')->matchProtocolClassName($clientInfo['flag'])
            ?? General::class;

        $serversFiltered = $this->filterServers(
            servers: $servers,
            allowedTypes: $requestedTypes,
            filterKeywords: $filterKeywords
        );
CODE,
        <<<'CODE'
        $clientInfo = $this->getClientInfo($request);
        $isExclusiveClient = $this->isExclusiveClient($clientInfo['flag']);

        $requestedTypes = $this->parseRequestedTypes($request->input('types'));
        $filterKeywords = $this->parseFilterKeywords($request->input('filter'));

        $protocolClassName = $isExclusiveClient
            ? ClashMeta::class
            : (app('protocols.manager')->matchProtocolClassName($clientInfo['flag']) ?? General::class);

        $serversFiltered = $this->filterServers(
            servers: $servers,
            allowedTypes: $requestedTypes,
            filterKeywords: $filterKeywords,
            exclusiveOnly: $isExclusiveClient,
            excludeExclusive: !$isExclusiveClient
        );
CODE,
        'xboard-doSubscribe-core'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
    private function filterServers(array $servers, array $allowedTypes, ?array $filterKeywords): array
    {
        return collect($servers)->filter(function ($server) use ($allowedTypes, $filterKeywords) {
            // Condition 1: Server type must be in the list of allowed types
            if ($allowedTypes && !in_array($server['type'], $allowedTypes)) {
                return false; // Filter out (don't keep)
            }

            // Condition 2: If filterKeywords are provided, at least one keyword must match
            if (!empty($filterKeywords)) { // Check if $filterKeywords is not empty
                $keywordMatch = collect($filterKeywords)->contains(function ($keyword) use ($server) {
                    return stripos($server['name'], $keyword) !== false
                        || in_array($keyword, $server['tags'] ?? []);
                });
                if (!$keywordMatch) {
                    return false; // Filter out if no keywords match
                }
            }
            // Keep the server if its type is allowed AND (no filter keywords OR at least one keyword matched)
            return true;
        })->values()->all();
    }

    private function getClientInfo(Request $request): array
CODE,
        <<<'CODE'
    private function filterServers(
        array $servers,
        array $allowedTypes,
        ?array $filterKeywords,
        bool $exclusiveOnly = false,
        bool $excludeExclusive = false
    ): array
    {
        return collect($servers)->filter(function ($server) use ($allowedTypes, $filterKeywords, $exclusiveOnly, $excludeExclusive) {
            if ($allowedTypes && !in_array($server['type'], $allowedTypes)) {
                return false;
            }

            if ($this->shouldFilterExclusiveServer($server, $exclusiveOnly, $excludeExclusive)) {
                return false;
            }

            if (!empty($filterKeywords)) {
                $keywordMatch = collect($filterKeywords)->contains(function ($keyword) use ($server) {
                    return stripos($server['name'], $keyword) !== false
                        || in_array($keyword, $this->normalizeServerTags($server['tags'] ?? []), true);
                });
                if (!$keywordMatch) {
                    return false;
                }
            }
            return true;
        })->values()->all();
    }

    private function isExclusiveClient(string $flag): bool
    {
        foreach (self::EXCLUSIVE_CLIENT_FLAGS as $exclusiveFlag) {
            if (stripos($flag, $exclusiveFlag) !== false) {
                return true;
            }
        }

        return false;
    }

    private function shouldFilterExclusiveServer(array $server, bool $exclusiveOnly, bool $excludeExclusive): bool
    {
        $tags = $this->normalizeServerTags($server['tags'] ?? []);
        $isExclusiveServer = in_array(self::EXCLUSIVE_TAG, $tags, true);

        if ($exclusiveOnly) {
            return !$isExclusiveServer;
        }

        if ($excludeExclusive) {
            return $isExclusiveServer;
        }

        return false;
    }

    private function normalizeServerTags($tags): array
    {
        if (is_string($tags)) {
            $decodedTags = json_decode($tags, true);
            $tags = is_array($decodedTags) ? $decodedTags : [];
        }

        return is_array($tags) ? $tags : [];
    }

    private function getClientInfo(Request $request): array
CODE,
        'xboard-filter-method'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
    private function setSubscribeInfoToServers(&$servers, $user, $rejectServerCount = 0)
    {
        if (!isset($servers[0]))
            return;
        if ($rejectServerCount > 0) {
            array_unshift($servers, array_merge($servers[0], [
                'name' => "过滤掉{$rejectServerCount}条线路",
            ]));
        }
        if (!(int) admin_setting('show_info_to_server_enable', 0))
            return;
CODE,
        <<<'CODE'
    private function setSubscribeInfoToServers(&$servers, $user, $rejectServerCount = 0)
    {
        if (!isset($servers[0]))
            return;
        if (!(int) admin_setting('show_info_to_server_enable', 0))
            return;
CODE,
        'xboard-remove-filter-tip'
    );

    file_put_contents($file, $code);
    echo "patched\n";
    exit(0);
}

fwrite(STDERR, "不支持的面板类型：{$panel}\n");
exit(1);
PHP
}

clear_laravel_cache() {
  local root="$1"
  log ''
  log '开始清理 Laravel 缓存...'
  if (cd "$root" && php artisan optimize:clear >/dev/null 2>&1); then
    log 'Laravel 缓存已清理：php artisan optimize:clear'
    return 0
  fi

  local commands=(config:clear cache:clear view:clear route:clear)
  local cmd
  for cmd in "${commands[@]}"; do
    if (cd "$root" && php artisan "$cmd" >/dev/null 2>&1); then
      log "已执行：php artisan $cmd"
    else
      log "跳过或执行失败：php artisan $cmd"
    fi
  done
}

patch_project() {
  local panel="$1"
  local root="$2"
  local controller="$root/app/Http/Controllers/V1/Client/ClientController.php"
  [ -f "$controller" ] || fail "未找到目标文件：$controller"

  log ''
  log "准备修改：$controller"
  backup_file "$controller"

  local result
  result=$(apply_patch_by_php "$panel" "$controller")
  case "$result" in
    patched)
      log '补丁写入成功。'
      ;;
    already_patched)
      log '检测到已应用过补丁，跳过写入。'
      ;;
    *)
      fail "补丁执行异常：$result"
      ;;
  esac

  if ask_yes_no '是否立即清理 Laravel 缓存？' 'y'; then
    clear_laravel_cache "$root"
  fi

  log ''
  log '如果线上仍未生效，请手动重载 PHP-FPM 或重启容器，以刷新 OPcache。'
}

main() {
  require_php
  choose_panel

  local panel root
  case "$PANEL_CHOICE" in
    xboard|v2board)
      choose_root "$PANEL_CHOICE"
      patch_project "$PANEL_CHOICE" "$ROOT_PATH"
      ;;
    all)
      for panel in xboard v2board; do
        choose_root "$panel"
        root="$ROOT_PATH"
        patch_project "$panel" "$root"
      done
      ;;
  esac

  log ''
  log '处理完成。'
}

main "$@"

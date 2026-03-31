#!/usr/bin/env bash
set -euo pipefail

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

is_tty_interactive() {
  [ -t 0 ] && [ -t 1 ]
}

choose_from_menu() {
  local title="$1"
  shift
  local options=("$@")
  local count=${#options[@]}
  local selected=0
  local input extra index

  [ "$count" -gt 0 ] || fail '菜单项不能为空。'

  if ! is_tty_interactive; then
    printf '\n%s\n' "$title" >&2
    for ((index = 0; index < count; index++)); do
      printf '  %s) %s\n' "$((index + 1))" "${options[$index]}" >&2
    done
    while true; do
      printf '请输入序号 [1-%s]: ' "$count" >&2
      read -r input || true
      if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$count" ]; then
        printf '%s\n' "$((input - 1))"
        return
      fi
      printf '输入无效，请重新输入。\n' >&2
    done
  fi

  trap 'tput cnorm 2>/dev/null || true' RETURN
  tput civis 2>/dev/null || true

  while true; do
    printf '\033[2J\033[H' >&2
    printf '%s\n' "$title" >&2
    printf '使用 ↑ ↓ 选择，回车确认。\n\n' >&2

    for ((index = 0; index < count; index++)); do
      if [ "$index" -eq "$selected" ]; then
        printf '> %s\n' "${options[$index]}" >&2
      else
        printf '  %s\n' "${options[$index]}" >&2
      fi
    done

    IFS= read -rsn1 input || true
    if [[ "$input" == $'\033' ]]; then
      IFS= read -rsn2 extra || true
      input+="$extra"
    fi

    case "$input" in
      $'\033[A') selected=$(((selected - 1 + count) % count)) ;;
      $'\033[B') selected=$(((selected + 1) % count)) ;;
      ''|$'\n')
        printf '\033[2J\033[H' >&2
        printf '%s\n' "$selected"
        return
        ;;
    esac
  done
}

choose_panel() {
  local menu_index
  menu_index=$(choose_from_menu '请选择要修改的面板：' 'XBoard' 'V2Board' 'SSPanel-Malio')

  case "$menu_index" in
    0) PANEL_CHOICE='xboard' ;;
    1) PANEL_CHOICE='v2board' ;;
    2) PANEL_CHOICE='sspanel-malio' ;;
    *) fail '面板选择异常。' ;;
  esac
}

validate_xboard_root() {
  local root="$1"
  [ -f "$root/artisan" ] &&
    [ -f "$root/app/Http/Controllers/V1/Client/ClientController.php" ] &&
    [ -f "$root/app/Protocols/ClashMeta.php" ] &&
    [ -f "$root/app/Support/ProtocolManager.php" ]
}

validate_v2board_root() {
  local root="$1"
  [ -f "$root/artisan" ] &&
    [ -f "$root/app/Http/Controllers/V1/Client/ClientController.php" ] &&
    [ -f "$root/app/Protocols/ClashMeta.php" ] &&
    [ ! -f "$root/app/Support/ProtocolManager.php" ]
}

validate_sspanel_root() {
  local root="$1"
  [ -f "$root/bootstrap.php" ] &&
    [ -f "$root/app/Utils/URL.php" ] &&
    [ -f "$root/resources/views/malio/user/node.tpl" ]
}

validate_root_for_panel() {
  local panel="$1"
  local root="$2"

  case "$panel" in
    xboard) validate_xboard_root "$root" ;;
    v2board) validate_v2board_root "$root" ;;
    sspanel-malio) validate_sspanel_root "$root" ;;
    *) return 1 ;;
  esac
}

collect_candidates() {
  local panel="$1"
  local root="/www/wwwroot"
  local result=''
  local dir

  [ -d "$root" ] || return 0

  for dir in "$root"/*; do
    [ -d "$dir" ] || continue
    validate_root_for_panel "$panel" "$dir" || continue
    result+="$dir"$'\n'
  done

  printf '%s' "$result" | awk 'NF && !seen[$0]++'
}

format_candidate_label() {
  local path="$1"
  local name
  name=$(basename "$path")
  printf '%s (%s)' "$name" "$path"
}

prompt_root_error() {
  local panel="$1"
  case "$panel" in
    xboard|v2board)
      log '目标目录需包含 artisan、app/Http/Controllers/V1/Client/ClientController.php、app/Protocols/ClashMeta.php。'
      ;;
    sspanel-malio)
      log '目标目录需包含 bootstrap.php、app/Utils/URL.php、resources/views/malio/user/node.tpl。'
      ;;
  esac
}

choose_root() {
  local panel="$1"
  local selected_index path
  local manual_label='手动输入路径'
  local -a candidate_array=()
  local -a option_array=()

  mapfile -t candidate_array < <(collect_candidates "$panel")

  if [ "${#candidate_array[@]}" -gt 0 ]; then
    for path in "${candidate_array[@]}"; do
      option_array+=("$(format_candidate_label "$path")")
    done
    option_array+=("$manual_label")

    selected_index=$(choose_from_menu "检测到以下 ${panel} 目录：" "${option_array[@]}")
    if [ "$selected_index" -lt "${#candidate_array[@]}" ]; then
      ROOT_PATH="${candidate_array[$selected_index]}"
      return
    fi
  fi

  while true; do
    printf '请输入 %s 项目根目录: ' "$panel"
    read -r ROOT_PATH || true
    [ -n "$ROOT_PATH" ] || { log '路径不能为空。'; continue; }

    if validate_root_for_panel "$panel" "$ROOT_PATH"; then
      return
    fi

    prompt_root_error "$panel"
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
  local target="$2"
  local file="$3"

  php - "$panel" "$target" "$file" <<'PHP'
<?php
$panel = $argv[1] ?? '';
$target = $argv[2] ?? '';
$file = $argv[3] ?? '';
$code = @file_get_contents($file);
if ($code === false) {
    fwrite(STDERR, "读取文件失败：{$file}\n");
    exit(1);
}

function replace_once_or_fail(string $code, string $search, string $replace, string $label): string
{
    $variants = [
        [$search, $replace],
        [
            str_replace("\n", "\r\n", $search),
            str_replace("\n", "\r\n", $replace),
        ],
    ];

    foreach ($variants as [$searchVariant, $replaceVariant]) {
        $pos = strpos($code, $searchVariant);
        if ($pos !== false) {
            return substr($code, 0, $pos) . $replaceVariant . substr($code, $pos + strlen($searchVariant));
        }
    }

    fwrite(STDERR, "未找到补丁锚点：{$label}\n");
    exit(2);
}

if ($panel === 'v2board' && $target === 'controller') {
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

            if ($this->isExclusiveClient($flag)) {
                $servers = $this->filterToExclusiveServersOnly($servers);
                if (strpos($protocolFlag, 'meta') === false) {
                    $protocolFlag .= '|meta';
                }
            } else {
                $servers = $this->filterExclusiveServers($servers);
            }

            if($protocolFlag) {
                if (strpos($protocolFlag, 'sing') === false) {
                    $this->setSubscribeInfoToServers($servers, $user);
                    foreach (array_reverse(glob(app_path('Protocols') . '/*.php')) as $file) {
                        $file = 'App\\Protocols\\' . basename($file, '.php');
                        $class = new $file($user, $servers);
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

    private function isExclusiveClient(string $flag): bool
    {
        foreach (self::EXCLUSIVE_CLIENT_FLAGS as $exclusiveFlag) {
            if (stripos($flag, $exclusiveFlag) !== false) {
                return true;
            }
        }
        return false;
    }

    private function filterExclusiveServers(array $servers): array
    {
        return array_values(array_filter($servers, function ($server) {
            $tags = $server['tags'] ?? [];
            if (is_string($tags)) {
                $tags = json_decode($tags, true) ?? [];
            }
            return !in_array(self::EXCLUSIVE_TAG, $tags, true);
        }));
    }

    private function filterToExclusiveServersOnly(array $servers): array
    {
        return array_values(array_filter($servers, function ($server) {
            $tags = $server['tags'] ?? [];
            if (is_string($tags)) {
                $tags = json_decode($tags, true) ?? [];
            }
            return in_array(self::EXCLUSIVE_TAG, $tags, true);
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

if ($panel === 'xboard' && $target === 'controller') {
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

if ($panel === 'sspanel-malio' && $target === 'url') {
    if (strpos($code, 'private const EXCLUSIVE_CLIENT_FLAGS') !== false && strpos($code, 'shouldKeepNodeForClient') !== false) {
        echo "already_patched\n";
        exit(0);
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
class URL
{
    /*
CODE,
        <<<'CODE'
class URL
{
    /**
     * 专用客户端标识
     */
    private const EXCLUSIVE_CLIENT_FLAGS = [
        'xboardmihomo',
    ];

    /**
     * 专用节点标记关键字
     */
    private const EXCLUSIVE_NODE_KEYWORD = '客服端专用';

    /*
CODE,
        'sspanel-url-class-header'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
    public static function getNew_AllItems($user, $Rule)
CODE,
        <<<'CODE'
    private static function isExclusiveClientRequest()
    {
        $userAgent = strtolower($_SERVER['HTTP_USER_AGENT'] ?? '');
        foreach (self::EXCLUSIVE_CLIENT_FLAGS as $flag) {
            if ($flag !== '' && strpos($userAgent, strtolower($flag)) !== false) {
                return true;
            }
        }
        return false;
    }

    private static function containsExclusiveKeyword($value)
    {
        if (!is_string($value) || $value === '') {
            return false;
        }
        return strpos($value, self::EXCLUSIVE_NODE_KEYWORD) !== false;
    }

    private static function isExclusiveNode($node)
    {
        return self::containsExclusiveKeyword($node->info ?? '')
            || self::containsExclusiveKeyword($node->name ?? '')
            || self::containsExclusiveKeyword($node->status ?? '');
    }

    private static function shouldKeepNodeForClient($node)
    {
        $isExclusiveNode = self::isExclusiveNode($node);
        if (self::isExclusiveClientRequest()) {
            return $isExclusiveNode;
        }
        return !$isExclusiveNode;
    }

    public static function getNew_AllItems($user, $Rule)
CODE,
        'sspanel-url-helper-methods'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
            foreach ($nodes as $node) {
                if (in_array($node->sort, [13]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'ss'))) {
CODE,
        <<<'CODE'
            foreach ($nodes as $node) {
                if (!self::shouldKeepNodeForClient($node)) {
                    continue;
                }

                if (in_array($node->sort, [13]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'ss'))) {
CODE,
        'sspanel-url-node-loop'
    );

    file_put_contents($file, $code);
    echo "patched\n";
    exit(0);
}

if ($panel === 'sspanel-malio' && $target === 'node_tpl') {
    if (strpos($code, 'data-xboard-exclusive') !== false && strpos($code, 'xboard-exclusive-badge') !== false) {
        echo "already_patched\n";
        exit(0);
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
    .card-body .rounded-circle {
      box-shadow: 0 2px 6px #e6ecf1;
    }
  </style>
CODE,
        <<<'CODE'
    .card-body .rounded-circle {
      box-shadow: 0 2px 6px #e6ecf1;
    }

    .xboard-exclusive-badge {
      display: inline-flex;
      align-items: center;
      margin-top: 6px;
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 12px;
      line-height: 1.4;
      color: #fff;
      background: linear-gradient(135deg, #ff9800, #f57c00);
    }
  </style>
CODE,
        'sspanel-node-style'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
                <div class="card" {if $user->class>0} data-toggle="modal" data-target="#node-modal-{$node['id']}"{/if}>
CODE,
        <<<'CODE'
                <div class="card"{if strpos($node['info'], '客服端专用') !== false || strpos($node['name'], '客服端专用') !== false || strpos($node['status'], '客服端专用') !== false} data-xboard-exclusive="1"{/if} {if $user->class>0} data-toggle="modal" data-target="#node-modal-{$node['id']}"{/if}>
CODE,
        'sspanel-node-card-modal'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
                  <div class="card" {if $user->class >0}onclick="urlChange('{$node['id']}',0,{if $relay_rule != null}{$relay_rule->id}{else}0{/if})"{/if}>
CODE,
        <<<'CODE'
                  <div class="card"{if strpos($node['info'], '客服端专用') !== false || strpos($node['name'], '客服端专用') !== false || strpos($node['status'], '客服端专用') !== false} data-xboard-exclusive="1"{/if} {if $user->class >0}onclick="urlChange('{$node['id']}',0,{if $relay_rule != null}{$relay_rule->id}{else}0{/if})"{/if}>
CODE,
        'sspanel-node-card-click'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
                          <div class="media-body">
                            <div class="media-title node-status {if $node['online']=='1' or $node['sort'] == 14}node-is-online{else}node-is-offline{/if}">{current(explode(" - ", $node['name']))}</div>
                            <div class=" text-job text-muted">{$node['info']}</div>
                          </div>
CODE,
        <<<'CODE'
                          <div class="media-body"{if strpos($node['info'], '客服端专用') !== false || strpos($node['name'], '客服端专用') !== false || strpos($node['status'], '客服端专用') !== false} data-xboard-exclusive="1"{/if}>
                            <div class="media-title node-status {if $node['online']=='1' or $node['sort'] == 14}node-is-online{else}node-is-offline{/if}">{current(explode(" - ", $node['name']))}</div>
                            {if strpos($node['info'], '客服端专用') !== false || strpos($node['name'], '客服端专用') !== false || strpos($node['status'], '客服端专用') !== false}
                            <div class="xboard-exclusive-badge" data-xboard-exclusive="1">客服端专用</div>
                            {/if}
                            <div class=" text-job text-muted">{$node['info']}</div>
                          </div>
CODE,
        'sspanel-node-media-body'
    );

    file_put_contents($file, $code);
    echo "patched\n";
    exit(0);
}

fwrite(STDERR, "不支持的补丁目标：{$panel} / {$target}\n");
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

clear_sspanel_cache() {
  local root="$1"
  local dir
  local -a dirs=(
    "$root/storage/framework/smarty"
    "$root/storage/framework/views"
    "$root/storage/SubscribeCache"
  )

  log ''
  log '开始清理 SSPanel 模板与订阅缓存...'
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    log "已清理：$dir"
  done
}

patch_single_file() {
  local panel="$1"
  local target="$2"
  local file="$3"
  [ -f "$file" ] || fail "未找到目标文件：$file"

  log ''
  log "准备修改：$file"
  backup_file "$file"

  local result status
  set +e
  result=$(apply_patch_by_php "$panel" "$target" "$file" 2>&1)
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    fail "补丁执行失败：$result"
  fi

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
}

patch_project() {
  local panel="$1"
  local root="$2"

  case "$panel" in
    xboard|v2board)
      patch_single_file "$panel" 'controller' "$root/app/Http/Controllers/V1/Client/ClientController.php"
      if ask_yes_no '是否立即清理 Laravel 缓存？' 'y'; then
        clear_laravel_cache "$root"
      fi
      ;;
    sspanel-malio)
      patch_single_file "$panel" 'url' "$root/app/Utils/URL.php"
      patch_single_file "$panel" 'node_tpl' "$root/resources/views/malio/user/node.tpl"
      if ask_yes_no '是否立即清理 SSPanel 模板与订阅缓存？' 'y'; then
        clear_sspanel_cache "$root"
      fi
      ;;
    *)
      fail "不支持的面板类型：$panel"
      ;;
  esac

  log ''
  log '如果线上仍未生效，请手动重载 PHP-FPM 或重启容器，以刷新 OPcache。'
}

main() {
  require_php
  choose_panel
  choose_root "$PANEL_CHOICE"
  patch_project "$PANEL_CHOICE" "$ROOT_PATH"

  log ''
  log '处理完成。'
}

main "$@"

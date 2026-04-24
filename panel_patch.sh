#!/usr/bin/env bash
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
declare -a EXCLUSIVE_CLIENT_FLAGS=()

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

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt_exclusive_client_flags() {
  local default_value='XBoardMihomo/1.0'
  local answer normalized item
  local -a raw_flags=()

  while true; do
    printf '请输入专用客户端 UA 或识别标识（多个用逗号分隔，留空使用默认 %s）: ' "$default_value"
    read -r answer || true
    if [ -z "$answer" ]; then
      answer="$default_value"
    fi

    normalized="${answer//，/,}"
    IFS=',' read -r -a raw_flags <<< "$normalized"
    EXCLUSIVE_CLIENT_FLAGS=()

    for item in "${raw_flags[@]}"; do
      item=$(trim_value "$item")
      [ -n "$item" ] || continue
      EXCLUSIVE_CLIENT_FLAGS+=("$item")
    done

    if [ "${#EXCLUSIVE_CLIENT_FLAGS[@]}" -gt 0 ]; then
      log "专用客户端识别标识：$(printf '%s' "${EXCLUSIVE_CLIENT_FLAGS[0]}")$(if [ "${#EXCLUSIVE_CLIENT_FLAGS[@]}" -gt 1 ]; then printf ' 等 %s 项' "${#EXCLUSIVE_CLIENT_FLAGS[@]}"; fi)"
      log '后端按“不区分大小写的包含匹配”识别专用客户端请求。'
      return
    fi

    log '至少需要输入一个专用客户端 UA 或识别标识。'
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
    [ -f "$root/app/Controllers/UserController.php" ] &&
    [ -f "$root/app/Controllers/VueController.php" ]
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
      log '目标目录需包含 bootstrap.php、app/Utils/URL.php、app/Controllers/UserController.php、app/Controllers/VueController.php。'
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
  local exclusive_flags_payload

  exclusive_flags_payload=$(printf '%s\n' "${EXCLUSIVE_CLIENT_FLAGS[@]}")

  php /dev/stdin "$panel" "$target" "$file" "$exclusive_flags_payload" <<'PHP'
<?php
$panel = $argv[1] ?? '';
$target = $argv[2] ?? '';
$file = $argv[3] ?? '';
$exclusiveFlagsRaw = $argv[4] ?? '';
$code = @file_get_contents($file);
if ($code === false) {
    fwrite(STDERR, "读取文件失败：{$file}\n");
    exit(1);
}

$exclusiveFlags = array_values(array_filter(
    array_map(static fn($item) => trim($item), preg_split('/\r?\n/', $exclusiveFlagsRaw) ?: []),
    static fn($item) => $item !== ''
));

if (count($exclusiveFlags) === 0) {
    $exclusiveFlags = ['XBoardMihomo/1.0'];
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

function escape_php_single_quoted(string $value): string
{
    return str_replace(["\\", "'"], ["\\\\", "\\'"], $value);
}

function build_exclusive_flags_code(array $flags): string
{
    $lines = array_map(
        static fn($flag) => "        '" . escape_php_single_quoted($flag) . "',",
        $flags
    );
    return implode("\n", $lines);
}

function inject_exclusive_flags(string $template, string $exclusiveFlagsCode): string
{
    return str_replace('__EXCLUSIVE_CLIENT_FLAGS__', $exclusiveFlagsCode, $template);
}

function replace_exclusive_flags_constant(string $code, string $exclusiveFlagsCode, string $label): string
{
    $replacement = "private const EXCLUSIVE_CLIENT_FLAGS = [\n{$exclusiveFlagsCode}\n    ];";
    $result = preg_replace('/private const EXCLUSIVE_CLIENT_FLAGS = \[(?:.*?)\];/s', $replacement, $code, 1, $count);
    if ($result === null || $count < 1) {
        fwrite(STDERR, "未找到专用客户端标识常量：{$label}\n");
        exit(2);
    }
    return $result;
}

$exclusiveFlagsCode = build_exclusive_flags_code($exclusiveFlags);

if ($panel === 'v2board' && $target === 'controller') {
    if (strpos($code, 'private const EXCLUSIVE_CLIENT_FLAGS') !== false && strpos($code, '$protocolFlag = $flag;') !== false) {
        $code = replace_exclusive_flags_constant($code, $exclusiveFlagsCode, 'v2board-exclusive-flags');
        file_put_contents($file, $code);
        echo "patched\n";
        exit(0);
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
class ClientController extends Controller
{
    public function subscribe(Request $request)
CODE,
        inject_exclusive_flags(<<<'CODE'
class ClientController extends Controller
{
    /**
     * 专用客户端标识列表
     * 只有匹配这些标识的客户端才能获取带 exclusive 标签的节点
     */
    private const EXCLUSIVE_CLIENT_FLAGS = [
__EXCLUSIVE_CLIENT_FLAGS__
    ];

    /**
     * 专用节点标签名
     */
    private const EXCLUSIVE_TAG = '客服端专用';

    public function subscribe(Request $request)
CODE,
        $exclusiveFlagsCode),
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
        $code = replace_exclusive_flags_constant($code, $exclusiveFlagsCode, 'xboard-exclusive-flags');
        file_put_contents($file, $code);
        echo "patched\n";
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
        inject_exclusive_flags(<<<'CODE'
class ClientController extends Controller
{
    /**
     * 专用客户端标识
     */
    private const EXCLUSIVE_CLIENT_FLAGS = [
__EXCLUSIVE_CLIENT_FLAGS__
    ];

    /**
     * 专用节点标签
     */
    private const EXCLUSIVE_TAG = '客服端专用';

    /**
     * Protocol prefix mapping for server names
CODE,
        $exclusiveFlagsCode),
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

if ($panel === 'sspanel-malio' && $target === 'user_controller') {
    if (substr_count($code, "strpos((string) (\$node->info ?? ''), '客服端专用') !== false") >= 2) {
        echo "already_patched\n";
        exit(0);
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
        foreach ($nodes as $node) {
            if ($user->is_admin == 0 && $node->node_group != $user->node_group && $node->node_group != 0) {
                continue;
            }
            if ($node->sort == 9) {
CODE,
        <<<'CODE'
        foreach ($nodes as $node) {
            if ($user->is_admin == 0 && $node->node_group != $user->node_group && $node->node_group != 0) {
                continue;
            }
            if (
                strpos((string) ($node->info ?? ''), '客服端专用') !== false ||
                strpos((string) ($node->status ?? ''), '客服端专用') !== false
            ) {
                continue;
            }
            if ($node->sort == 9) {
CODE,
        'sspanel-user-controller-node-loop'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
        foreach ($nodes as $node) {
            if (($user->node_group == $node->node_group || $node->node_group == 0 || $user->is_admin) && (!$node->isNodeTrafficOut())) {
                if ($node->sort == 9) {
CODE,
        <<<'CODE'
        foreach ($nodes as $node) {
            if (($user->node_group == $node->node_group || $node->node_group == 0 || $user->is_admin) && (!$node->isNodeTrafficOut())) {
                if (
                    strpos((string) ($node->info ?? ''), '客服端专用') !== false ||
                    strpos((string) ($node->status ?? ''), '客服端专用') !== false
                ) {
                    continue;
                }
                if ($node->sort == 9) {
CODE,
        'sspanel-user-controller-prefix-loop'
    );

    file_put_contents($file, $code);
    echo "patched\n";
    exit(0);
}

if ($panel === 'sspanel-malio' && $target === 'vue_controller') {
    if (strpos($code, "strpos((string) (\$node->info ?? ''), '客服端专用') !== false") !== false) {
        echo "already_patched\n";
        exit(0);
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
        foreach ($nodes as $node) {
            if ($node->node_group != $user->node_group && $node->node_group != 0) {
                continue;
            }
            if ($node->sort == 9) {
CODE,
        <<<'CODE'
        foreach ($nodes as $node) {
            if ($node->node_group != $user->node_group && $node->node_group != 0) {
                continue;
            }
            if (
                strpos((string) ($node->info ?? ''), '客服端专用') !== false ||
                strpos((string) ($node->status ?? ''), '客服端专用') !== false
            ) {
                continue;
            }
            if ($node->sort == 9) {
CODE,
        'sspanel-vue-controller-node-loop'
    );

    file_put_contents($file, $code);
    echo "patched\n";
    exit(0);
}

if ($panel === 'sspanel-malio' && $target === 'url') {
    if (
        strpos($code, 'private static function shouldKeepNodeForClient($node, $userAgent)') !== false &&
        strpos($code, "case 'vless':") !== false &&
        strpos($code, "case 'hysteria2':") !== false &&
        strpos($code, 'public static function getVlessItem') !== false &&
        strpos($code, 'public static function getHy2Item') !== false
    ) {
        $code = replace_exclusive_flags_constant($code, $exclusiveFlagsCode, 'sspanel-url-exclusive-flags');
        file_put_contents($file, $code);
        echo "patched\n";
        exit(0);
    }

    if (strpos($code, 'private const EXCLUSIVE_CLIENT_FLAGS') === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
class URL
{
    /*
CODE,
            inject_exclusive_flags(<<<'CODE'
class URL
{
    /**
     * 专用客户端 UA 标识
     */
    private const EXCLUSIVE_CLIENT_FLAGS = [
__EXCLUSIVE_CLIENT_FLAGS__
    ];

    /**
     * 专用节点关键字
     */
    private const EXCLUSIVE_NODE_KEYWORD = '客服端专用';

    /*
CODE,
            $exclusiveFlagsCode),
            'sspanel-url-class-header'
        );
    }

    if (strpos($code, "\$userAgent = strtolower(\$_SERVER['HTTP_USER_AGENT'] ?? '');") === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
        //         'regex'   => '.*香港.*HKBN.*',
        //     ]
        // ];
        $is_mu = $Rule['is_mu'];
CODE,
            <<<'CODE'
        //         'regex'   => '.*香港.*HKBN.*',
        //     ]
        // ];
        $userAgent = strtolower($_SERVER['HTTP_USER_AGENT'] ?? '');
        $is_mu = $Rule['is_mu'];
CODE,
            'sspanel-url-user-agent'
        );
    }

    $oldHelperBlock = <<<'CODE'
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
CODE;

    $newHelperBlock = <<<'CODE'
    /**
     * 判断是否为专用客户端请求
     *
     * @param string $userAgent
     *
     * @return bool
     */
    private static function isExclusiveClientRequest($userAgent)
    {
        foreach (self::EXCLUSIVE_CLIENT_FLAGS as $flag) {
            if ($flag !== '' && strpos($userAgent, strtolower($flag)) !== false) {
                return true;
            }
        }
        return false;
    }

    /**
     * 判断字段是否包含专用节点关键字
     *
     * 只看节点描述（info）和节点状态（status），不再依赖节点名称。
     *
     * @param mixed $value
     *
     * @return bool
     */
    private static function containsExclusiveKeyword($value)
    {
        if (!is_string($value) || $value === '') {
            return false;
        }
        return strpos($value, self::EXCLUSIVE_NODE_KEYWORD) !== false;
    }

    /**
     * 判断是否为专用节点
     *
     * @param Node $node
     *
     * @return bool
     */
    private static function isExclusiveNode($node)
    {
        return self::containsExclusiveKeyword($node->info ?? '')
            || self::containsExclusiveKeyword($node->status ?? '');
    }

    /**
     * 根据客户端类型决定是否保留节点
     *
     * @param Node   $node
     * @param string $userAgent
     *
     * @return bool
     */
    private static function shouldKeepNodeForClient($node, $userAgent)
    {
        $isExclusiveNode = self::isExclusiveNode($node);
        if (self::isExclusiveClientRequest($userAgent)) {
            return $isExclusiveNode;
        }
        return !$isExclusiveNode;
    }

    public static function getNew_AllItems($user, $Rule)
CODE;

    if (strpos($code, 'private static function shouldKeepNodeForClient($node, $userAgent)') === false) {
        if (strpos($code, $oldHelperBlock) !== false) {
            $code = replace_once_or_fail(
                $code,
                $oldHelperBlock,
                $newHelperBlock,
                'sspanel-url-helper-methods-upgrade'
            );
        } else {
            $code = replace_once_or_fail(
                $code,
                <<<'CODE'
    public static function getNew_AllItems($user, $Rule)
CODE,
                $newHelperBlock,
                'sspanel-url-helper-methods'
            );
        }
    }

    if (strpos($code, "case 'vless':") === false || strpos($code, "case 'hysteria2':") === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
            case 'trojan':
                $sort = [14];
                break;
            default:
                $Rule['type'] = 'all';
                $sort = [0, 10, 11, 12, 13, 14];
                break;
CODE,
            <<<'CODE'
            case 'trojan':
                $sort = [14];
                break;
            case 'vless':
                $sort = [15, 16];
                break;
            case 'hysteria2':
                $sort = [17];
                break;
            default:
                $Rule['type'] = 'all';
                $sort = [0, 10, 11, 12, 13, 14, 15, 16, 17];
                break;
CODE,
            'sspanel-url-sort-switch'
        );
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
        if ($is_mu != 0 && $Rule['type'] != 'vmess' && $Rule['type'] != 'trojan') {
CODE,
        <<<'CODE'
        if ($is_mu != 0 && $Rule['type'] != 'vmess' && $Rule['type'] != 'trojan' && $Rule['type'] != 'vless' && $Rule['type'] != 'hysteria2') {
CODE,
        'sspanel-url-mu-condition'
    );

    if (
        strpos($code, '!self::shouldKeepNodeForClient($node, $userAgent))') === false &&
        strpos($code, '!self::shouldKeepNodeForClient($node))') === false
    ) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
            foreach ($nodes as $node) {
                if (in_array($node->sort, [13]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] != 'all'))) {
CODE,
            <<<'CODE'
            foreach ($nodes as $node) {
                if (!self::shouldKeepNodeForClient($node, $userAgent)) {
                    continue;
                }

                if (in_array($node->sort, [13]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'ss'))) {
CODE,
            'sspanel-url-node-loop-stock'
        );
    }

    if (strpos($code, '!self::shouldKeepNodeForClient($node))') !== false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
            foreach ($nodes as $node) {
                if (!self::shouldKeepNodeForClient($node)) {
                    continue;
                }

                if (in_array($node->sort, [13]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'ss'))) {
CODE,
            <<<'CODE'
            foreach ($nodes as $node) {
                if (!self::shouldKeepNodeForClient($node, $userAgent)) {
                    continue;
                }

                if (in_array($node->sort, [13]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'ss'))) {
CODE,
            'sspanel-url-node-loop-upgrade'
        );
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
                if (in_array($node->sort, [11, 12]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] != 'all'))) {
CODE,
        <<<'CODE'
                if (in_array($node->sort, [11, 12]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'vmess'))) {
CODE,
        'sspanel-url-vmess-condition'
    );

    if (strpos($code, "if (in_array(\$node->sort, [15, 16])") === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
                if (in_array($node->sort, [14]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'trojan'))) {
                    // Trojan
                    $item = self::getTrojanItem($user, $node, $emoji);
                    if ($item != null) {
                        $find = (isset($Rule['content']['regex']) && $Rule['content']['regex'] != '' ? ConfController::getMatchProxy($item, ['content' => ['regex' => $Rule['content']['regex']]]) : true);
                        if ($find) {
                            $return_array[] = $item;
                        }
                    }
                    continue;
                }
                if (in_array($node->sort, [0, 10]) && $node->mu_only != 1 && ($is_mu == 0 || ($is_mu != 0 && Config::get('mergeSub') === true))) {
CODE,
            <<<'CODE'
                if (in_array($node->sort, [14]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'trojan'))) {
                    // Trojan
                    $item = self::getTrojanItem($user, $node, $emoji);
                    if ($item != null) {
                        $find = (isset($Rule['content']['regex']) && $Rule['content']['regex'] != '' ? ConfController::getMatchProxy($item, ['content' => ['regex' => $Rule['content']['regex']]]) : true);
                        if ($find) {
                            $return_array[] = $item;
                        }
                    }
                    continue;
                }
                if (in_array($node->sort, [15, 16]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'vless'))) {
                    // VLESS
                    $item = self::getVlessItem($user, $node, $emoji);
                    if ($item != null) {
                        $find = (isset($Rule['content']['regex']) && $Rule['content']['regex'] != '' ? ConfController::getMatchProxy($item, ['content' => ['regex' => $Rule['content']['regex']]]) : true);
                        if ($find) {
                            $return_array[] = $item;
                        }
                    }
                    continue;
                }
                if (in_array($node->sort, [17]) && (($Rule['type'] == 'all' && $x == 0) || ($Rule['type'] == 'hysteria2'))) {
                    // Hysteria2
                    $item = self::getHy2Item($user, $node, $emoji);
                    if ($item != null) {
                        $find = (isset($Rule['content']['regex']) && $Rule['content']['regex'] != '' ? ConfController::getMatchProxy($item, ['content' => ['regex' => $Rule['content']['regex']]]) : true);
                        if ($find) {
                            $return_array[] = $item;
                        }
                    }
                    continue;
                }
                if (in_array($node->sort, [0, 10]) && $node->mu_only != 1 && ($is_mu == 0 || ($is_mu != 0 && Config::get('mergeSub') === true))) {
CODE,
            'sspanel-url-insert-new-types'
        );
    }

    if (strpos($code, 'public static function getVlessItem') === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
    
    public static function getAllUrl($user, $is_mu, $is_ss = 0, $getV2rayPlugin = 1)
CODE,
            <<<'CODE'

    /**
     * VLESS 节点
     *
     * @param User $user 用户
     * @param Node $node
     * @param bool $emoji
     *
     * @return array
     */
    public static function getVlessItem($user, $node, $emoji = false)
    {
        $server = explode(';', $node->server);
        $opt = [];
        if (isset($server[1])) {
            parse_str($server[1], $opt);
        }

        $item['remark'] = ($emoji == true ? Tools::addEmoji($node->name) : $node->name);
        $item['type'] = 'vless';
        $item['address'] = $server[0];
        $item['port'] = (isset($opt['port']) ? (int) $opt['port'] : 443);
        $item['uuid'] = $user->uuid;
        $item['flow'] = (isset($opt['flow']) ? $opt['flow'] : '');

        if (isset($opt['security']) && $opt['security'] == 'reality') {
            $destHost = (isset($opt['dest']) ? $opt['dest'] : '');
            $destPort = (isset($opt['serverPort']) ? $opt['serverPort'] : '');
            $item['security'] = 'reality';
            $item['reality'] = [
                'dest' => ($destPort !== '' ? $destHost . ':' . $destPort : $destHost),
                'server_name' => (isset($opt['serverName']) ? $opt['serverName'] : ''),
                'private_key' => (isset($opt['privateKey']) ? $opt['privateKey'] : ''),
                'public_key' => (isset($opt['publicKey']) ? $opt['publicKey'] : ''),
                'short_id' => (isset($opt['shortId']) ? $opt['shortId'] : ''),
            ];
        } else {
            $item['security'] = 'none';
            $item['reality'] = [
                'dest' => '',
                'server_name' => '',
                'private_key' => '',
                'public_key' => '',
                'short_id' => '',
            ];
        }

        return $item;
    }

    /**
     * Hysteria2 节点
     *
     * @param User $user 用户
     * @param Node $node
     * @param bool $emoji
     *
     * @return array
     */
    public static function getHy2Item($user, $node, $emoji = false)
    {
        $server = explode(';', $node->server);
        $opt = [];
        if (isset($server[1])) {
            parse_str($server[1], $opt);
        }

        $item['remark'] = ($emoji == true ? Tools::addEmoji($node->name) : $node->name);
        $item['type'] = 'hysteria2';
        $item['address'] = $server[0];
        $item['port'] = (isset($opt['port']) ? (int) $opt['port'] : 443);
        $item['password'] = $user->uuid;
        $item['up_mbps'] = (isset($opt['up_mbps']) ? (int) $opt['up_mbps'] : 100);
        $item['down_mbps'] = (isset($opt['down_mbps']) ? (int) $opt['down_mbps'] : 100);
        $item['obfs_type'] = (isset($opt['obfs']) ? $opt['obfs'] : 'plain');
        $item['obfs_password'] = (isset($opt['obfs_password']) ? $opt['obfs_password'] : '');
        $item['ignore_client_bandwidth'] = (isset($opt['ignore_client_bandwidth']) ? (bool) $opt['ignore_client_bandwidth'] : false);
        $item['allow_insecure'] = (isset($opt['allow_insecure']) ? (bool) $opt['allow_insecure'] : false);
        $item['class'] = $node->node_class;
        $item['group'] = Config::get('appName');
        $item['ratio'] = $node->traffic_rate;

        return $item;
    }

    
    public static function getAllUrl($user, $is_mu, $is_ss = 0, $getV2rayPlugin = 1)
CODE,
            'sspanel-url-insert-methods'
        );
    }

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
      patch_single_file "$panel" 'user_controller' "$root/app/Controllers/UserController.php"
      patch_single_file "$panel" 'vue_controller' "$root/app/Controllers/VueController.php"
      patch_single_file "$panel" 'url' "$root/app/Utils/URL.php"
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
  prompt_exclusive_client_flags
  patch_project "$PANEL_CHOICE" "$ROOT_PATH"

  log ''
  log '处理完成。'
}

main "$@"

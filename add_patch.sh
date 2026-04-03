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

ask_integer_input() {
  local prompt="$1"
  local default="$2"
  local answer

  while true; do
    printf '%s [%s]: ' "$prompt" "$default" >&2
    read -r answer || true
    if [ -z "$answer" ]; then
      answer="$default"
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$answer"
      return
    fi
    printf '请输入非负整数。\n' >&2
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

choose_feature() {
  local panel="$1"
  local menu_index

  case "$panel" in
    v2board)
      menu_index=$(choose_from_menu '请选择要添加的功能补丁：' '分组套餐限制')
      case "$menu_index" in
        0)
          FEATURE_CHOICE='group_plan_limit'
          FEATURE_LABEL='分组套餐限制'
          ;;
        *) fail '功能选择异常。' ;;
      esac
      ;;
    xboard|sspanel-malio)
      fail '当前脚本暂未提供该面板的功能补丁，你后续可以继续往 add_patch.sh 里追加。'
      ;;
    *)
      fail '未知面板类型。'
      ;;
  esac
}

choose_feature_options() {
  local panel="$1"
  local feature="$2"

  case "$panel:$feature" in
    v2board:group_plan_limit)
      PATCH_USER_OLD_AFTER_MINUTES=$(ask_integer_input '请输入注册多少分钟后视为老用户' '5')
      PATCH_OLD_USER_GROUP_ID=$(ask_integer_input '请输入老用户权限组ID（专线组）' '1')
      PATCH_NEW_USER_GROUP_ID=$(ask_integer_input '请输入新用户权限组ID（直连组）' '2')
      ;;
    *)
      ;;
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

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    candidate_array+=("$path")
  done < <(collect_candidates "$panel")

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
  local feature="$2"
  local target="$3"
  local file="$4"

  PATCH_USER_OLD_AFTER_MINUTES="${PATCH_USER_OLD_AFTER_MINUTES:-5}" \
  PATCH_OLD_USER_GROUP_ID="${PATCH_OLD_USER_GROUP_ID:-1}" \
  PATCH_NEW_USER_GROUP_ID="${PATCH_NEW_USER_GROUP_ID:-2}" \
  php /dev/stdin "$panel" "$feature" "$target" "$file" <<'PHP'
<?php
$panel = $argv[1] ?? '';
$feature = $argv[2] ?? '';
$target = $argv[3] ?? '';
$file = $argv[4] ?? '';
$userOldAfterMinutes = (int) (getenv('PATCH_USER_OLD_AFTER_MINUTES') !== false ? getenv('PATCH_USER_OLD_AFTER_MINUTES') : 5);
$oldUserGroupId = (int) (getenv('PATCH_OLD_USER_GROUP_ID') !== false ? getenv('PATCH_OLD_USER_GROUP_ID') : 1);
$newUserGroupId = (int) (getenv('PATCH_NEW_USER_GROUP_ID') !== false ? getenv('PATCH_NEW_USER_GROUP_ID') : 2);
$code = @file_get_contents($file);
if ($code === false) {
    fwrite(STDERR, "读取文件失败：{$file}\n");
    exit(1);
}

$placeholderReplacements = [
    '__USER_OLD_AFTER_MINUTES__' => (string) $userOldAfterMinutes,
    '__OLD_USER_GROUP_ID__' => (string) $oldUserGroupId,
    '__NEW_USER_GROUP_ID__' => (string) $newUserGroupId,
];

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

function insert_before_last_class_brace_or_fail(string $code, string $insert, string $label): string
{
    if (!preg_match('/\}\s*$/s', $code, $matches, PREG_OFFSET_CAPTURE)) {
        fwrite(STDERR, "未找到类结束位置：{$label}\n");
        exit(2);
    }

    $newline = strpos($code, "\r\n") !== false ? "\r\n" : "\n";
    $pos = $matches[0][1];
    $prefix = rtrim(substr($code, 0, $pos), "\r\n");
    $suffix = substr($code, $pos);
    $insert = str_replace(["\r\n", "\n"], $newline, trim($insert, "\r\n"));

    return $prefix . $newline . $newline . $insert . $newline . $suffix;
}

if ($panel === 'v2board' && $feature === 'group_plan_limit' && $target === 'plan_controller') {
    $hasPlanDetailNoCache = strpos($code, <<<'CODE'
            ])->header('Cache-Control', 'private, no-store, no-cache, must-revalidate, max-age=0')
                ->header('Pragma', 'no-cache')
                ->header('Expires', '0')
                ->header('Vary', 'Authorization');
CODE) !== false;

    $hasPlanListNoCache = strpos($code, <<<'CODE'
        ])->header('Cache-Control', 'private, no-store, no-cache, must-revalidate, max-age=0')
            ->header('Pragma', 'no-cache')
            ->header('Expires', '0')
            ->header('Vary', 'Authorization');
CODE) !== false;

    if (
        strpos($code, 'private const USER_OLD_AFTER_MINUTES') !== false &&
        strpos($code, "->where('group_id', \$allowedGroupId)") !== false &&
        strpos($code, 'private function getAllowedGroupId(User $user): int') !== false &&
        $hasPlanDetailNoCache &&
        $hasPlanListNoCache
    ) {
        echo "already_patched\n";
        exit(0);
    }

    if (strpos($code, 'private const USER_OLD_AFTER_MINUTES') === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
class PlanController extends Controller
{
    public function fetch(Request $request)
CODE,
            strtr(<<<'CODE'
class PlanController extends Controller
{
    // 注册满多少分钟后视为老用户，可自行修改
    private const USER_OLD_AFTER_MINUTES = __USER_OLD_AFTER_MINUTES__;
    // 老用户对应权限组（专线组）
    private const OLD_USER_GROUP_ID = __OLD_USER_GROUP_ID__;
    // 新用户对应权限组（直连组）
    private const NEW_USER_GROUP_ID = __NEW_USER_GROUP_ID__;

    public function fetch(Request $request)
CODE, $placeholderReplacements),
            'v2board-plan-class-header'
        );
    }

    if (strpos($code, '$allowedGroupId = $this->getAllowedGroupId($user);') === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
        $user = User::find($request->user['id']);
        if ($request->input('id')) {
CODE,
            <<<'CODE'
        $user = User::find($request->user['id']);
        if (!$user) {
            abort(500, __('The user does not exist'));
        }
        $allowedGroupId = $this->getAllowedGroupId($user);
        if ($request->input('id')) {
CODE,
            'v2board-plan-fetch-user'
        );
    }

    if (strpos($code, 'if ((int)$plan->group_id !== $allowedGroupId) {') === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
            if (!$plan) {
                abort(500, __('Subscription plan does not exist'));
            }
            if ((!$plan->show && !$plan->renew) || (!$plan->show && $user->plan_id !== $plan->id)) {
                abort(500, __('Subscription plan does not exist'));
            }
CODE,
            <<<'CODE'
            if (!$plan) {
                abort(500, __('Subscription plan does not exist'));
            }
            if ((int)$plan->group_id !== $allowedGroupId) {
                abort(500, __('Subscription plan does not exist'));
            }
            if ((!$plan->show && !$plan->renew) || (!$plan->show && $user->plan_id !== $plan->id)) {
                abort(500, __('Subscription plan does not exist'));
            }
CODE,
            'v2board-plan-detail-group-check'
        );
    }

    if (strpos($code, "->where('group_id', \$allowedGroupId)") === false) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
        $plans = Plan::where('show', 1)
            ->orderBy('sort', 'ASC')
            ->get();
CODE,
            <<<'CODE'
        $plans = Plan::where('show', 1)
            ->where('group_id', $allowedGroupId)
            ->orderBy('sort', 'ASC')
            ->get();
CODE,
            'v2board-plan-list-filter'
        );
    }

    if (!$hasPlanDetailNoCache) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
            return response([
                'data' => $plan
            ]);
CODE,
            <<<'CODE'
            return response([
                'data' => $plan
            ])->header('Cache-Control', 'private, no-store, no-cache, must-revalidate, max-age=0')
                ->header('Pragma', 'no-cache')
                ->header('Expires', '0')
                ->header('Vary', 'Authorization');
CODE,
            'v2board-plan-detail-no-cache'
        );
    }

    if (!$hasPlanListNoCache) {
        $code = replace_once_or_fail(
            $code,
            <<<'CODE'
        return response([
            'data' => $plans
        ]);
CODE,
            <<<'CODE'
        return response([
            'data' => $plans
        ])->header('Cache-Control', 'private, no-store, no-cache, must-revalidate, max-age=0')
            ->header('Pragma', 'no-cache')
            ->header('Expires', '0')
            ->header('Vary', 'Authorization');
CODE,
            'v2board-plan-list-no-cache'
        );
    }

    if (strpos($code, 'private function getAllowedGroupId(User $user): int') === false) {
        $code = insert_before_last_class_brace_or_fail(
            $code,
            <<<'CODE'
    private function getAllowedGroupId(User $user): int
    {
        $oldAfterMinutes = max(self::USER_OLD_AFTER_MINUTES, 0);
        $oldUserGroupId = self::OLD_USER_GROUP_ID;
        $newUserGroupId = self::NEW_USER_GROUP_ID;

        if (!$user->created_at) {
            return $newUserGroupId;
        }

        $cutoffTimestamp = time() - ($oldAfterMinutes * 60);
        return (int) $user->created_at <= $cutoffTimestamp ? $oldUserGroupId : $newUserGroupId;
    }
CODE,
            'v2board-plan-helper-method'
        );
    }

    file_put_contents($file, $code);
    echo "patched\n";
    exit(0);
}

if ($panel === 'v2board' && $feature === 'group_plan_limit' && $target === 'order_controller') {
    if (
        strpos($code, 'private const USER_OLD_AFTER_MINUTES') !== false &&
        strpos($code, '当前账号暂时无法购买该套餐') !== false &&
        strpos($code, 'private function getAllowedGroupId(User $user): int') !== false
    ) {
        echo "already_patched\n";
        exit(0);
    }

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
class OrderController extends Controller
{
    public function fetch(Request $request)
CODE,
        strtr(<<<'CODE'
class OrderController extends Controller
{
    // 注册满多少分钟后视为老用户，可自行修改
    private const USER_OLD_AFTER_MINUTES = __USER_OLD_AFTER_MINUTES__;
    // 老用户对应权限组（专线组）
    private const OLD_USER_GROUP_ID = __OLD_USER_GROUP_ID__;
    // 新用户对应权限组（直连组）
    private const NEW_USER_GROUP_ID = __NEW_USER_GROUP_ID__;

    public function fetch(Request $request)
CODE, $placeholderReplacements),
        'v2board-order-class-header'
    );

    $code = replace_once_or_fail(
        $code,
        <<<'CODE'
        $plan = $planService->plan;
        $user = User::find($request->user['id']);

        if (!$plan) {
            abort(500, __('Subscription plan does not exist'));
        }
CODE,
        <<<'CODE'
        $plan = $planService->plan;
        $user = User::find($request->user['id']);

        if (!$user) {
            abort(500, __('The user does not exist'));
        }
        if (!$plan) {
            abort(500, __('Subscription plan does not exist'));
        }
        if ((int)$plan->group_id !== $this->getAllowedGroupId($user)) {
            abort(500, '当前账号暂时无法购买该套餐');
        }
CODE,
        'v2board-order-group-check'
    );

    $code = insert_before_last_class_brace_or_fail(
        $code,
        <<<'CODE'
    private function getAllowedGroupId(User $user): int
    {
        $oldAfterMinutes = max(self::USER_OLD_AFTER_MINUTES, 0);
        $oldUserGroupId = self::OLD_USER_GROUP_ID;
        $newUserGroupId = self::NEW_USER_GROUP_ID;

        if (!$user->created_at) {
            return $newUserGroupId;
        }

        $cutoffTimestamp = time() - ($oldAfterMinutes * 60);
        return (int) $user->created_at <= $cutoffTimestamp ? $oldUserGroupId : $newUserGroupId;
    }
CODE,
        'v2board-order-helper-method'
    );

    file_put_contents($file, $code);
    echo "patched\n";
    exit(0);
}

fwrite(STDERR, "不支持的补丁目标：{$panel} / {$feature} / {$target}\n");
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

patch_single_file() {
  local panel="$1"
  local feature="$2"
  local target="$3"
  local file="$4"
  [ -f "$file" ] || fail "未找到目标文件：$file"

  log ''
  log "准备修改：$file"
  backup_file "$file"

  local result status
  set +e
  result=$(apply_patch_by_php "$panel" "$feature" "$target" "$file" 2>&1)
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
  local feature="$2"
  local root="$3"

  case "$panel:$feature" in
    v2board:group_plan_limit)
      patch_single_file "$panel" "$feature" 'plan_controller' "$root/app/Http/Controllers/V1/User/PlanController.php"
      patch_single_file "$panel" "$feature" 'order_controller' "$root/app/Http/Controllers/V1/User/OrderController.php"
      if ask_yes_no '是否立即清理 Laravel 缓存？' 'y'; then
        clear_laravel_cache "$root"
      fi
      ;;
    *)
      fail "当前不支持该补丁组合：$panel / $feature"
      ;;
  esac

  log ''
  log '如果线上仍未生效，请手动重载 PHP-FPM 或重启容器，以刷新 OPcache。'
}

main() {
  require_php
  choose_panel
  choose_root "$PANEL_CHOICE"
  choose_feature "$PANEL_CHOICE"
  choose_feature_options "$PANEL_CHOICE" "$FEATURE_CHOICE"

  log ''
  log "已选择功能：$FEATURE_LABEL"
  if [ "${FEATURE_CHOICE:-}" = 'group_plan_limit' ]; then
    log "老用户判定分钟数：${PATCH_USER_OLD_AFTER_MINUTES}"
    log "老用户组ID：${PATCH_OLD_USER_GROUP_ID}"
    log "新用户组ID：${PATCH_NEW_USER_GROUP_ID}"
  fi

  patch_project "$PANEL_CHOICE" "$FEATURE_CHOICE" "$ROOT_PATH"

  log ''
  log '处理完成。'
}

main "$@"

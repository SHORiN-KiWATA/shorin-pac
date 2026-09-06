#!/usr/bin/env bash
# shorin-pac 的共享库：AI 供应商层 + 配置界面。被 pac / pacr 以 `source` 方式加载。
#
# 设计要点：
# - 只做“一次性补全”：给一份 system 提示词和一份 user 文本，拿回一段文本。
#   没有上下文、记忆、流式；所有后端行为一致。
# - 后端（protocol）：
#     openai-chat   任何 OpenAI Chat Completions 兼容 HTTP 端点（含 opencode zen 公共 key）
#     openai-responses  OpenAI Responses API 端点
#     anthropic     Anthropic Messages HTTP 端点
#     claude-code   本机 claude CLI（订阅额度）
#     codex         本机 codex CLI
#     antigravity   本机 agy CLI
#     opencode      本机 opencode CLI
#     miyu          本机 miyu（交给 Miyu 自己的模型路由）
# - 供应商来源：用户自己的 ~/.config/shorin-pac/config.json、Miyu 的 ~/.miyu/config/config.jsonc
#   （只读导入，id 前缀 miyu/）、内置（public 公共 key 与检测到的本机 CLI）。
# - 依赖：bash 4+、jq、curl。fzf 只在交互选择时需要。
#
# 对外函数（其余均为内部函数）：
#   ai_init                       初始化路径与配置
#   ai_all_providers              NDJSON 输出所有可用供应商
#   ai_resolve [provider:model]   解析当前选择，设置 AI_PROVIDER_ID / AI_MODEL / AI_PROVIDER_JSON
#   ai_backend_has_tools          当前后端是否可用只读工具（返回码）
#   ai_complete SYS USER OUT [WORKDIR]         纯文本补全
#   ai_json_complete SYS USER OUT [WORKDIR] [JQ_CHECK]   补全 + 抽取 JSON + 校验（失败重试一次）
#   ai_select_interactive         fzf 选择供应商/模型并写入配置
#   ai_describe_selection         一行文字描述当前选择
#   config_main [子命令]          `pac config` 入口（菜单 / select / show / set / add / remove / test / path）

[[ -n "${SHORIN_PAC_AI_LOADED:-}" ]] && return 0
SHORIN_PAC_AI_LOADED=1

AI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_PROMPT_DIR="$(cd "${AI_LIB_DIR}/.." && pwd)/prompts"
AI_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/shorin-pac"
AI_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/shorin-pac"
AI_CONFIG_FILE="${AI_CONFIG_DIR}/config.json"
AI_MIYU_HOME="${MIYU_HOME:-$HOME/.miyu}"
AI_MIYU_CONFIG="${AI_MIYU_HOME}/config/config.jsonc"

AI_HTTP_TIMEOUT="${SHORIN_PAC_AI_HTTP_TIMEOUT:-600}"
AI_CLI_TIMEOUT="${SHORIN_PAC_AI_CLI_TIMEOUT:-900}"
AI_MODELS_CACHE_TTL_MIN=1440
AI_MAX_OUTPUT_BYTES=$((4 * 1024 * 1024))

AI_PROVIDER_ID=""
AI_MODEL=""
AI_PROVIDER_JSON=""
AI_ALLOW_TOOLS=true
AI_IMPORT_MIYU=true
AI_LAST_ERROR=""
AI_HEARTBEAT_PID=""

# 语言：与 pac 一致，按消息类别 locale 判断
AI_MESSAGE_LOCALE="${SHORIN_PAC_LOCALE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}}"
if [[ "${AI_MESSAGE_LOCALE,,}" == *zh* ]]; then
    AI_IS_CN=true
else
    AI_IS_CN=false
fi

ai_msg() {
    # ai_msg KEY ：极简双语文案
    local key="$1"
    if $AI_IS_CN; then
        case "$key" in
            THINKING) printf '%s' "AI 正在分析" ;;
            NO_PROVIDER) printf '%s' "未找到可用的 AI 供应商。请运行 pac config 配置，或安装 claude / codex / agy / opencode / miyu 之一。" ;;
            USING) printf '%s' "使用 AI 供应商：" ;;
            AUTO_HINT) printf '%s' "（自动选择，可用 pac config 更改）" ;;
            ERR_DEPS) printf '%s' "错误：AI 功能需要 curl 和 jq。" ;;
            ERR_HTTP) printf '%s' "错误：AI 接口请求失败。" ;;
            ERR_CLI) printf '%s' "错误：AI 命令行后端执行失败。" ;;
            ERR_EMPTY) printf '%s' "错误：AI 返回了空响应。" ;;
            ERR_JSON) printf '%s' "错误：AI 返回的内容不是有效的 JSON 结果。" ;;
            RETRY_JSON) printf '%s' "AI 输出格式不对，正在重试一次..." ;;
            ERR_BINARY) printf '%s' "错误：未找到命令：" ;;
            ERR_NO_KEY) printf '%s' "错误：该供应商没有配置 API key：" ;;
            SELECT_HEADER) printf '%s' "选择 AI 供应商 / 模型 | Enter:选择 | Esc:取消" ;;
            SELECTED) printf '%s' "已选择：" ;;
            RATE_LIMIT) printf '%s' "供应商限流（429）。公共 key 额度有限，建议在 pac config 里配置自己的供应商。" ;;
            *) printf '%s' "$key" ;;
        esac
    else
        case "$key" in
            THINKING) printf '%s' "AI is analyzing" ;;
            NO_PROVIDER) printf '%s' "No usable AI provider found. Run 'pac config', or install one of claude / codex / agy / opencode / miyu." ;;
            USING) printf '%s' "AI provider:" ;;
            AUTO_HINT) printf '%s' "(auto-selected; change with pac config)" ;;
            ERR_DEPS) printf '%s' "Error: AI features require curl and jq." ;;
            ERR_HTTP) printf '%s' "Error: AI API request failed." ;;
            ERR_CLI) printf '%s' "Error: AI CLI backend failed." ;;
            ERR_EMPTY) printf '%s' "Error: AI returned an empty response." ;;
            ERR_JSON) printf '%s' "Error: AI did not return a valid JSON result." ;;
            RETRY_JSON) printf '%s' "AI output was malformed, retrying once..." ;;
            ERR_BINARY) printf '%s' "Error: command not found:" ;;
            ERR_NO_KEY) printf '%s' "Error: no API key configured for provider:" ;;
            SELECT_HEADER) printf '%s' "Select AI provider / model | Enter:select | Esc:cancel" ;;
            SELECTED) printf '%s' "Selected:" ;;
            RATE_LIMIT) printf '%s' "Provider rate limited (429). The public key has a small quota; configure your own provider in 'pac config'." ;;
            *) printf '%s' "$key" ;;
        esac
    fi
}

ai_lang_name() {
    if $AI_IS_CN; then printf 'Simplified Chinese (简体中文)'; else printf 'English'; fi
}

# ------------------------------------------------------------------------------
# 配置文件
# ------------------------------------------------------------------------------

ai_init() {
    command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || {
        echo "$(ai_msg ERR_DEPS)" >&2
        return 1
    }
    mkdir -p "$AI_CONFIG_DIR" "$AI_CACHE_DIR"
    if [[ ! -s "$AI_CONFIG_FILE" ]]; then
        ai_config_write '{"version":1,"selected":{"provider":"","model":""},"allow_tools":true,"import_miyu":true,"providers":[]}'
    fi
    AI_ALLOW_TOOLS=$(ai_config_get '.allow_tools // true')
    AI_IMPORT_MIYU=$(ai_config_get '.import_miyu // true')
    return 0
}

ai_config_get() {
    # ai_config_get <jq 表达式>
    jq -r "$1" "$AI_CONFIG_FILE" 2>/dev/null
}

ai_config_write() {
    # ai_config_write <完整 JSON 文本>
    local tmp="${AI_CONFIG_FILE}.tmp.$$"
    printf '%s\n' "$1" | jq . > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$AI_CONFIG_FILE"
}

ai_config_update() {
    # ai_config_update <jq 过滤器> [jq 参数...]：原子更新配置
    local filter="$1"; shift
    local updated
    updated=$(jq "$@" "$filter" "$AI_CONFIG_FILE") || return 1
    ai_config_write "$updated"
}

# ------------------------------------------------------------------------------
# JSONC → JSON（Miyu 配置带注释；jq 不认注释）
# 处理 // 行注释与 /* */ 块注释，跳过字符串内部；不处理尾随逗号（Miyu 不会写出）。
# ------------------------------------------------------------------------------
ai_strip_jsonc() {
    awk '
    BEGIN { blk = 0 }
    {
        s = $0; out = ""; n = length(s); i = 1; instr = 0; esc = 0
        while (i <= n) {
            c = substr(s, i, 1); d = substr(s, i, 2)
            if (blk) {
                if (d == "*/") { blk = 0; i += 2 } else { i++ }
                continue
            }
            if (instr) {
                out = out c
                if (esc) { esc = 0 }
                else if (c == "\\") { esc = 1 }
                else if (c == "\"") { instr = 0 }
                i++; continue
            }
            if (c == "\"") { instr = 1; out = out c; i++; continue }
            if (d == "//") { break }
            if (d == "/*") { blk = 1; i += 2; continue }
            out = out c; i++
        }
        print out
    }'
}

# ------------------------------------------------------------------------------
# 供应商来源
# 每个供应商是一个 JSON 对象：
#   {id, source, display_name, protocol, base_url, api_key, models[], default_model, binary}
# ------------------------------------------------------------------------------

ai_normalize_provider() {
    # stdin: 原始供应商 JSON；stdout: 规范化后的 JSON（协议推断、模型去重）
    jq -c '
        def norm_protocol:
            (.protocol // "" | ascii_downcase) as $p
            | if ($p == "" or $p == "auto") then
                (if ((.base_url // "") | test("anthropic"; "i")) then "anthropic" else "openai-chat" end)
              elif ($p == "openai-responses" or $p == "responses") then "openai-responses"
              elif ($p == "anthropic-messages" or $p == "claude" or $p == "claude-messages") then "anthropic"
              elif ($p == "claude-code-cli") then "claude-code"
              elif ($p == "antigravity-cli" or $p == "agy") then "antigravity"
              elif ($p == "codex-cli") then "codex"
              else $p end;
        .protocol = norm_protocol
        | .models = (((.models // []) + (if ((.default_model // "") != "") then [.default_model] else [] end)) | unique)
        | .default_model = (if ((.default_model // "") != "") then .default_model else (.models[0] // "") end)
        | .base_url = ((.base_url // "") | sub("/+$"; ""))
        | .api_key = (.api_key // "")
        | .binary = (.binary // "")
        | .display_name = (.display_name // .id)
    '
}

ai_user_providers() {
    [[ -s "$AI_CONFIG_FILE" ]] || return 0
    jq -c '.providers[]? | .source = "user"' "$AI_CONFIG_FILE" 2>/dev/null | while IFS= read -r line; do
        printf '%s\n' "$line" | ai_normalize_provider
    done
}

ai_miyu_providers() {
    [[ "$AI_IMPORT_MIYU" == true && -r "$AI_MIYU_CONFIG" ]] || return 0
    local json
    json=$(ai_strip_jsonc < "$AI_MIYU_CONFIG" | jq -c . 2>/dev/null) || return 0
    printf '%s' "$json" | jq -c '
        . as $root
        | .providers[]?
        | select((.enabled // true) == true)
        | (.protocol // "" | ascii_downcase) as $p
        | . + {
            id: ("miyu/" + .id),
            source: "miyu",
            display_name: ((.display_name // .id) + " (Miyu)"),
            binary: (
                if $p == "claude-code" then ($root.plugins.claude_code.binary // "")
                elif $p == "antigravity" then ($root.plugins.antigravity.binary // "")
                elif $p == "codex" then ($root.plugins.codex.binary // "")
                else "" end)
        }
        | select(((.models // []) | length) > 0 or ((.default_model // "") != "") or ($p == "claude-code" or $p == "antigravity" or $p == "codex"))
    ' 2>/dev/null | while IFS= read -r line; do
        printf '%s\n' "$line" | ai_normalize_provider
    done
}

ai_cli_models() {
    # ai_cli_models <protocol>：本机 CLI 的模型列表，带缓存；失败回退到预置列表
    # 注意：bash 的 local 先展开整行再赋值，所以不能在同一行里引用刚声明的变量
    local proto="$1"
    local cache="${AI_CACHE_DIR}/models-${proto}.txt"
    local fresh=""
    if [[ -s "$cache" ]] && [[ -z "$(find "$cache" -mmin +${AI_MODELS_CACHE_TTL_MIN} 2>/dev/null)" ]]; then
        cat "$cache"
        return 0
    fi
    case "$proto" in
        codex)
            fresh=$(timeout 20 codex debug models 2>/dev/null | jq -r '.models[]? | select(.visibility != "hide") | .slug' 2>/dev/null || true)
            ;;
        antigravity)
            fresh=$(timeout 20 agy models 2>/dev/null | awk -F'\t' 'NF >= 1 && $1 !~ /^Fetching/ && $1 != "" { print $1 }' || true)
            ;;
        opencode)
            fresh=$(timeout 20 opencode models 2>/dev/null | awk 'NF { print $1 }' || true)
            ;;
    esac
    if [[ -n "$fresh" ]]; then
        printf '%s\n' "$fresh" > "$cache"
        printf '%s\n' "$fresh"
        return 0
    fi
    case "$proto" in
        codex) printf '%s\n' gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4-mini ;;
        antigravity) printf '%s\n' gemini-3.8-flash-high gemini-3.8-flash-medium gemini-3.8-flash-low gemini-3.1-pro-high claude-sonnet-4-6 claude-opus-4-6-thinking gpt-oss-120b-medium ;;
        opencode) printf '%s\n' opencode/big-pickle opencode/mimo-v2.5-free ;;
    esac
}

ai_builtin_providers() {
    # 内置：公共 key 永远存在；CLI 后端只在命令存在时出现。
    jq -cn '{id:"public", source:"builtin", display_name:"OpenCode Zen public key (rate limited)", protocol:"openai-chat",
             base_url:"https://opencode.ai/zen/v1", api_key:"public", models:["big-pickle","mimo-v2.5-free"], default_model:"big-pickle"}'
    if command -v claude >/dev/null 2>&1; then
        jq -cn '{id:"claude-code", source:"builtin", display_name:"Claude Code CLI", protocol:"claude-code",
                 models:["sonnet","opus","haiku","fable"], default_model:"sonnet"}'
    fi
    if command -v codex >/dev/null 2>&1; then
        jq -cn --argjson m "$(ai_cli_models codex | jq -Rn '[inputs]')" \
            '{id:"codex", source:"builtin", display_name:"Codex CLI", protocol:"codex", models:$m, default_model:($m[0] // "gpt-5.6-terra")}'
    fi
    if command -v agy >/dev/null 2>&1; then
        jq -cn --argjson m "$(ai_cli_models antigravity | jq -Rn '[inputs]')" \
            '{id:"antigravity", source:"builtin", display_name:"Antigravity CLI (agy)", protocol:"antigravity", models:$m, default_model:($m[0] // "gemini-3.8-flash-high")}'
    fi
    if command -v opencode >/dev/null 2>&1; then
        jq -cn --argjson m "$(ai_cli_models opencode | jq -Rn '[inputs]')" \
            '{id:"opencode", source:"builtin", display_name:"opencode CLI", protocol:"opencode", models:$m, default_model:($m[0] // "opencode/big-pickle")}'
    fi
    if command -v miyu >/dev/null 2>&1; then
        jq -cn '{id:"miyu", source:"builtin", display_name:"Miyu (uses Miyu current model)", protocol:"miyu", models:["auto"], default_model:"auto"}'
    fi
}

ai_all_providers() {
    # NDJSON；同 id 先到先得：用户配置 > Miyu 导入 > 内置
    {
        ai_user_providers
        ai_miyu_providers
        ai_builtin_providers | while IFS= read -r line; do printf '%s\n' "$line" | ai_normalize_provider; done
    } | jq -c -s 'unique_by(.id) as $u | [.[] | .id] | unique as $ids
                  | reduce $ids[] as $id ([]; . + [ $u[] | select(.id == $id) ][0:1])
                  | .[]' 2>/dev/null
}

ai_get_provider() {
    # ai_get_provider <id> → JSON 或失败
    local id="$1" found
    found=$(ai_all_providers | jq -c --arg id "$id" 'select(.id == $id)' | head -n1)
    [[ -n "$found" ]] || return 1
    printf '%s' "$found"
}

ai_resolve_key() {
    # ai_resolve_key <api_key 字段>：逗号多 key 取第一个；$env:NAME 取环境变量
    local raw="$1" first name
    first="${raw%%,*}"
    first="${first#"${first%%[![:space:]]*}"}"
    first="${first%"${first##*[![:space:]]}"}"
    if [[ "$first" == '$env:'* ]]; then
        name="${first#'$env:'}"
        printf '%s' "${!name:-}"
    else
        printf '%s' "$first"
    fi
}

ai_provider_is_cli() {
    case "$1" in
        claude-code|codex|antigravity|opencode|miyu) return 0 ;;
        *) return 1 ;;
    esac
}

ai_provider_binary() {
    # ai_provider_binary <provider JSON> → 可执行文件名/路径
    local json="$1" proto bin
    proto=$(jq -r '.protocol' <<< "$json")
    bin=$(jq -r '.binary // ""' <<< "$json")
    if [[ -n "$bin" ]]; then printf '%s' "$bin"; return; fi
    case "$proto" in
        claude-code) printf 'claude' ;;
        codex) printf 'codex' ;;
        antigravity) printf 'agy' ;;
        opencode) printf 'opencode' ;;
        miyu) printf 'miyu' ;;
    esac
}

# ------------------------------------------------------------------------------
# 选择解析
# 优先级：显式参数（provider:model）> 环境变量 SHORIN_PAC_AI > 配置文件 > 自动探测
# ------------------------------------------------------------------------------

ai_auto_provider_id() {
    local id
    for id in opencode claude-code codex antigravity miyu; do
        if ai_all_providers | jq -e --arg id "$id" 'select(.id == $id)' >/dev/null 2>&1; then
            printf '%s' "$id"
            return 0
        fi
    done
    printf 'public'
}

ai_resolve() {
    # ai_resolve [provider[:model]]
    local spec="${1:-${SHORIN_PAC_AI:-}}" provider model auto=false
    if [[ -n "$spec" ]]; then
        provider="${spec%%:*}"
        model=""
        [[ "$spec" == *:* ]] && model="${spec#*:}"
    else
        provider=$(ai_config_get '.selected.provider // ""')
        model=$(ai_config_get '.selected.model // ""')
    fi
    if [[ -z "$provider" ]]; then
        provider=$(ai_auto_provider_id)
        model=""
        auto=true
    fi
    if ! AI_PROVIDER_JSON=$(ai_get_provider "$provider"); then
        # 配置里选的供应商已不可用（例如 CLI 被卸载）：退回自动探测
        provider=$(ai_auto_provider_id)
        model=""
        auto=true
        AI_PROVIDER_JSON=$(ai_get_provider "$provider") || {
            echo "$(ai_msg NO_PROVIDER)" >&2
            return 1
        }
    fi
    if [[ -z "$model" ]]; then
        model=$(jq -r '.default_model // ""' <<< "$AI_PROVIDER_JSON")
    fi
    AI_PROVIDER_ID="$provider"
    AI_MODEL="$model"
    AI_AUTO_SELECTED="$auto"
    return 0
}

ai_describe_selection() {
    local name
    name=$(jq -r '.display_name' <<< "$AI_PROVIDER_JSON")
    if [[ "$AI_MODEL" == "auto" ]]; then
        printf '%s' "$name"
    else
        printf '%s · %s' "$name" "$AI_MODEL"
    fi
    if [[ "${AI_AUTO_SELECTED:-false}" == true ]]; then
        printf ' %s' "$(ai_msg AUTO_HINT)"
    fi
}

ai_backend_has_tools() {
    [[ "$AI_ALLOW_TOOLS" == true ]] || return 1
    ai_provider_is_cli "$(jq -r '.protocol' <<< "$AI_PROVIDER_JSON")"
}

# ------------------------------------------------------------------------------
# 心跳：长时间等待时每 10 秒在 stderr 打一行
# ------------------------------------------------------------------------------
ai_heartbeat_start() {
    local label="${1:-$(ai_msg THINKING)}"
    (
        trap 'exit 0' TERM INT
        started=$SECONDS
        while true; do
            sleep 10 &
            wait $! || exit 0
            printf '\033[90m   %s (%ss)\033[0m\n' "$label" "$((SECONDS - started))" >&2
        done
    ) &
    AI_HEARTBEAT_PID=$!
}

ai_heartbeat_stop() {
    if [[ -n "$AI_HEARTBEAT_PID" ]]; then
        kill "$AI_HEARTBEAT_PID" 2>/dev/null || true
        wait "$AI_HEARTBEAT_PID" 2>/dev/null || true
        AI_HEARTBEAT_PID=""
    fi
}

ai_sanitize() {
    # 去掉 ANSI 与危险控制字符（AI 输出会被原样打印到终端）
    sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g' | tr -d '\a\b\v\f\r'
}

# ------------------------------------------------------------------------------
# HTTP 后端
# ------------------------------------------------------------------------------

ai_http_post() {
    # ai_http_post URL BODY_FILE RESP_FILE HEADER...
    local url="$1" body="$2" resp="$3"; shift 3
    local -a hdr=()
    local h code
    for h in "$@"; do hdr+=(-H "$h"); done
    code=$(curl --silent --show-error --proto '=https,http' --tlsv1.2 \
        --connect-timeout 15 --max-time "$AI_HTTP_TIMEOUT" \
        --max-filesize "$AI_MAX_OUTPUT_BYTES" \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        --user-agent 'shorin-pac/1' \
        "${hdr[@]}" --data-binary "@${body}" \
        -o "$resp" -w '%{http_code}' "$url" 2>"${resp}.curlerr") || {
        AI_LAST_ERROR="$(cat "${resp}.curlerr" 2>/dev/null)"
        return 1
    }
    AI_HTTP_CODE="$code"
    [[ "$code" =~ ^2 ]]
}

ai_http_error_message() {
    # 从响应体里抠错误信息
    local resp="$1"
    jq -r '(.error.message // .error // .message // empty) | tostring' "$resp" 2>/dev/null | head -c 500
}

ai_http_openai() {
    local sys="$1" user="$2" out="$3"
    local base key url body resp msg
    base=$(jq -r '.base_url' <<< "$AI_PROVIDER_JSON")
    key=$(ai_resolve_key "$(jq -r '.api_key' <<< "$AI_PROVIDER_JSON")")
    [[ -n "$key" ]] || { [[ "$base" == *opencode.ai/zen* ]] && key="public"; }
    [[ -n "$key" ]] || { echo "$(ai_msg ERR_NO_KEY) $AI_PROVIDER_ID" >&2; return 1; }
    body="${out}.req"; resp="${out}.resp"
    jq -n --arg model "$AI_MODEL" --rawfile sys "$sys" --rawfile user "$user" \
        '{model:$model, stream:false, messages:[{role:"system",content:$sys},{role:"user",content:$user}]}' > "$body"
    url="${base}/chat/completions"
    if ! ai_http_post "$url" "$body" "$resp" "Authorization: Bearer ${key}"; then
        # 有些端点要 /v1 前缀，有些不要：404 时换一种再试
        if [[ "${AI_HTTP_CODE:-}" == "404" && "$base" != */v1 ]]; then
            url="${base}/v1/chat/completions"
            ai_http_post "$url" "$body" "$resp" "Authorization: Bearer ${key}" || {
                ai_http_report_failure "$resp"; return 1; }
        else
            ai_http_report_failure "$resp"; return 1
        fi
    fi
    jq -r '.choices[0].message.content // empty' "$resp" 2>/dev/null | ai_sanitize > "$out"
    rm -f "$body" "$resp" "${resp}.curlerr"
    [[ -s "$out" ]] || { echo "$(ai_msg ERR_EMPTY)" >&2; return 1; }
}

ai_http_openai_responses() {
    # OpenAI Responses API：POST {base}/responses，instructions = system，input = user
    local sys="$1" user="$2" out="$3"
    local base key url body resp
    base=$(jq -r '.base_url' <<< "$AI_PROVIDER_JSON")
    key=$(ai_resolve_key "$(jq -r '.api_key' <<< "$AI_PROVIDER_JSON")")
    [[ -n "$key" ]] || { echo "$(ai_msg ERR_NO_KEY) $AI_PROVIDER_ID" >&2; return 1; }
    body="${out}.req"; resp="${out}.resp"
    jq -n --arg model "$AI_MODEL" --rawfile sys "$sys" --rawfile user "$user" \
        '{model:$model, instructions:$sys, input:$user, store:false}' > "$body"
    url="${base}/responses"
    if ! ai_http_post "$url" "$body" "$resp" "Authorization: Bearer ${key}"; then
        if [[ "${AI_HTTP_CODE:-}" == "404" && "$base" != */v1 ]]; then
            url="${base}/v1/responses"
            ai_http_post "$url" "$body" "$resp" "Authorization: Bearer ${key}" || { ai_http_report_failure "$resp"; return 1; }
        else
            ai_http_report_failure "$resp"; return 1
        fi
    fi
    jq -r '(.output_text // empty), ([.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join(""))' "$resp" 2>/dev/null \
        | awk 'NF' | head -c "$AI_MAX_OUTPUT_BYTES" | ai_sanitize > "$out"
    rm -f "$body" "$resp" "${resp}.curlerr"
    [[ -s "$out" ]] || { echo "$(ai_msg ERR_EMPTY)" >&2; return 1; }
}

ai_http_anthropic() {
    local sys="$1" user="$2" out="$3"
    local base key url body resp
    base=$(jq -r '.base_url' <<< "$AI_PROVIDER_JSON")
    [[ -n "$base" ]] || base="https://api.anthropic.com"
    key=$(ai_resolve_key "$(jq -r '.api_key' <<< "$AI_PROVIDER_JSON")")
    [[ -n "$key" ]] || { echo "$(ai_msg ERR_NO_KEY) $AI_PROVIDER_ID" >&2; return 1; }
    body="${out}.req"; resp="${out}.resp"
    jq -n --arg model "$AI_MODEL" --rawfile sys "$sys" --rawfile user "$user" \
        '{model:$model, max_tokens:8192, system:$sys, messages:[{role:"user",content:$user}]}' > "$body"
    if [[ "$base" == */v1 ]]; then url="${base}/messages"; else url="${base}/v1/messages"; fi
    ai_http_post "$url" "$body" "$resp" "x-api-key: ${key}" "anthropic-version: 2023-06-01" || {
        ai_http_report_failure "$resp"; return 1; }
    jq -r '[.content[]? | select(.type == "text") | .text] | join("")' "$resp" 2>/dev/null | ai_sanitize > "$out"
    rm -f "$body" "$resp" "${resp}.curlerr"
    [[ -s "$out" ]] || { echo "$(ai_msg ERR_EMPTY)" >&2; return 1; }
}

ai_http_report_failure() {
    local resp="$1" msg
    msg=$(ai_http_error_message "$resp")
    if [[ "${AI_HTTP_CODE:-}" == "429" ]]; then
        echo "$(ai_msg RATE_LIMIT)" >&2
    fi
    echo "$(ai_msg ERR_HTTP) HTTP ${AI_HTTP_CODE:-?} ${msg:-$AI_LAST_ERROR}" >&2
    rm -f "${resp}.curlerr"
}

# ------------------------------------------------------------------------------
# CLI 后端
# 约定：cwd = WORKDIR（AUR 构建目录 / 家目录），提示词从 stdin 或参数进，
# 结果文本写到 OUT。工具只开只读。
# ------------------------------------------------------------------------------

ai_cli_run() {
    # ai_cli_run LOG WORKDIR CMD...：带超时执行，stderr 进 LOG，stdout 由调用方接管
    local log="$1" workdir="$2"; shift 2
    (cd "$workdir" && timeout --foreground "$AI_CLI_TIMEOUT" "$@" 2>>"$log")
}

ai_cli_fail() {
    local log="$1"
    echo "$(ai_msg ERR_CLI)" >&2
    if [[ -s "$log" ]]; then
        grep -v -E '^\s*$' "$log" | tail -n 8 | ai_sanitize | sed 's/^/  /' >&2
    fi
    return 1
}

ai_cli_claude() {
    local sys="$1" user="$2" out="$3" workdir="$4" bin log
    bin=$(ai_provider_binary "$AI_PROVIDER_JSON")
    command -v "$bin" >/dev/null 2>&1 || { echo "$(ai_msg ERR_BINARY) $bin" >&2; return 1; }
    log="${out}.log"; : > "$log"
    local -a args=(-p --output-format text --no-session-persistence --strict-mcp-config --model "$AI_MODEL" --system-prompt "$(<"$sys")")
    if [[ "$AI_ALLOW_TOOLS" == true ]]; then
        # --tools 限定内置工具集（没有 Edit/Write），--allowedTools 决定无头模式下哪些调用免审批放行；
        # 不用 --disallowedTools：它对不存在的工具名会直接报错退出。
        args+=(--tools "Read,Glob,Grep,WebSearch,WebFetch,Bash"
               --allowedTools "Read,Glob,Grep,WebSearch,WebFetch,Bash(ls:*),Bash(find:*),Bash(du:*),Bash(cat:*),Bash(stat:*),Bash(file:*),Bash(pacman -Q*),Bash(curl -s*)")
    else
        args+=(--tools "")
    fi
    ai_cli_run "$log" "$workdir" "$bin" "${args[@]}" < "$user" | ai_sanitize > "$out" || ai_cli_fail "$log"
    [[ -s "$out" ]] || ai_cli_fail "$log"
}

ai_cli_codex() {
    local sys="$1" user="$2" out="$3" workdir="$4" bin log
    bin=$(ai_provider_binary "$AI_PROVIDER_JSON")
    command -v "$bin" >/dev/null 2>&1 || { echo "$(ai_msg ERR_BINARY) $bin" >&2; return 1; }
    log="${out}.log"; : > "$log"
    local -a args=(exec --ephemeral --ignore-user-config --skip-git-repo-check --color never
                   -s read-only -C "$workdir" -m "$AI_MODEL"
                   -c "model_instructions_file=\"${sys}\"" -c "project_doc_max_bytes=0"
                   -o "$out" -)
    # codex 的 stdout 是进度流，最终答复走 -o；stdout 一并进日志便于排错
    ai_cli_run "$log" "$workdir" "$bin" "${args[@]}" < "$user" >>"$log" || ai_cli_fail "$log"
    if [[ -s "$out" ]]; then
        ai_sanitize < "$out" > "${out}.clean" && mv -f "${out}.clean" "$out"
    else
        ai_cli_fail "$log"
    fi
}

ai_cli_agy() {
    # agy 的 --print 不读 stdin 文本，只能走 stream-json：一行 user 消息进，事件流出，
    # 取 result 帧的 response。system 提示词与 user 文本合并成一条消息（agy 无 system 参数）。
    local sys="$1" user="$2" out="$3" workdir="$4" bin log payload stream
    bin=$(ai_provider_binary "$AI_PROVIDER_JSON")
    command -v "$bin" >/dev/null 2>&1 || { echo "$(ai_msg ERR_BINARY) $bin" >&2; return 1; }
    log="${out}.log"; : > "$log"
    payload="${out}.payload"; stream="${out}.stream"
    # agy 的输入行是 {"event":"user","message":{"content":[...]}}（不是 claude 的 "type"），
    # 单行载荷上限约 170KB，超出会被静默截尾；证据包过大时先提示。
    jq -n --rawfile sys "$sys" --rawfile user "$user" \
        '{event:"user", message:{content:[{type:"text", text:($sys + "\n\n---\n\n" + $user)}]}}' -c > "$payload"
    printf '\n' >> "$payload"
    if (( $(stat -c %s "$payload") > 170000 )); then
        echo "shorin-pac: warning: prompt exceeds agy's ~170KB stdin budget; the tail may be truncated" >&2
    fi
    local -a args=(--print= --input-format stream-json --output-format stream-json
                   --model "$AI_MODEL" --print-timeout "${AI_CLI_TIMEOUT}s" --add-dir "$workdir")
    if [[ "$AI_ALLOW_TOOLS" == true ]]; then
        args+=(--sandbox --dangerously-skip-permissions)
    else
        args+=(--sandbox)
    fi
    ai_cli_run "$log" "$workdir" "$bin" "${args[@]}" < "$payload" > "$stream" || ai_cli_fail "$log"
    # result 帧：{"event":"result","result":{"status":..,"response":..,"error":..}}
    jq -r 'select(.event == "result") | .result.response // empty' "$stream" 2>/dev/null | ai_sanitize > "$out"
    if [[ ! -s "$out" ]]; then
        # 兜底：把 agent_response 的 text_delta 拼起来
        jq -r 'select(.event == "step_update") | .step_update.agent_response.text_delta // empty' "$stream" 2>/dev/null | tr -d '\n' | ai_sanitize > "$out"
    fi
    if [[ ! -s "$out" ]]; then
        jq -r 'select(.event == "result") | .result.error // empty' "$stream" 2>/dev/null >> "$log"
        ai_cli_fail "$log"
    fi
    rm -f "$payload" "$stream"
}

ai_cli_opencode() {
    local sys="$1" user="$2" out="$3" workdir="$4" bin log
    bin=$(ai_provider_binary "$AI_PROVIDER_JSON")
    command -v "$bin" >/dev/null 2>&1 || { echo "$(ai_msg ERR_BINARY) $bin" >&2; return 1; }
    log="${out}.log"; : > "$log"
    OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
    ai_cli_run "$log" "$workdir" "$bin" run --pure -m "$AI_MODEL" --dir "$workdir" \
        < <(cat "$sys"; printf '\n\n---\n\n'; cat "$user") | ai_sanitize > "$out" || ai_cli_fail "$log"
    [[ -s "$out" ]] || ai_cli_fail "$log"
}

ai_cli_miyu() {
    # miyu --stdout ask：管道输入会拼进提示词，但有 5 万字符上限；超过时改成让 Miyu 自己读文件。
    local sys="$1" user="$2" out="$3" workdir="$4" bin log combined size
    bin=$(ai_provider_binary "$AI_PROVIDER_JSON")
    command -v "$bin" >/dev/null 2>&1 || { echo "$(ai_msg ERR_BINARY) $bin" >&2; return 1; }
    log="${out}.log"; : > "$log"
    combined="${out}.prompt"
    { cat "$sys"; printf '\n\n---\n\n'; cat "$user"; } > "$combined"
    size=$(wc -m < "$combined")
    if (( size <= 45000 )); then
        ai_cli_run "$log" "$workdir" "$bin" --stdout ask < "$combined" | ai_sanitize > "$out" || ai_cli_fail "$log"
    else
        ai_cli_run "$log" "$workdir" "$bin" --stdout ask \
            "The task is in the file ${combined}. Read that file with your file tool and follow every instruction in it exactly. Reply with the requested output only." \
            < /dev/null | ai_sanitize > "$out" || ai_cli_fail "$log"
    fi
    rm -f "$combined"
    [[ -s "$out" ]] || ai_cli_fail "$log"
}

# ------------------------------------------------------------------------------
# 统一入口
# ------------------------------------------------------------------------------

ai_complete() {
    # ai_complete SYS_FILE USER_FILE OUT_FILE [WORKDIR]
    local sys="$1" user="$2" out="$3" workdir="${4:-$PWD}" proto rc=0
    [[ -n "$AI_PROVIDER_JSON" ]] || ai_resolve || return 1
    proto=$(jq -r '.protocol' <<< "$AI_PROVIDER_JSON")
    : > "$out"
    ai_heartbeat_start
    case "$proto" in
        openai-chat) ai_http_openai "$sys" "$user" "$out" || rc=$? ;;
        openai-responses) ai_http_openai_responses "$sys" "$user" "$out" || rc=$? ;;
        anthropic) ai_http_anthropic "$sys" "$user" "$out" || rc=$? ;;
        claude-code) ai_cli_claude "$sys" "$user" "$out" "$workdir" || rc=$? ;;
        codex) ai_cli_codex "$sys" "$user" "$out" "$workdir" || rc=$? ;;
        antigravity) ai_cli_agy "$sys" "$user" "$out" "$workdir" || rc=$? ;;
        opencode) ai_cli_opencode "$sys" "$user" "$out" "$workdir" || rc=$? ;;
        miyu) ai_cli_miyu "$sys" "$user" "$out" "$workdir" || rc=$? ;;
        *) echo "shorin-pac: unsupported protocol '$proto'" >&2; rc=1 ;;
    esac
    ai_heartbeat_stop
    return $rc
}

ai_extract_json() {
    # ai_extract_json IN_FILE OUT_FILE：从可能带前后废话/代码围栏的文本里抠出第一个 JSON 对象
    local in="$1" out="$2" tmp="${2}.try"
    # 1) 整体就是 JSON
    if jq -c . "$in" > "$tmp" 2>/dev/null && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "$out"; return 0
    fi
    # 2) ```json ... ``` 围栏
    awk 'BEGIN{p=0} /^[[:space:]]*```/{ if(p){exit} else {p=1; next} } p{print}' "$in" > "$tmp"
    if [[ -s "$tmp" ]] && jq -c . "$tmp" > "${tmp}2" 2>/dev/null && jq -e 'type == "object"' "${tmp}2" >/dev/null 2>&1; then
        mv -f "${tmp}2" "$out"; rm -f "$tmp"; return 0
    fi
    # 3) 从第一个 { 开始，依次尝试到每一个 }（从最后一个往前），直到 jq 能解析
    local start end
    start=$(grep -b -o -m1 '{' "$in" 2>/dev/null | head -n1 | cut -d: -f1)
    if [[ -n "$start" ]]; then
        for end in $(grep -b -o '}' "$in" 2>/dev/null | cut -d: -f1 | sort -rn | head -n 200); do
            (( end > start )) || break
            tail -c +"$((start + 1))" "$in" | head -c "$((end - start + 1))" > "$tmp"
            if jq -c . "$tmp" > "${tmp}2" 2>/dev/null && jq -e 'type == "object"' "${tmp}2" >/dev/null 2>&1; then
                mv -f "${tmp}2" "$out"; rm -f "$tmp"; return 0
            fi
        done
    fi
    rm -f "$tmp" "${tmp}2"
    return 1
}

ai_json_complete() {
    # ai_json_complete SYS USER OUT_JSON [WORKDIR] [JQ_CHECK]
    # 输出规范化后的紧凑 JSON 到 OUT_JSON；原始回复留在 OUT_JSON.raw 供排错。
    local sys="$1" user="$2" out="$3" workdir="${4:-$PWD}" check="${5:-true}"
    local raw="${out}.raw" retry_user="${out}.retry" attempt
    for attempt in 1 2; do
        if [[ $attempt -eq 2 ]]; then
            echo "$(ai_msg RETRY_JSON)" >&2
            {
                cat "$user"
                printf '\n\n---\nYour previous reply could not be parsed as the required JSON object. Reply again with ONLY the JSON object, no prose, no code fences. Previous reply (truncated):\n'
                head -c 4000 "$raw"
            } > "$retry_user"
            user="$retry_user"
        fi
        ai_complete "$sys" "$user" "$raw" "$workdir" || continue
        if ai_extract_json "$raw" "$out" && jq -e "$check" "$out" >/dev/null 2>&1; then
            rm -f "$retry_user"
            return 0
        fi
    done
    rm -f "$retry_user"
    echo "$(ai_msg ERR_JSON)" >&2
    return 1
}

# ------------------------------------------------------------------------------
# 交互选择（fzf）
# ------------------------------------------------------------------------------

ai_selection_rows() {
    # 每行：provider_id<TAB>model<TAB>供应商显示名<TAB>来源标签
    ai_all_providers | jq -r '
        . as $p
        | (.models | if length == 0 then [""] else . end)[]
        | [$p.id, ., $p.display_name, ($p.source + "/" + $p.protocol)]
        | @tsv'
}

ai_select_interactive() {
    command -v fzf >/dev/null 2>&1 || { echo "shorin-pac: fzf is required for interactive selection" >&2; return 1; }
    local rows current chosen provider model
    rows=$(ai_selection_rows)
    [[ -n "$rows" ]] || { echo "$(ai_msg NO_PROVIDER)" >&2; return 1; }
    current="$(ai_config_get '.selected.provider // ""'):$(ai_config_get '.selected.model // ""')"
    chosen=$(printf '%s\n' "$rows" | awk -F'\t' -v cur="$current" '
        BEGIN { OFS = "\t" }
        {
            mark = ($1 ":" $2 == cur) ? "●" : " "
            # 显示列：标记  供应商名(定宽)  模型(定宽)  来源
            name = $3; if (length(name) > 26) name = substr(name, 1, 25) "…"
            model = $2; if (length(model) > 34) model = substr(model, 1, 33) "…"
            printf "%s\t%s\t%s %-27s %-35s \033[90m%s\033[0m\n", $1, $2, mark, name, model, $4
        }' | fzf --ansi --with-nth=3.. --delimiter='\t' --height=70% --layout=reverse --border --tiebreak=index \
            --header "$(ai_msg SELECT_HEADER)") || return 1
    provider=$(cut -f1 <<< "$chosen")
    model=$(cut -f2 <<< "$chosen")
    ai_config_update '.selected = {provider: $p, model: $m}' --arg p "$provider" --arg m "$model" || return 1
    AI_PROVIDER_JSON=""
    ai_resolve
    echo -e "\033[36m$(ai_msg SELECTED)\033[0m $(ai_describe_selection)"
}

# ==============================================================================
# 配置界面（`pac config` / `pacr config`）
# ==============================================================================

config_msg() {
    local key="$1"
    if $AI_IS_CN; then
        case "$key" in
            MENU_HEADER) printf '%s' "AI 配置 | Enter:进入 | Esc:退出" ;;
            M_SELECT) printf '%s' "选择供应商 / 模型" ;;
            M_ADD) printf '%s' "添加自定义供应商" ;;
            M_REMOVE) printf '%s' "删除自定义供应商" ;;
            M_TEST) printf '%s' "测试当前供应商" ;;
            M_SHOW) printf '%s' "查看当前配置" ;;
            M_QUIT) printf '%s' "退出" ;;
            CURRENT) printf '%s' "当前：" ;;
            ADD_ID) printf '%s' "供应商 id（字母数字和 - _，例如 deepseek）: " ;;
            ADD_NAME) printf '%s' "显示名称（回车用 id）: " ;;
            ADD_URL) printf '%s' "API 地址（例如 https://api.deepseek.com/v1）: " ;;
            ADD_PROTO) printf '%s' "协议 | Enter:选择" ;;
            ADD_KEY) printf '%s' "API key（可写 \$env:变量名；输入不回显）: " ;;
            ADD_FETCH) printf '%s' "正在获取模型列表..." ;;
            ADD_MODELS_HEADER) printf '%s' "Tab:多选模型 | Enter:确认 | Esc:手动输入" ;;
            ADD_MODELS_MANUAL) printf '%s' "模型名（逗号分隔）: " ;;
            ADD_DONE) printf '%s' "已保存并选用供应商：" ;;
            ADD_EXISTS) printf '%s' "错误：该 id 已存在。" ;;
            ADD_INVALID_ID) printf '%s' "错误：id 不合法。" ;;
            REMOVE_HEADER) printf '%s' "选择要删除的自定义供应商 | Esc:取消" ;;
            REMOVE_NONE) printf '%s' "没有自定义供应商。" ;;
            REMOVED) printf '%s' "已删除：" ;;
            TEST_SENDING) printf '%s' "发送测试消息到：" ;;
            TEST_OK) printf '%s' "测试通过，回复：" ;;
            TEST_FAIL) printf '%s' "测试失败。" ;;
            SHOW_SELECTED) printf '%s' "当前选择" ;;
            SHOW_CUSTOM) printf '%s' "自定义供应商" ;;
            SHOW_CONFIG) printf '%s' "配置文件" ;;
            SHOW_NONE) printf '%s' "（无）" ;;
            SET_BAD) printf '%s' "错误：找不到供应商：" ;;
            PRESS_ENTER) printf '%s' "按回车继续..." ;;
            *) printf '%s' "$key" ;;
        esac
    else
        case "$key" in
            MENU_HEADER) printf '%s' "AI settings | Enter:open | Esc:quit" ;;
            M_SELECT) printf '%s' "Select provider / model" ;;
            M_ADD) printf '%s' "Add a custom provider" ;;
            M_REMOVE) printf '%s' "Remove a custom provider" ;;
            M_TEST) printf '%s' "Test the current provider" ;;
            M_SHOW) printf '%s' "Show current settings" ;;
            M_QUIT) printf '%s' "Quit" ;;
            CURRENT) printf '%s' "Current:" ;;
            ADD_ID) printf '%s' "Provider id (letters, digits, - _; e.g. deepseek): " ;;
            ADD_NAME) printf '%s' "Display name (Enter = id): " ;;
            ADD_URL) printf '%s' "API base URL (e.g. https://api.deepseek.com/v1): " ;;
            ADD_PROTO) printf '%s' "Protocol | Enter:select" ;;
            ADD_KEY) printf '%s' "API key (\$env:VAR allowed; input hidden): " ;;
            ADD_FETCH) printf '%s' "Fetching model list..." ;;
            ADD_MODELS_HEADER) printf '%s' "Tab:multi-select models | Enter:confirm | Esc:type manually" ;;
            ADD_MODELS_MANUAL) printf '%s' "Model names (comma separated): " ;;
            ADD_DONE) printf '%s' "Saved and selected provider:" ;;
            ADD_EXISTS) printf '%s' "Error: that id already exists." ;;
            ADD_INVALID_ID) printf '%s' "Error: invalid id." ;;
            REMOVE_HEADER) printf '%s' "Select a custom provider to remove | Esc:cancel" ;;
            REMOVE_NONE) printf '%s' "No custom providers." ;;
            REMOVED) printf '%s' "Removed:" ;;
            TEST_SENDING) printf '%s' "Sending a test message to:" ;;
            TEST_OK) printf '%s' "Test passed, reply:" ;;
            TEST_FAIL) printf '%s' "Test failed." ;;
            SHOW_SELECTED) printf '%s' "Selected" ;;
            SHOW_CUSTOM) printf '%s' "Custom providers" ;;
            SHOW_CONFIG) printf '%s' "Config file" ;;
            SHOW_NONE) printf '%s' "(none)" ;;
            SET_BAD) printf '%s' "Error: provider not found:" ;;
            PRESS_ENTER) printf '%s' "Press Enter to continue..." ;;
            *) printf '%s' "$key" ;;
        esac
    fi
}

config_show() {
    local cyan=$'\033[36m' reset=$'\033[0m'
    ai_resolve >/dev/null 2>&1 || true
    echo "${cyan}$(config_msg SHOW_SELECTED)${reset}: $(ai_describe_selection 2>/dev/null || echo '-')"
    echo "${cyan}$(config_msg SHOW_CUSTOM)${reset}: $(ai_config_get '[.providers[]? | .id + " (" + .protocol + ", " + (.models | join(", ")) + ")"] | join("; ")' | sed "s/^$/$(config_msg SHOW_NONE)/")"
    echo "${cyan}$(config_msg SHOW_CONFIG)${reset}: $AI_CONFIG_FILE"
}

config_set() {
    local spec="$1"
    if ai_resolve "$spec" && [[ "${AI_AUTO_SELECTED:-false}" != true ]]; then
        ai_config_update '.selected = {provider: $p, model: $m}' --arg p "$AI_PROVIDER_ID" --arg m "$AI_MODEL"
        echo -e "\033[36m$(ai_msg SELECTED)\033[0m $(ai_describe_selection)"
    else
        echo "$(config_msg SET_BAD) $spec" >&2
        return 1
    fi
}

config_add() {
    local id name url proto key models_json fetched chosen
    read -r -p "$(config_msg ADD_ID)" id
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "$(config_msg ADD_INVALID_ID)" >&2; return 1; }
    if ai_all_providers | jq -e --arg id "$id" 'select(.id == $id)' >/dev/null; then
        echo "$(config_msg ADD_EXISTS)" >&2; return 1
    fi
    read -r -p "$(config_msg ADD_NAME)" name; [[ -n "$name" ]] || name="$id"
    read -r -p "$(config_msg ADD_URL)" url; url="${url%/}"
    proto=$(printf '%s\n' "openai-chat" "openai-responses" "anthropic" | fzf --height=7 --layout=reverse --header "$(config_msg ADD_PROTO)") || return 1
    read -r -s -p "$(config_msg ADD_KEY)" key; echo
    models_json='[]'
    if [[ "$proto" == openai-* ]]; then
        echo -e "\033[90m$(config_msg ADD_FETCH)\033[0m"
        fetched=$(curl -sS --max-time 20 -H "Authorization: Bearer $(ai_resolve_key "$key")" "${url}/models" 2>/dev/null \
            | jq -r '.data[]?.id // empty' 2>/dev/null | sort -u || true)
        if [[ -n "$fetched" ]]; then
            chosen=$(printf '%s\n' "$fetched" | fzf --multi --height=60% --layout=reverse --border --header "$(config_msg ADD_MODELS_HEADER)" || true)
            [[ -n "$chosen" ]] && models_json=$(printf '%s\n' "$chosen" | jq -R . | jq -s .)
        fi
    fi
    if [[ "$models_json" == '[]' ]]; then
        read -r -p "$(config_msg ADD_MODELS_MANUAL)" chosen
        models_json=$(printf '%s' "$chosen" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' | jq -R . | jq -s .)
    fi
    ai_config_update '.providers += [{id:$id, display_name:$name, base_url:$url, protocol:$proto, api_key:$key, models:$models, default_model:($models[0] // "")}]' \
        --arg id "$id" --arg name "$name" --arg url "$url" --arg proto "$proto" --arg key "$key" --argjson models "$models_json"
    ai_config_update '.selected = {provider: $p, model: $m}' --arg p "$id" --arg m "$(jq -r '.[0] // ""' <<< "$models_json")"
    echo -e "\033[32m$(config_msg ADD_DONE)\033[0m $id"
}

config_remove() {
    local id="${1:-}" rows
    if [[ -z "$id" ]]; then
        rows=$(ai_config_get '.providers[]? | "\(.id)\t\(.display_name)"')
        [[ -n "$rows" ]] || { echo "$(config_msg REMOVE_NONE)"; return 0; }
        id=$(printf '%s\n' "$rows" | fzf --delimiter='\t' --height=40% --layout=reverse --header "$(config_msg REMOVE_HEADER)" | cut -f1) || return 1
        [[ -n "$id" ]] || return 0
    fi
    ai_config_update '.providers = [.providers[] | select(.id != $id)] | if .selected.provider == $id then .selected = {provider:"", model:""} else . end' --arg id "$id"
    echo -e "\033[33m$(config_msg REMOVED)\033[0m $id"
}

config_toggle() {
    local key="$1" value="$2"
    case "$value" in
        on|true|1) value=true ;;
        off|false|0) value=false ;;
        *) echo "usage: pac config $key on|off" >&2; return 1 ;;
    esac
    ai_config_update ".${key} = \$v" --argjson v "$value"
    ai_init
}

config_test() {
    ai_resolve || return 1
    echo -e "\033[90m$(config_msg TEST_SENDING)\033[0m $(ai_describe_selection)"
    local tmp sys user out
    tmp=$(mktemp -d -t shorin-pac-test.XXXXXX)
    sys="$tmp/sys"; user="$tmp/user"; out="$tmp/out"
    printf 'You are a connectivity test. Reply with exactly the word PONG and nothing else.' > "$sys"
    printf 'ping' > "$user"
    if ai_complete "$sys" "$user" "$out" "$tmp" && [[ -s "$out" ]]; then
        echo -e "\033[32m$(config_msg TEST_OK)\033[0m $(head -c 200 "$out" | tr -d '\n')"
        rm -rf "$tmp"; return 0
    fi
    echo -e "\033[31m$(config_msg TEST_FAIL)\033[0m" >&2
    rm -rf "$tmp"; return 1
}

config_menu() {
    command -v fzf >/dev/null 2>&1 || { echo "pac config: fzf is required for the menu" >&2; return 1; }
    local choice
    while true; do
        ai_resolve >/dev/null 2>&1 || true
        choice=$(printf '%s\n' \
            "select	$(config_msg M_SELECT)	$(config_msg CURRENT) $(ai_describe_selection 2>/dev/null || echo -)" \
            "add	$(config_msg M_ADD)	" \
            "remove	$(config_msg M_REMOVE)	" \
            "test	$(config_msg M_TEST)	" \
            "show	$(config_msg M_SHOW)	" \
            "quit	$(config_msg M_QUIT)	" \
            | awk -F'\t' '{ printf "%s\t%-28s \033[90m%s\033[0m\n", $1, $2, $3 }' \
            | fzf --ansi --delimiter='\t' --with-nth=2.. --height=12 --layout=reverse --border --header "$(config_msg MENU_HEADER)" \
            | cut -f1) || return 0
        case "$choice" in
            select) ai_select_interactive || true ;;
            add) config_add || true ;;
            remove) config_remove || true ;;
            test) config_test || true; read -r -p "$(config_msg PRESS_ENTER)" _ || true ;;
            show) config_show; read -r -p "$(config_msg PRESS_ENTER)" _ || true ;;
            quit|"") return 0 ;;
        esac
    done
}

config_main() {
    ai_init || return 1
    case "${1:-}" in
        "") config_menu ;;
        select) ai_select_interactive ;;
        show) config_show ;;
        set) [[ -n "${2:-}" ]] || { echo "usage: pac config set <provider[:model]>" >&2; return 1; }; config_set "$2" ;;
        add) config_add ;;
        remove) config_remove "${2:-}" ;;
        tools) config_toggle allow_tools "${2:-}" ;;
        miyu) config_toggle import_miyu "${2:-}" ;;
        test) config_test ;;
        path) echo "$AI_CONFIG_FILE" ;;
        -h|--help|help)
            cat <<'EOF'
pac config                 interactive menu / 交互菜单
pac config select          choose provider and model / 选择供应商与模型
pac config show            show current settings / 查看当前配置
pac config set <provider[:model]>
pac config add | remove [id]
pac config test            send a test message / 发一条测试消息
pac config path            print the config file path
EOF
            ;;
        *) echo "pac config: unknown subcommand '$1'" >&2; return 1 ;;
    esac
}

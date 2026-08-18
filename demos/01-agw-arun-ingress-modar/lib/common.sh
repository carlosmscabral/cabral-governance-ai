#!/usr/bin/env bash
# ==============================================================================
# Common Shell Utilities & Logging
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

# ANSI Color Codes
export COLOR_RED='\033[0;31m'
export COLOR_GREEN='\033[0;32m'
export COLOR_YELLOW='\033[1;33m'
export COLOR_BLUE='\033[0;34m'
export COLOR_CYAN='\033[0;36m'
export COLOR_MAGENTA='\033[0;35m'
export COLOR_BOLD='\033[1m'
export COLOR_NC='\033[0m' # No Color

# Rich Emoji Log Functions
log_info() {
    printf "${COLOR_BLUE}ℹ️  [INFO]${COLOR_NC} %s\n" "$*"
}

log_success() {
    printf "${COLOR_GREEN}✅ [SUCESSO]${COLOR_NC} %s\n" "$*"
}

log_warn() {
    printf "${COLOR_YELLOW}⚠️  [AVISO]${COLOR_NC} %s\n" "$*"
}

log_error() {
    printf "${COLOR_RED}❌ [ERRO]${COLOR_NC} %s\n" "$*" >&2
}

log_banner() {
    local msg="$*"
    local border="================================================================================"
    printf "\n${COLOR_MAGENTA}${COLOR_BOLD}%s\n🚀 %s\n%s${COLOR_NC}\n\n" "$border" "$msg" "$border"
}

log_step() {
    printf "${COLOR_CYAN}${COLOR_BOLD}🎯 [PASSO] %s${COLOR_NC}\n" "$*"
}

log_verify() {
    printf "${COLOR_YELLOW}🔍 [VERIFICAÇÃO]${COLOR_NC} %s\n" "$*"
}

# Preflight Tool Check
check_command() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Comando obrigatório '$cmd' não foi encontrado no PATH."
        if [[ -n "$hint" ]]; then
            log_warn "Dica de instalação: $hint"
        fi
        return 1
    fi
}

# Error Trap Handler
setup_error_trap() {
    trap 'error_exit ${LINENO} "$BASH_COMMAND"' ERR
}

error_exit() {
    local line="$1"
    local cmd="$2"
    log_error "Falha na linha $line ao executar o comando: '$cmd'"
    exit 1
}

# Wait for condition helper
wait_for_resource() {
    local desc="$1"
    local max_retries="${2:-30}"
    local delay="${3:-5}"
    shift 3
    local check_cmd=("$@")

    log_info "Aguardando $desc ficar pronto..."
    local count=0
    until "${check_cmd[@]}" &>/dev/null; do
        ((count++))
        if ((count >= max_retries)); then
            log_error "Tempo esgotado aguardando por $desc ($((max_retries * delay))s)."
            return 1
        fi
        printf "."
        sleep "$delay"
    done
    printf "\n"
    log_success "$desc está pronto e ativo!"
}

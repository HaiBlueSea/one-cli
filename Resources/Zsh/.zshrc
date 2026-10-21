_aie_source_user_zshrc() {
  local save=$ZDOTDIR
  if [[ -n ${AIE_USER_ZDOTDIR:-} ]]; then
    ZDOTDIR=$AIE_USER_ZDOTDIR
  else
    unset ZDOTDIR
  fi
  local user_home=${ZDOTDIR:-$HOME}
  if [[ -r $user_home/.zshrc ]]; then
    source $user_home/.zshrc
  fi
  ZDOTDIR=$save
}
_aie_source_user_zshrc

if [[ -n ${AIE_WRAPPER_BIN:-} && -d $AIE_WRAPPER_BIN ]]; then
  path=($AIE_WRAPPER_BIN ${path:#$AIE_WRAPPER_BIN})
  export PATH
fi

if [[ -z ${_AIE_HOOKS_LOADED:-} && -n ${AIE_HELPER:-} && -x "$AIE_HELPER" ]]; then
  _AIE_HOOKS_LOADED=1
  autoload -Uz add-zsh-hook

  if [[ -z ${AIE_TOP_PID:-} || $AIE_TOP_PID == $$ ]]; then
    export AIE_TOP_PID=$$
    export AIE_SHELL_ROLE=top
  else
    export AIE_SHELL_ROLE=nested
  fi

  typeset -gi _AIE_SEQ=0
  typeset -g _AIE_LAST_CWD=

  _aie_emit_cwd() {
    [[ $AIE_SHELL_ROLE == top && $ZSH_SUBSHELL == 0 ]] || return 0
    (( _AIE_SEQ++ ))
    "$AIE_HELPER" --kind cwd --cwd "$PWD" --role "$AIE_SHELL_ROLE" --seq "$_AIE_SEQ" >/dev/null 2>&1 || true
    _AIE_LAST_CWD=$PWD
  }

  _aie_chpwd() {
    _aie_emit_cwd
  }

  _aie_precmd() {
    local last=$?
    [[ $AIE_SHELL_ROLE == top && $ZSH_SUBSHELL == 0 ]] || return 0
    unset AIE_LAUNCH_ID
    if [[ $AIE_SHELL_ROLE == top && $PWD != $_AIE_LAST_CWD ]]; then
      _aie_emit_cwd
    fi
    if [[ $AIE_SHELL_ROLE == top ]]; then
      "$AIE_HELPER" --kind promptReady --cwd "$PWD" --role "$AIE_SHELL_ROLE" --exit "$last" >/dev/null 2>&1 || true
    fi
  }

  _aie_preexec() {
    [[ $AIE_SHELL_ROLE == top && $ZSH_SUBSHELL == 0 ]] || return 0
    unset AIE_LAUNCH_ID
    if command -v uuidgen >/dev/null 2>&1; then
      export AIE_LAUNCH_ID=$(uuidgen | tr 'A-Z' 'a-z')
    fi
    print -nr -- "${1:-$2}" | "$AIE_HELPER" --kind preexec --role "$AIE_SHELL_ROLE" >/dev/null 2>&1 || true
  }

  add-zsh-hook chpwd _aie_chpwd
  add-zsh-hook precmd _aie_precmd
  add-zsh-hook preexec _aie_preexec
  _aie_emit_cwd
fi

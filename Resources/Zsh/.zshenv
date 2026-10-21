# AI Terminal private Zsh bootstrap. Keep this ZDOTDIR so later files still load.
if [[ -n ${_AIE_ENV_LOADED:-} ]]; then
  return
fi
_AIE_ENV_LOADED=1
_AIE_BOOTSTRAP_ZDOTDIR=${AIE_BOOTSTRAP_ZDOTDIR:-$ZDOTDIR}

_aie_source_user_zshenv() {
  if [[ -n ${AIE_USER_ZDOTDIR:-} ]]; then
    ZDOTDIR=$AIE_USER_ZDOTDIR
  else
    unset ZDOTDIR
  fi
  local user_home=${ZDOTDIR:-$HOME}
  if [[ -r $user_home/.zshenv ]]; then
    source $user_home/.zshenv
  fi
  if [[ -n ${ZDOTDIR:-} && $ZDOTDIR != $_AIE_BOOTSTRAP_ZDOTDIR ]]; then
    export AIE_USER_ZDOTDIR=$ZDOTDIR
  fi
}
_aie_source_user_zshenv
ZDOTDIR=$_AIE_BOOTSTRAP_ZDOTDIR

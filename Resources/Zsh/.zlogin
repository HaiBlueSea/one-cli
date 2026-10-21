_aie_source_user_zlogin() {
  local save=$ZDOTDIR
  if [[ -n ${AIE_USER_ZDOTDIR:-} ]]; then
    ZDOTDIR=$AIE_USER_ZDOTDIR
  else
    unset ZDOTDIR
  fi
  local user_home=${ZDOTDIR:-$HOME}
  if [[ -r $user_home/.zlogin ]]; then
    source $user_home/.zlogin
  fi
  ZDOTDIR=$save
}
_aie_source_user_zlogin

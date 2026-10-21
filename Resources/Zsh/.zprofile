_aie_source_user_zprofile() {
  local save=$ZDOTDIR
  if [[ -n ${AIE_USER_ZDOTDIR:-} ]]; then
    ZDOTDIR=$AIE_USER_ZDOTDIR
  else
    unset ZDOTDIR
  fi
  local user_home=${ZDOTDIR:-$HOME}
  if [[ -r $user_home/.zprofile ]]; then
    source $user_home/.zprofile
  fi
  ZDOTDIR=$save
}
_aie_source_user_zprofile

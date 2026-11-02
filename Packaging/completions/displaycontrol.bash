_displaycontrol() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "status list get set preset schedule sync reset-gamma selftest mcp version" -- "$cur") )
  else
    COMPREPLY=( $(compgen -W "--json --human --all --launch --brightness --contrast --volume --input --rotation --power --mute --index --uuid --delay --mock" -- "$cur") )
  fi
}
complete -F _displaycontrol displaycontrol

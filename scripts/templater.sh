#!/bin/sh

# $1 - file template
# $2 (optional) - file vars

#set -eu # unset variables are errors & non-zero return values exit the whole script
[ "${DEBUG:-}" = "true" ] && set -x

template="./.env.template"
fin="./.env.vars"

cat_template() {
  echo "cat << EOT"
  if [ -n "$1" ]; then
    cat "$1"
  else
    [ -n $template ] && cat $template
  fi


  echo EOT
}

# source file vars
if [ -f "$2" ]; then
  set -a; . "$2"; set +a;
else
  [ -f $fin ] && (set -a; . $fin; set +a; )
fi

# source file template
if [ -f "$1" ]; then
  set -a; . "$1"; set +a;
else
  [ -f "${template}" ] && (set -a; . "${template}"; set +a; )
fi

cat_template $1 | sh

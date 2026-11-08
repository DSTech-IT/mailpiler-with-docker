#!/bin/bash

# Colors
if [ -z ${BASH_SOURCE} ]; then
  blue=`echo "\e[1m\e[34m"`
  green=`echo "\e[1m\e[32m"`
  greenBold=`echo "\e[1m\e[1;32m"`
  redBold=`echo "\e[1m\e[1;31m"`
  red=`echo "\e[1m\e[31m"`
  purple=`echo "\e[1m\e[35m"`
  bold=`echo "\e[1m"`
  normal=`echo "\e[0m"`
else
  blue=`echo -e "\e[1m\e[34m"`
  green=`echo -e "\e[1m\e[32m"`
  greenBold=`echo -e "\e[1m\e[1;32m"`
  redBold=`echo -e "\e[1m\e[1;31m"`
  purple=`echo -e "\e[1m\e[35m"`
  bold=`echo -e "\e[1m"`
  normal=`echo -en "\e[0m"`
fi

# Update Source: the files of the newest release, REPO_RAW_URL can point to a branch for tests
GITHUB_REPO="DSTech-IT/mailpiler-with-docker"
REPO_RAW_URL="${REPO_RAW_URL:-}"

# Run from the install directory, also when started by cron
cd "$(dirname "$0")" || exit 1

HLINE="================================================================"
HLINE_SMALL="================================="

BLA_metro=( 0.2 '    ' '=   ' '==  ' '=== ' ' ===' '  ==' '   =' )

BLA::play_loading_animation_loop() {
  while true ; do
    for frame in "${BLA_active_loading_animation[@]}" ; do
      printf "\r%s" "${frame}"
      sleep "${BLA_loading_animation_frame_interval}"
    done
  done
}

BLA::start_loading_animation() {
  BLA_active_loading_animation=( "${@}" )
  BLA_loading_animation_frame_interval="${BLA_active_loading_animation[0]}"
  unset "BLA_active_loading_animation[0]"
  tput civis # Hide the terminal cursor
  BLA::play_loading_animation_loop &
  BLA_loading_animation_pid="${!}"
}

BLA::stop_loading_animation() {
  kill "${BLA_loading_animation_pid}" &> /dev/null
  printf "\n"
  tput cnorm # Restore the terminal cursor
}

# Ask for a port, $1 = question, $2 = default
function ask_port {
  local port
  while true; do
    read -ep "$1 (Enter for default: $2): " port
    port=${port:-$2}
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then echo "$port"; return; fi
    echo -e "${redBold} Please enter a port between 1 and 65535.${normal}" >&2
  done
}

# Ask for the host IP and ports Piler is published on and save them in piler.conf,
# $1 = default IP (empty = all interfaces), $2 = default SMTP port, $3 = default web port
function set_port_config {
  local bindIp smtpPort httpPort="$3" key

  while true; do
    read -ep "Bind the Piler ports to one host IP? (Enter for default: ${1:-all interfaces}, \"all\" for all interfaces): " bindIp
    bindIp=${bindIp:-$1}
    if [ "$bindIp" = "all" ]; then bindIp=""; fi
    if [[ -z "$bindIp" || "$bindIp" =~ ^[0-9A-Fa-f:.]+$ ]]; then break; fi
    echo -e "${redBold} Please enter an IPv4 or IPv6 address.${normal}"
  done

  smtpPort=$(ask_port "Host port for SMTP" "$2")

  # With Let's Encrypt the nginx-proxy needs the ports 80 and 443
  if [ "$USE_LETSENCRYPT" != "yes" ]; then
    httpPort=$(ask_port "Host port for the web interface, e.g. behind your own reverse proxy" "$3")
  fi

  for key in PILER_BIND_IP PILER_SMTP_PORT PILER_HTTP_PORT; do
    if ! grep -q "^${key}=" ./piler.conf; then echo "${key}=\"\"" >> ./piler.conf; fi
  done
  sed -i -e 's/^PILER_BIND_IP=.*/PILER_BIND_IP="'$bindIp'"/' \
         -e 's/^PILER_SMTP_PORT=.*/PILER_SMTP_PORT="'$smtpPort'"/' \
         -e 's/^PILER_HTTP_PORT=.*/PILER_HTTP_PORT="'$httpPort'"/' ./piler.conf
}

# Ask which networks may deliver mail to Piler and save them in piler.conf, $1 = default
function set_smtp_acl {
  local acl entries entry valid
  echo "Piler can accept SMTP only from some networks, e.g. 192.168.1.0/24 10.0.0.5"
  echo "(\"host\" = mail from this server, \"all\" = from everywhere)"
  while true; do
    read -ep "Networks separated by spaces (Enter for default: ${1:-all}): " acl
    acl=${acl:-$1}
    if [ "$acl" = "all" ]; then acl=""; fi
    read -ra entries <<< "$acl"
    valid=yes
    for entry in "${entries[@]}"; do
      if [[ "$entry" != "host" && ! "$entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then valid=no; fi
    done
    if [ "$valid" = "yes" ]; then break; fi
    echo -e "${redBold} Please enter IPv4 addresses, networks like 192.168.1.0/24 or \"host\".${normal}"
  done
  if ! grep -q "^PILER_SMTP_ACL=" ./piler.conf; then echo 'PILER_SMTP_ACL=""' >> ./piler.conf; fi
  sed -i 's#^PILER_SMTP_ACL=.*#PILER_SMTP_ACL="'"${entries[*]}"'"#' ./piler.conf
}

# Bind the published ports of docker-compose.yml to PILER_BIND_IP (empty = all interfaces)
function bind_ports {
  local ip="$PILER_BIND_IP"
  if [ -z "$ip" ]; then return; fi
  if [[ "$ip" == *:* ]]; then ip="[$ip]"; fi
  sed -i -E 's#^([[:space:]]*- ")((\$\{PILER_[A-Z_]+:-[0-9]+\}|[0-9]+):[0-9]+")$#\1'"$ip"':\2#' $installPth/docker-compose.yml
}

# Release tags like v.1.2.3 without the prefix, for sort -V
function version_of {
  local v=${1#v}
  echo "${v#.}"
}

# True if release tag $1 is newer than $2
function is_newer {
  local a b
  a=$(version_of "$1"); b=$(version_of "$2")
  [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

# Show the notes of the releases after $1 up to $releaseTag (only $releaseTag if $1 is empty)
function show_release_notes {
  local releases tag
  if ! command -v jq > /dev/null; then
    echo "${blue}Release notes: https://github.com/$GITHUB_REPO/releases (install jq to show them here)${normal}"
    return
  fi
  releases=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases?per_page=30") || return
  while read -r tag; do
    if is_newer "$tag" "$releaseTag"; then continue; fi
    if [ -n "$1" ] && ! is_newer "$tag" "$1"; then continue; fi
    if [ -z "$1" ] && [ "$tag" != "$releaseTag" ]; then continue; fi
    echo
    echo "${greenBold}${HLINE}"
    jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .name' <<< "$releases"
    echo "${HLINE}${normal}"
    jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .body' <<< "$releases" | tr -d '\r'
  done < <(jq -r '.[] | select(.prerelease | not) | .tag_name' <<< "$releases" | sort -V)
  echo
}

# Ask before the update, $1 = question
function confirm_update {
  while true; do
    read -ep "$1 (y/n): " yn
    case $yn in
      [Yy]* ) echo "${greenBold}********* Update started... Please wait... *********${normal}"; return;;
      [Nn]* ) echo -e "${redBold}    The update is canceled!${normal}"; exit;;
      * ) echo -e "${redBold} Please confirm with y or n.${normal}";;
    esac
  done
}

# Pull new releases of the images under the same tag and rebuild the Piler image if
# Ubuntu updates are pending. Only changed containers are recreated (meant for a cronjob).
function check_images {
  local compose=(docker compose) oldImage=""
  if [ "$COMPOSE_VERSION" != native ]; then compose=(docker-compose); fi

  echo "$(date '+%F %T') Checking the images of Piler"
  "${compose[@]}" pull --ignore-buildable --quiet || exit 1

  if docker exec piler sh -c 'apt-get update -qq > /dev/null 2>&1; apt list --upgradable 2> /dev/null' | grep -q "upgradable from"; then
    echo "Ubuntu updates are pending, rebuilding the Piler image"
    oldImage=$(docker inspect -f '{{.Image}}' piler)
    "${compose[@]}" build --no-cache --quiet piler || exit 1
  fi

  "${compose[@]}" up -d || exit 1

  # Remove the replaced Piler image, so that weekly rebuilds do not fill the disk
  if [ -n "$oldImage" ]; then docker rmi "$oldImage" > /dev/null 2>&1; fi
  echo "$(date '+%F %T') Image check done"
}

#######################################################################################
function finish_info {
  echo
  echo "${greenBold}${HLINE}"
  echo "${greenBold}             Piler Update completed successfully"
  echo "${greenBold}${HLINE}${normal}"
  echo
  echo
  echo "${greenBold}${HLINE}"

  if [ "$USE_LETSENCRYPT" = "yes" ]; then
    echo "${greenBold}you can start in your Browser with:"
    echo "${greenBold}https://${PILER_DOMAIN}"
  else
    echo "${greenBold}you can start in your Browser with:"
    echo "${greenBold}http://${PILER_DOMAIN} or http://local-ip"
  fi

  echo "${greenBold}${HLINE}${normal}"

  echo
  echo "${blue}${HLINE}"
  echo "${blue}You can remove the old unused containers on your system!"
  echo "${blue}Execute the following command: docker system prune"
  echo "${blue}${HLINE}${normal}"
  echo
  exit 0
}

function header_info {
clear

echo "${greenBold}"
cat <<"EOF"
        _ _             _   _           _       _
  _ __ (_) | ___ _ __  | | | |_ __   __| | __ _| |_ ___
 | '_ \| | |/ _ \ '__| | | | | '_ \ / _` |/ _` | __/ _ \
 | |_) | | |  __/ |    | |_| | |_) | (_| | (_| | ||  __/
 | .__/|_|_|\___|_|     \___/| .__/ \__,_|\__,_|\__\___|
 |_|                         |_|

EOF
echo "${normal}"
}

mode=update
case "${1:-}" in
  "" ) ;;
  --force ) mode=force;;
  --check-images ) mode=check-images;;
  * ) echo "Usage: bash update.sh [--force | --check-images]"; exit 1;;
esac

if [ "$mode" != check-images ]; then header_info; fi

#######################################################################################

# App Check
for bin in curl docker git; do
  if [[ -z $(which ${bin}) ]]; then echo "${redBold}Cannot find ${bin}, exiting...${normal}"; exit 1; fi
done

# Docker-Compose Check
if docker compose > /dev/null 2>&1; then
    if [ "$(docker compose version --short 2>/dev/null | sed 's/^v//' | cut -d. -f1)" -ge 2 ] 2>/dev/null; then
      COMPOSE_VERSION=native
      echo -e "${purple}Found Docker Compose Plugin (native).${normal}"
      echo -e "${purple}Setting the DOCKER_COMPOSE_VERSION Variable to native${normal}"
      sleep 2
      echo -e "${purple}Notice: You´ll have to update this Compose Version via your Package Manager manually!${normal}"
    else
      echo -e "${redBold}Cannot find Docker Compose with Version 2.X.X or higher.${normal}"
      exit 1
    fi
elif docker-compose > /dev/null 2>&1; then
  if ! [[ $(alias docker-compose 2> /dev/null) ]] ; then
    if [ "$(docker-compose version --short 2>/dev/null | sed 's/^v//' | cut -d. -f1)" -ge 2 ] 2>/dev/null; then
      COMPOSE_VERSION=standalone
      echo -e "${purple}Found Docker Compose Standalone.${normal}"
      echo -e "${purple}Setting the DOCKER_COMPOSE_VERSION Variable to standalone${normal}"
      sleep 2
    else
      echo -e "${redBold}Cannot find Docker Compose with Version 2.X.X or higher.${normal}"
      exit 1
    fi
  fi

else
  echo -e "${redBold}Cannot find Docker Compose.${normal}"
  exit 1
fi

#######################################################################################

installPth=`pwd`
configPth="$installPth/config"
etcPth="/var/lib/docker/volumes/piler-docker_piler_etc/_data"
buildPth="$installPth/build"

if [ "$mode" = check-images ]; then check_images; exit 0; fi

# Marker of the installer before 1.3.0, no longer needed
rm -f $installPth/.update

releaseTag="${PILER_UPDATE_TAG:-}"

if [ -n "${PILER_UPDATE_RESTARTED:-}" ]; then
  # Restarted by the steps below, the update was already confirmed
  :
elif [ -n "$REPO_RAW_URL" ]; then
  echo "${purple}Update source: $REPO_RAW_URL${normal}"
  if [ "$mode" != force ]; then confirm_update "Do you want to update from this source?"; fi
else
  releaseTag=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -z "$releaseTag" ]; then
    echo "${redBold}Cannot read the newest release from GitHub, the update is canceled.${normal}"
    exit 1
  fi
  installedTag=$(cat $installPth/.version 2> /dev/null)
  echo "${blue}Installed version: ${installedTag:-unknown}, newest release: ${releaseTag}${normal}"

  if [ "$mode" != force ]; then
    if [ -n "$installedTag" ] && ! is_newer "$releaseTag" "$installedTag"; then
      echo "${greenBold}Piler is up to date. Run \"bash update.sh --force\" to pull and rebuild everything anyway.${normal}"
      exit 0
    fi
    show_release_notes "$installedTag"
    confirm_update "Do you want to update to ${releaseTag}?"
  fi
  REPO_RAW_URL="https://raw.githubusercontent.com/$GITHUB_REPO/$releaseTag"
fi

# Continue with the update.sh of the new release, it knows the steps this release needs.
# Releases before 1.3.0 have an update.sh without release support and are not restarted.
if [ -z "${PILER_UPDATE_RESTARTED:-}" ]; then
  if curl -fsSL "$REPO_RAW_URL/update.sh" -o $installPth/update.sh.new \
      && grep -q -- "--check-images" $installPth/update.sh.new \
      && ! cmp -s $installPth/update.sh.new $installPth/update.sh; then
    mv $installPth/update.sh.new $installPth/update.sh
    REPO_RAW_URL="$REPO_RAW_URL" PILER_UPDATE_TAG="$releaseTag" PILER_UPDATE_RESTARTED=1 exec bash $installPth/update.sh "$@"
  fi
  rm -f $installPth/update.sh.new
fi

# The port settings were added in 1.3.0: ask once and suggest the ports
# of the old docker-compose.yml, so that ports changed by hand are kept
if ! grep -q "^PILER_BIND_IP=" ./piler.conf; then
  . ./piler.conf
  oldIp=""; oldSmtp="25"; oldHttp="80"
  if [ -f $installPth/docker-compose.yml ]; then
    oldPort=$(sed -nE 's/^[[:space:]]*- "?(([0-9.]+):)?([0-9]+):25"?[[:space:]]*$/\2|\3/p' $installPth/docker-compose.yml | head -1)
    if [ -n "$oldPort" ]; then oldIp=${oldPort%|*}; oldSmtp=${oldPort#*|}; fi
    if [ "$USE_LETSENCRYPT" != "yes" ]; then
      oldPort=$(sed -nE 's/^[[:space:]]*- "?(([0-9.]+):)?([0-9]+):80"?[[:space:]]*$/\3/p' $installPth/docker-compose.yml | head -1)
      oldHttp=${oldPort:-80}
    fi
  fi
  echo
  echo "${blue}The host IP and ports of Piler can now be set (saved in piler.conf)${normal}"
  set_port_config "$oldIp" "$oldSmtp" "$oldHttp"
fi

# The SMTP access list was added in 1.3.0: ask once, empty keeps a smtp.acl written by hand
if ! grep -q "^PILER_SMTP_ACL=" ./piler.conf; then
  echo
  echo "${blue}The networks allowed to deliver mail can now be set (saved in piler.conf)${normal}"
  set_smtp_acl ""
fi

# old docker stop (before the docker-compose.yml is removed)
cd $installPth

if [ $COMPOSE_VERSION = native ]; then
  docker compose down
else
  docker-compose down
fi

if [ -f $installPth/docker-compose.yml ]; then
  rm $installPth/docker-compose.yml
fi

# Download yml update
echo
echo "${greenBold}${HLINE}"
echo "${greenBold}                 Download Update files for Piler"
echo "${greenBold}${HLINE}${normal}"
echo

# Update Files
for ymlUpdate in piler-default.yml piler-ssl.yml; do
  echo
  echo "${purple}${HLINE}${HLINE_SMALL}"
  echo "${purple}****** Download Update $ymlUpdate ******"
  wget $REPO_RAW_URL/config/$ymlUpdate -O $configPth/$ymlUpdate
  echo "${purple}${HLINE}${HLINE_SMALL}${normal}"
  echo
done

for fileUpdate in install-piler.sh README.md LICENSE piler.conf.example patch.sh; do
  echo
  echo "${purple}${HLINE}${HLINE_SMALL}"
  echo "${purple}****** Download Update $fileUpdate ******"
  wget $REPO_RAW_URL/$fileUpdate -O $installPth/$fileUpdate
  echo "${purple}${HLINE}${HLINE_SMALL}${normal}"
  echo
done

# Config files for the manticore and mysql containers are only downloaded if missing,
# so that local changes (e.g. charset_table) are kept
for confUpdate in manticore.conf piler.cnf; do
  if [ ! -f $installPth/$confUpdate ]; then
    echo
    echo "${purple}${HLINE}${HLINE_SMALL}"
    echo "${purple}****** Download $confUpdate ******"
    wget $REPO_RAW_URL/$confUpdate -O $installPth/$confUpdate
    echo "${purple}${HLINE}${HLINE_SMALL}${normal}"
    echo
  fi
done

for buildUpdate in start.sh build.sh Dockerfile build.conf; do
  echo
  echo "${purple}${HLINE}${HLINE_SMALL}"
  echo "${purple}****** Download Update $buildUpdate ******"
  wget $REPO_RAW_URL/build/$buildUpdate -O $buildPth/$buildUpdate
  echo "${purple}${HLINE}${HLINE_SMALL}${normal}"
  echo
done

# build config load
. $buildPth/build.conf

# set Piler Version
sed -i 's/PILER_VERSION=.*/PILER_VERSION="'$PILER_VERSION'"/g' ./piler.conf

# set Maria-DB Version
sed -i 's/MARIA_DB_VERSION=.*/MARIA_DB_VERSION="'$MARIA_DB_VERSION'"/g' ./piler.conf

# config load
. ./piler.conf

if [ ! -f $installPth/.env ]; then
  ln -s ./piler.conf .env
fi

# create Network
if docker network inspect pilernet > /dev/null 2>&1; then
    echo "Network pilernet is available"
else
    docker network create pilernet
    echo "Network pilernet created"
fi

# Backup Config
if [ ! -d $installPth/backup ]; then
  mkdir -p $installPth/backup
fi

cp -rf $etcPth/* $installPth/backup/

# Added Manticore
if [ ! -f $etcPth/MANTICORE ]; then
  touch $etcPth/MANTICORE
fi

# Copy docker-compose.yml
if [ "$USE_LETSENCRYPT" = "yes" ]; then
  cp $configPth/piler-ssl.yml $installPth/docker-compose.yml
else
  cp $configPth/piler-default.yml $installPth/docker-compose.yml
fi
bind_ports
# Check for Patches before Update
bash $installPth/patch.sh
BLA::start_loading_animation "${BLA_metro[@]}"
sleep 5
BLA::stop_loading_animation

# start Update Container
echo
echo "${greenBold}${HLINE}"
echo "${greenBold}                 Update Container for Piler"
echo "${greenBold}${HLINE}${normal}"
echo

if [ "$USE_LETSENCRYPT" = "yes" ]; then
    if ! docker network ls | grep -o "nginx-proxy"; then
      docker network create nginx-proxy

      echo
      echo "${blue}${HLINE}"
      echo "${blue}                       docker network created"
      echo "${blue}${HLINE}${normal}"
      echo
    fi
fi

# Rebuild the Piler image without cache, so that security updates of the Ubuntu
# packages (e.g. PHP) are installed even if the Dockerfile has not changed, and
# pull new releases of the other images (patch updates under the same tag)
if [ $COMPOSE_VERSION = native ]; then
  docker compose build --no-cache
  docker compose pull --ignore-buildable
  docker compose up --force-recreate -d
else
  docker-compose build --no-cache
  docker-compose pull --ignore-buildable
  docker-compose up --force-recreate -d
fi

# Remember the installed release for the next update
if [ -n "$releaseTag" ]; then echo "$releaseTag" > $installPth/.version; fi

echo
echo "${greenBold}${HLINE}"
echo "${greenBold}                 Reindex Piler"
echo "${greenBold}${HLINE}${normal}"
echo

while true; do
    read -ep "Do you want to perform the Reindex?? (y/n): " yn
    case $yn in
        [Yy]* ) echo "${greenBold}********* Reindex started... Please wait... *********${normal}"; break;;
        [Nn]* ) echo -e "${redBold}    Update without Reindex!${normal}"; finish_info;;
        * ) echo -e "${redBold} Please confirm with y or n.${normal}";;
    esac
done

BLA::start_loading_animation "${BLA_metro[@]}"
sleep 15
docker exec -u piler -w /var/tmp piler reindex -a
BLA::stop_loading_animation
finish_info

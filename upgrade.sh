#!/bin/bash

# The original source of this script is from
# https://bugs.launchpad.net/openstack-ci/+bug/979227
# Authored by Drragh Bailey (dbailey)-k

# This script should be used to upgrade Gerrit from an old
# version to a newer version.

# Requirements:
#  1.  Gerrit must be running on Linux trusty.
#  2.  Should run this script as the gerrit2 user
#  3.  Should run this script on the gerrit server
#  4.  Make sure gerrit service is stopped before running

function cleanup() {
    revert
}

# Get DB config from existing gerrit site
function get_config_data() {
    local config_path=$1
    local config="$1/etc/gerrit.config"
    local secure="$1/etc/secure.config"

    [[ ! -e "${config}" ]] && { echo "No gerrit config file supplied!"; exit 2; }
    [[ ! -e "${secure}" ]] && { echo "No gerrit secure file supplied!"; exit 2; }


    CONFIG=${config}
    DB_HOST=$(git config --file ${config} --get database.hostname)
    DB_PORT=$(git config --file ${config} --get database.port)
    if [ -z "${DB_PORT}" ] ; then
       DB_PORT="3306"
    fi
    DB_NAME=$(git config --file ${config} --get database.database)
    DB_USER=$(git config --file ${config} --get database.username)
    DB_PASSWD=$(git config --file ${secure} --get database.password)
}


# backup Gerrit db
function backup_db() {
    local id=$1
    echo "Backing up db ${DB_NAME} to ${DB_NAME}-${id}.sql"
    mysqldump -h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER} ${DB_PASSWD:+-p${DB_PASSWD}} ${DB_NAME} > ${DB_NAME}-${id}.sql
}

# backup Gerrit site
function backup_site() {
    local id=$1
    echo "Backing up ${GERRIT_SITE} to ${GERRIT_SITE}-${id}.tar.gz"
    tar -pczf ${GERRIT_SITE}-${id}.tar.gz ${GERRIT_SITE}
}

# upgrading from gerrit 2.8 requires this workaround
# https://groups.google.com/d/msg/repo-discuss/0qP1xZoOoDY/a9LKSYkii5MJ
function create_db_index() {
    local id=$1
    echo "Creating index in ${DB_NAME} for upgrade"
    mysqldump -h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER} ${DB_PASSWD:+-p${DB_PASSWD}} \
      ${DB_NAME} -e "CREATE INDEX patch_set_approvals_closedbyu ON patch_set_approvals (change_open);" ||
      { echo "Problem creating required index for upgrade"; exit 1; }
}

# upgrade Gerrit site
function gerrit_init() {

    echo "Upgrading Gerrit in ${GERRIT_SITE} using ${GERRIT_WAR}"
    java -jar ${GERRIT_WAR} init --batch --no-auto-start -d ${GERRIT_SITE}
}

# install Gerrit core plugins
function install_plugins() {

    echo "Installing Gerrit core plugins into ${GERRIT_SITE}/plugins"
    unzip -jo ${GERRIT_WAR} WEB-INF/plugins/* -d ${GERRIT_SITE}/plugins
}

# reindex Gerrit site
function gerrit_reindex() {

    echo "Reindexing Gerrit in ${GERRIT_SITE}"
    java -jar ${GERRIT_WAR} reindex -d ${GERRIT_SITE}
}


function restore_db() {
    local id=$1
    echo "Restoring previous backup of DB with ${DB_NAME}-${id}.sql"
    mysql -h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER} ${DB_PASSWD:+-p${DB_PASSWD}} ${DB_NAME} < ${DB_NAME}-${id}.sql
}

function restore_site() {
    local id=$1
    echo "Restoring previous backup of site with ${GERRIT_SITE}-${id}.tar.gz"
    tar -zxvf ${GERRIT_SITE}-${id}.tar.gz -C ${GERRIT_SITE}
}


function upgrade() {
    backup_db "backup-before-upgrade"
    backup_site "backup-before-upgrade"
    create_db_index

    trap cleanup "EXIT" "SIGTRAP" "SIGKILL" "SIGTERM"
    gerrit_init
    install_plugins
    gerrit_reindex
    trap - "EXIT" "SIGTRAP" "SIGKILL" "SIGTERM"
}

function revert() {
    backup_db "backup-before-revert"
    backup_site "backup-before-revert"
    restore_db
    restore_site
}

USAGE="$0 ACTION [path]

  ACTION   upgrade, revert or backup
  war      path to gerrit war file (i.e. /home/gerrit2/gerrit-2.10.war)
  site     path to gerrit site directory (i.e. /home/gerrit2/review)
"

if [ $# -ne 3 ]
then
    echo "${USAGE}"
    exit 2
fi

GERRIT_WAR=$2
GERRIT_SITE=$3
get_config_data ${GERRIT_SITE}

case $1 in
    "backup")
        backup_db
        backup_site
        ;;
    "upgrade")
	upgrade
	;;
    "revert")
	revert
	;;
    *)
	echo "Invalid action"
	echo "${USAGE}"
	exit 2
esac

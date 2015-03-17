#!/bin/sh

# TODO: how to detect files that are deprecated/delete old files
# TODO: perform signature checking of release archives
# TODO: when /boot/gptboot or /boot/gptzfsboot changes, warn
# TODO: look into etcupdate
# TODO: automatically detect right parts to deploy

set -e

ROOT=/mnt
UPGRADE=10.1-TRANSBSD
URL=http://mondieu.skoef.net/${UPGRADE}
PARTS="kernel base"
: ${PAGER=/usr/bin/more}

# detect if file is the same, besides the $FreeBSD$ part
samef () {
    X=`sed -E 's/\\$FreeBSD.*\\$/\$FreeBSD\$/' < $1 | sha256 -q`
    Y=`sed -E 's/\\$FreeBSD.*\\$/\$FreeBSD\$/' < $2 | sha256 -q`

    [ $X = $Y ] && return 0
    return 1
}

# gzip wrapper for samef
samegz () {
    X=$(mktemp ${TMP}/samegz.XXXX)
    Y=$(mktemp ${TMP}/samegz.XXXX)
    zcat $1 > $X
    zcat $2 > $Y
    samef $X $Y && ret=0 || ret=1
    rm -f $X $Y
    return $ret
}

unstage() {
    local name=$(echo $1 | sed -e 's/\[/\\\[/g' -e 's/\]/\\\]/g')
    local stagefile=${TMP}/stage.list
    local delim="|"
    [ $# -gt 1 ] && stagefile=$2
    [ $# -gt 2 ] && delim=$3
    sed -i '' "\#${delim}${name}${delim}#d" ${stagefile}
}

checkyesno() {
    case ${1} in
        [Yy][Ee][Ss]|[Yy])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

cleanup() {
    local quiet=$1
    [ -z "${quiet}" ] && log_begin_msg "Cleaning up"
    find ${TMP} ${RELEASE} -flags +schg -exec chflags noschg {} \; 2>/dev/null || true
    rm -rf ${TMP} ${RELEASE}
    [ -z "${quiet}" ] && log_end_msg
    return 0
}

log_begin_msg() {
    echo -n "`date` ==> $@ ... "
}

log_end_msg() {
    echo "done"
}

indicate() {
    case ${__INDICATOR} in
        '|')
            __INDICATOR="/"
            ;;
        '/')
            __INDICATOR="-"
            ;;
        '-')
            __INDICATOR="\\"
            ;;
        '\\')
            __INDICATOR="|"
            ;;
        *)
            __INDICATOR='/'
            ;;
    esac
    printf "\b${__INDICATOR}"
}

# sanity checks
if ! echo ${PARTS} | grep -qw kernel || \
    ! echo ${PARTS} | grep -qw base; then
    cat <<- EOF
Your \$PARTS should at least contain \`kernel'
and \`base'.
EOF
    exit 1
fi

log_begin_msg "Preparing work space"

BASEDIR=$(mktemp -d /tmp/mondieu.XXXX)
RELEASE=${BASEDIR}/release
TMP=${BASEDIR}/tmp

cleanup 1
trap "cleanup" EXIT INT
mkdir ${TMP} ${RELEASE}
log_end_msg

# fetch archives and extract all files
log_begin_msg "Fetching release ${UPGRADE}"

# prepare release dir
if [ -d ${RELEASE} ]; then
    find ${RELEASE} -flags +schg -exec chflags noschg {} \;
    rm -r ${RELEASE}
fi
mkdir -p ${RELEASE}

for part in ${PARTS}; do
    echo -n "${part} "
    fetch -q -o - ${URL}/${part}.txz | \
        tar -Jxf - -C ${RELEASE}/
done
log_end_msg

# go over all files in extracted release
# if file is not present in current fs
# or signature is not matching, it should be staged
: > ${TMP}/stage.list
: > ${TMP}/etcdiff.list
log_begin_msg "Comparing ${UPGRADE} to current release"
echo -n " " # padding indicator
for file in $(cd ${RELEASE}; find ./); do
    # gather info of files
    file=$(echo ${file} | sed 's/^\.//')
    spath="${RELEASE}/${file}"
    dpath="${ROOT}/${file}"
    owner=$(stat -f %Su ${spath})
    group=$(stat -f %Sg ${spath})
    mode=$(stat -f %Op ${spath} | sed -E 's/.*([0-9]{4})$/\1/')
    flags=$(stat -f %Sf ${spath})
    link=$(readlink ${spath} || true)
    if [ -d ${spath} ]; then
        type=d
    elif [ -L ${spath} ]; then
        type=L
    else
        type=f
        signature=$(sha256 -q ${spath})
    fi

    indicate

    case $type in
        d)
            # we stage all directories
            # so we can set the right flags later on
            ;;
        f)
            # if file already exists, try to detect whether
            # it should be staged or not
            if [ -f ${dpath} ]; then
                # don't stage identical files
                if [ "$(sha256 -q ${dpath})" = "${signature}" ]; then
                    continue
                fi

                # check if anything beside FreeBSD header
                # was even changed
                if echo ${file} | grep -q '\.gz$' && \
                    samegz ${spath} ${dpath}; then
                    continue
                elif samef ${spath} ${dpath}; then
                    continue
                fi

                # don't add base configuration to stage
                if echo ${file} | grep -q '^/etc/'; then
                    echo ${file} >> ${TMP}/etcdiff.list
                    continue
                fi
            fi
            ;;
        L)
            # check where link is pointing to
            if [ -L ${dpath} ] && [ "$(readlink ${dpath})" = "${link}" ]; then
                continue
            fi
            ;;
        *)
            echo "Unknown type ${type} (${file})"
            exit 1
            ;;
    esac

    echo "${file}|${type}|${owner}|${group}|${mode}|${flags}|${signature}|${link}" >> ${TMP}/stage.list
done
log_end_msg

# if no files should be staged, we're done
STAGECOUNT=$(wc -l < ${TMP}/stage.list | awk '{print $1}')
if [ ${STAGECOUNT} -eq 0 ]; then
    echo "No files need to be upgraded"
    exit
fi

# show summary
(echo -n "The following files will be updated/added "; \
 echo "as part of upgrading to ${UPGRADE}:"; \
 awk -F'|' '{if ($2 == "f") {print $1}}' ${TMP}/stage.list | sort) | ${PAGER}

# get confirmation to apply upgrade
echo -n "Installing upgrade to ${UPGRADE}, proceed? [y/n]: "
read CONFIRM
if ! checkyesno ${CONFIRM}; then
    exit
fi

if [ "$(wc -l < ${TMP}/etcdiff.list)" -gt 0 ]; then
    cat <<-EOF
We will now interactively merge your configuration files with the
new release's. For each part choose whether you want the left (l or 1)
or right (r or 2) side of the diff. You can also edit a part before
chosing it, with el/e1 and er/e2 for left and right respectively.

If you decide to stop during merging, none of your current config files
will be touched.

Press any key to proceed:
EOF
read DISCARD

    cat ${TMP}/etcdiff.list | while read file; do
        case ${file} in
            # Don't merge these -- we're rebuild them
            # after updates are installed.
            /etc/spwd.db | /etc/pwd.db | /etc/login.conf.db)
                ;;

            # Invoke sdiff to merge files interactively
            *)
                if ! cmp ${ROOT}/${file} ${RELEASE}/${file}; then
                    echo "==> Merging file: ${file}"
                    if ! sdiff -s -w $(tput cols) -o ${RELEASE}/${file}.new ${ROOT}/${file} ${RELEASE}/${file} < /dev/tty && [ $? -eq 2 ]; then
                        echo "Merge aborted at ${file}"
                        exit
                    fi

                    mv ${RELEASE}/${file}.new ${RELEASE}/${file}
                fi
                ;;
        esac

        unstage ${file} ${TMP}/etcdiff.list ""
    done
fi

log_begin_msg "Moving files into place"
echo -n " " # padding indicator
tr '|' ' ' < ${TMP}/stage.list | \
    while read file type owner group mode flags signature link; do

    indicate

    case $type in
        d)
            # Create a directory
            install -d -o ${owner} -g ${group} \
                -m ${mode} ${ROOT}/${file}
            ;;
        f)
            if [ -z "${link}" ]; then
                # Install file, without flags
                install -S -o ${owner} -g ${group} \
                    -m ${mode} ${RELEASE}/${file} ${ROOT}/${file}
            else # do we even have these?
                # Create hard link
                ln -f ${ROOT}/${link} ${ROOT}/${file}
            fi
            ;;
        L)
            # Create symbolic link
            ln -sfh ${link} ${ROOT}/${file}
            ;;
        *)
            echo "unknown type ${type} ($file)"
            exit;
    esac
done
log_end_msg

log_begin_msg "Setting flags"
echo -n " " # padding indicator
tr '|' ' ' < ${TMP}/stage.list | \
    while read file type owner group mode flags signature link; do

    indicate

    if [ "${type}" = "f" ] && \
        ! [ "${flags}" != "" ]; then
        chflags ${flags} ${ROOT}/${file}
    fi
    done
log_end_msg

log_begin_msg "Updating passwd dbs"
pwd_mkdb -d ${ROOT}/etc ${ROOT}/etc/master.passwd
cap_mkdb -f ${ROOT}/etc/login.conf.db ${ROOT}/etc/login.conf
log_end_msg

cat <<- EOF
    Succesfully upgraded from $(uname -r) to ${UPGRADE}.
    You should reboot your system now, since new binaries are
    expecting to run under the new kernel.
EOF

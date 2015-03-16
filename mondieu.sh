#!/bin/sh

# TODO: how to detect files that are deprecated/delete old files
# TODO: perform signature checking
# TODO: when /boot/gptboot or /boot/gptzfsboot changes, warn
# TODO: do staging and samef/samegz all in one run

set -e

ROOT=/mnt
BASEDIR=/tmp/mondieu
RELEASE=${BASEDIR}/release
TMP=${BASEDIR}/tmp
UPGRADE=10.1-TRANSBSD
URL=http://mondieu.skoef.net/${UPGRADE}
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

log_begin_msg "Preparing work space"
cleanup 1
trap "cleanup" EXIT INT
[ ! -d ${BASEDIR} ] && mkdir ${BASEDIR}
mkdir ${TMP} ${RELEASE}
log_end_msg

log_begin_msg "Fetching main index"
fetch -q -o ${TMP} ${URL}/index.map ${URL}/index.sign
log_end_msg


log_begin_msg "Fetching available indexes"
tr '|' ' ' < ${TMP}/index.map | while read index signature; do
    fetch -q -o ${TMP} ${URL}/${index}.map
    if [ "$(sha256 -q ${TMP}/${index}.map)" != "${signature}" ]; then
        echo "Checksum mismatch in index ${index}"
        exit 1
    fi
done
log_end_msg

# go over all files in each index
# if file is not present in current fs
# or hash is not matching, it should be staged
: > ${TMP}/stage.list
log_begin_msg "Examining diffs"
for MAP in $(cd ${TMP}; find . -name '*.map' ! -name 'index.map'); do
    part=$(basename ${MAP} | sed -e 's/\.map$//')
    echo -n "${part} "
    tr '|' ' ' < ${TMP}/${MAP} | \
    while read file type owner group mode flags signature link; do
        stage=1
        case $type in
            d)
                [ -d ${ROOT}${file} ] && stage=0
                ;;
            f)
                [ -f ${ROOT}${file} ] && [ "$(sha256 -q ${ROOT}${file})" = "${signature}" ] && stage=0
                ;;
            L)
                [ -L ${ROOT}${file} ] && [ "$(readlink ${ROOT}${file})" = "${link}" ] && stage=0
                ;;
            *)
                echo "Unknown type ${type} (${file})"
                exit
                ;;
        esac

        if [ ${stage} -eq 1 ]; then
            echo "${part}|${file}|${type}|${owner}|${group}|${mode}|${flags}|${signature}|${link}" >> ${TMP}/stage.list
        fi
    done
done
log_end_msg

# if no files should be staged, we're done
STAGECOUNT=$(wc -l < ${TMP}/stage.list | awk '{print $1}')
if [ ${STAGECOUNT} -eq 0 ]; then
    echo "No files need to be upgraded"
    exit
fi

# fetch archives and extract all files
log_begin_msg "Fetching release"

if [ -d ${RELEASE} ]; then
    find ${RELEASE} -flags +schg -exec chflags noschg {} \;
    rm -r ${RELEASE}
fi
mkdir -p ${RELEASE}

awk -F'|' '{print $1}' ${TMP}/stage.list | sort -u | while read package; do
    echo -n "${package} "
    fetch -q -o - ${URL}/archives/${package}.txz | \
        tar -Jxf - -C ${RELEASE}/
done
log_end_msg

# check signature and move files to staging
log_begin_msg "Checking integrity for ${STAGECOUNT} files"
: > ${TMP}/etcdiff.list
tr '|' ' ' < ${TMP}/stage.list | \
while read package file type owner group mode flags signature link; do
    if [ "${type}" != "f" ]; then
        continue
    fi

    if [ ! -f ${RELEASE}${file} ]; then
        echo "${file} should be there, but is missing"
        exit 1
    fi

    if [ "$(sha256 -q ${RELEASE}${file})" != "${signature}" ]; then
        echo "error: ${file} did not match signature ${signature}"
        exit 1
    fi

    # see if anything else diffs besides FreeBSD marker
    if file -b ${RELEASE}${file} | grep -q "ASCII text" && \
        [ -f $file ]; then
        if samef ${file} ${RELEASE}${file}; then
            unstage ${file}
            continue
        fi

        # record updated files in /etc
        # so we can offer user to merge/diff them
        # later on
        if echo ${file} | grep -q '^/etc/'; then
            unstage ${file}
            echo ${file} >> ${TMP}/etcdiff.list
        fi

        continue
    fi

    # filter same compressed files
    if file -b ${RELEASE}${file} | grep -q 'gzip' && \
        [ -f ${file} ] && samegz ${file} ${RELEASE}${file}; then
        unstage ${file}
        continue
    fi
done
log_end_msg

# show summary
(echo -n "The following files will be updated/added "; \
 echo "as part of upgrading to ${UPGRADE}:"; \
 awk -F'|' '{if ($3 == "f") {print $2}}' ${TMP}/stage.list | sort) | ${PAGER}

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
tr '|' ' ' < ${TMP}/stage.list | \
    while read package file type owner group mode flags signature link; do
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
tr '|' ' ' < ${TMP}/stage.list | \
    while read package file type owner group mode flags signature link; do
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

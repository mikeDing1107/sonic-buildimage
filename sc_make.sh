#!/bin/bash

# This script is used to automate the build process of Sonic for Marvell platforms
# NOTE: Change CACHE_DIR and ARTIFACTS_DIR as per your requirement.

# arguments
INPUT=$@
BUILD_SAISERVER="N"
BUILD_RPC="N"
OTHER_BUILD_OPTIONS=""
NO_CACHE="N"
VERIFY_PATCHES="N"
PATCHING_CONFIG_AND_STOP="N"
# l_ -- local to avoid potential collision with sonic-buildimage project rules
l_DEBIAN="bookworm"

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# Set MIRROR to the public mirror for the build
MIRROR="publicmirror.azurecr.io"
VERSION_CONTROL_COMPONENTS="deb,py2,py3,web,git,docker"
REL_BUILD_TSTAMP=$(date +'%d-%m-%Y_%H-%M')
CACHE_DIR=/var/cache/sonic-mrvl
ARTIFACTS_DIR=/sonic-artifacts
BRANCH=""202505
BUILD_PLATFORM="marvell-prestera"
BUILD_PLATFORM_ARCH="arm64"
PATCH_SCRIPT_URL="https://github.com/Marvell-switching/sonic-scripts/raw/refs/heads/master/marvell_sonic_patch_script.sh"
DIR_PREFIX="ABU"
ENABLE_DOCKER_BASE_PULL_YN="ENABLE_DOCKER_BASE_PULL=n"

# Determine "wrong" architecture sub-string vs MACHINE_ARCH
MACHINE_ARCH=$(uname -m)
case "$MACHINE_ARCH" in
    x86_64|i386|i686)
        ARCH_WRONG_SSTR="arm"
        ;;
    aarch64|armv7l|armv8l)
        ARCH_WRONG_SSTR="amd"
        ;;
    *)
        ARCH_WRONG_SSTR="UNKNOWN"
        ;;
esac
if [[ "$INPUT" == *"$ARCH_WRONG_SSTR"* ]]; then
    echo "Wrong input. Only NATIVE-ARCH build supported. Check arm vs amd"
    exit 1
fi

# Script-debug/trace option "-e"
#set -e

print_usage()
{
    echo "Usage:"
    echo ""
    echo " $0"
    echo "   [-t <type>]"
    echo "   [-T <target>]"
    echo "   [-P <product>]"
    echo ""
    echo "    -t : Build type"
    echo "    -T : Build target"
    echo "    -P : Build product"
echo """
Example:
./sc_make.sh -t all -P KaiTian 
./sc_make.sh -t image -P KaiTian
./sc_make.sh -T docker-teamd.gz -P DingDing
./sc_make.sh -T debs/bookworm/tkmib_5.9.3+dfsg-2_all.deb -P DingDing
"""
}

parse_arguments()
{
    while [[ $# -gt 0 ]]; do
        case $1 in
            -b|--branch)
                BRANCH="$2"
                shift # past argument
                shift # past value
                ;;
	    -P|--product)
		BUILD_PRODUCT="$2"
		shift # past argument
                shift # past value
                ;;
            -p|--platform)
                BUILD_PLATFORM="$2"
                shift # past argument
                shift # past value
                ;;
            -a|--arch)
                BUILD_PLATFORM_ARCH="$2"
                shift # past argument
                shift # past value
                ;;
            -c|--commit)
                BRANCH_COMMIT="$2"
                shift # past argument
                shift # past value
                ;;
	    -t|--type)
                BUILD_TYPE="$2"
                shift # past argument
                shift # past value
                ;;
	    -T|--target)
                BUILD_TARGET="$2"
                shift # past argument
                shift # past value
                ;;
            -C)
                PATCHING_CONFIG_AND_STOP="Y"
                shift # past argument
                ;;
            -s|--saiserver)
                BUILD_SAISERVER="Y"
                shift # past argument
                ;;
            -r|--rpc)
                BUILD_RPC="Y"
                shift # past argument
                ;;
            --no-cache)
                NO_CACHE="Y"
                shift # past argument
                ;;
            --mark_no_del_ws)
                NO_DEL_WS="Y"
                shift # past argument
                ;;
            --patch_script)
                PATCH_SCRIPT_URL="$2"
                shift # past argument
                shift # past value
                ;;
            --url)
                GIT_HUB_URL="$2"
                shift # past argument
                shift # past value
                ;;
            --SAI)
                SAI_URL_PATH="$2"
                shift # past argument
                shift # past value
                ;;
            --admin_password)
                ADMIN_PASSWORD="$2"
                shift # past argument
                shift # past value
                ;;
            --other_build_options)
                OTHER_BUILD_OPTIONS="$2"
                shift # past argument
                shift # past value
                ;;
            --verify_patches)
                VERIFY_PATCHES="Y"
                shift # past argument
                ;;
            --clean_dockers)
                CLEAN_DOCKERS="Y"
                shift # past argument
                ;;
            --clean_ws)
                CLEAN_WS="Y"
                shift # past argument
                ;;
            -h|--help)
                print_usage
                exit 1
                ;;
            *)
                echo "ERROR: Unknown option '$1'"
                print_usage
                exit 1
                ;;
        esac
    done

    if [ -z "${BRANCH}" ]; then
        echo "Branch is not set. Please check usage."
        print_usage
        exit 0
    fi

    if [ -z "${BUILD_PLATFORM}" ]; then
        echo "Platform target is not set. Please check usage."
        print_usage
        exit 0
    fi

    if [ -z "${BUILD_PLATFORM_ARCH}" ]; then
        echo "Architecture target is not set. Please check usage."
        print_usage
        exit 0
    fi

    if [ -z "${GIT_HUB_URL}" ]; then
        GIT_HUB_URL="https://github.com/sonic-net/sonic-buildimage.git"
    fi

    if [ "${BUILD_PLATFORM}" == "marvell" ] || [ "${BUILD_PLATFORM}" == "marvell-arm64" ] || [ "${BUILD_PLATFORM}" == "marvell-armhf" ]; then
        PLATFORM_SHORT_NAME="mrvl"
        DIR_PREFIX="ABM"
    fi

    if [ "$BUILD_PLATFORM" == "innovium" ]; then
        PLATFORM_SHORT_NAME="invm"
        DIR_PREFIX="ABI"
    fi

    if [ "$BUILD_PLATFORM" == "marvell-teralynx" ]; then
        PLATFORM_SHORT_NAME="mrvl-teralynx"
        DIR_PREFIX="ABT"
    fi

    if [ "$BUILD_PLATFORM" == "marvell-prestera" ]; then
        PLATFORM_SHORT_NAME="mrvl-prestera"
        DIR_PREFIX="ABP"
    fi

    # TRIXIE overrides
    if [ "${BRANCH}" == "master" ] || [ "${BRANCH}" = "202511" ]; then
        l_DEBIAN="trixie"
        #ENABLE_DOCKER_BASE_PULL_YN=""
        #NO_CACHE=Y
        #echo -e "\n Force: no ENABLE_DOCKER_BASE_PULL and no-cache\n"
    fi
}

on_error()
{
    set +x
    cd $DIR
    mv $SONIC_SOURCE_DIR $SONIC_SOURCE_DIR-err
    echo -e "\n\n--- `date` --- Build Error ---------\n\n"
    exit 1
}

check_error()
{
    if [ $1 -ne 0 ]; then
        set +x
        echo "Error in building - $2"
        on_error
    else
        echo -e "\n--------- $2   passed ---------\n\n\n"
    fi
}

check_error_with_retry()
{
    n=0
    res=$1
    #set +x
    if [[ $res -ne 0 && $SONIC_BUILD_JOBS -ge 1 ]]; then
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches
        ((n=n+1))
        echo -e "\n--SONIC_BUILD_JOBS=$SONIC_BUILD_JOBS --------------------------------------------------"
        echo "Error in building $2, going to retry-$n in 20 sec (to abort press CTRL-C)"
        sleep 10
        echo "Error in building $2, going to retry-$n in 10 sec (to abort press CTRL-C)"
        sleep 10
        echo "----------------------------------------------------------------------"
        echo -e "     Retry build $2 started \n\n"
        eval "$3"
        res=$?
    fi
    if [ $res -ne 0 ]; then
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches
        ((n=n+1))
        echo -e "\n----------------------------------------------------------------------"
        echo "Error in building $2, going to retry-$n in 20 sec (to abort press CTRL-C)"
        sleep 10
        echo "Error in building $2, going to retry-$n in 10 sec (to abort press CTRL-C)"
        sleep 10
        echo "----------------------------------------------------------------------"
        echo -e "     Retry build $2 started \n\n"
        export SONIC_BUILD_JOBS=1
        eval "$3"
        check_error $? $2
    fi
}

check_free_space()
{
    local dir=$1
    local ALERT=$2

	if [ -v CLEAN_WS ]; then
	  df -H $dir | grep -vE '^Filesystem' | awk '{ print $5 " " $1 }' | while read -r output;
	  do
		echo "$output"
		usep=$(echo "$output" | awk '{ print $1}' | cut -d'%' -f1 )
		partition=$(echo "$output" | awk '{ print $2 }' )
		if [ $usep -ge $ALERT ]; then
			echo "Running out of space \"$partition ($usep%)\" on $(hostname) as on $(date)" |
				ls -1  | grep "${DIR_PREFIX}-" | grep "-err" | while read -r dir_name;
						do
							echo "Removing $dir_name"
							if [ ! -f $dir_name/no_del_ws ]; then
								sudo rm -rf $dir_name
							fi
						done
						# Check space again after removing errored build
						df -H $dir | grep -vE '^Filesystem' | awk '{ print $5 " " $1 }' | while read -r output_new;
					do
						echo "$output_new"
						usep=$(echo "$output_new" | awk '{ print $1}' | cut -d'%' -f1 )
						if [ $usep -ge $ALERT ]; then
							# Remove build dirs
							ls -1  | grep "${DIR_PREFIX}-" | while read -r dir_name;
						do
							echo "Removing $dir_name"
							if [ ! -f $dir_name/no_del_ws ]; then
								sudo rm -rf $dir_name
							fi
						done
						fi
					done
		fi
	  done
	fi

df -H $dir | grep -vE '^Filesystem' | awk '{ print $5 " " $1 }' | while read -r output;
do
    usep=$(echo "$output" | awk '{ print $1}' | cut -d'%' -f1 )
    if [ $usep -ge $ALERT ]; then
        echo "Not enough space. Please check build server to free space."
        echo "Optionally you can use --clean_dockers or --clean_ws after pushing your local changes"
        exit 1
    fi
done
}

cleanup_server()
{
    if [ -v CLEAN_DOCKERS ]; then
        # Remove all stopped containers
        docker system prune -a --volumes -f
    fi

    # check for disk space and cleanup
    check_free_space . 65
}

clone_ws()
{
    # Clone the Sonic source code
    if [ -z $BRANCH_COMMIT ]; then
        SONIC_SOURCE_DIR=$DIR_PREFIX-$BRANCH-$REL_BUILD_TSTAMP
    else
        SONIC_SOURCE_DIR=$DIR_PREFIX-$BRANCH-$REL_BUILD_TSTAMP-$BRANCH_COMMIT
    fi
    sudo rm -rf $SONIC_SOURCE_DIR
    mkdir $SONIC_SOURCE_DIR
    cd $SONIC_SOURCE_DIR
    if [ -v NO_DEL_WS ]; then
        touch no_del_ws
    fi
    git clone -b $BRANCH $GIT_BRANCH_PARAM $GIT_HUB_URL
    check_error $? "git-clone"
    cd sonic-buildimage
    echo "##Only if needed - clear caches to free disk space:" > build_cmd.txt
    echo "##   docker system prune -a --volumes -f" >> build_cmd.txt
    echo "##   sudo rm -rf /var/cache/sonic-mrvl/"  >> build_cmd.txt
    echo "##OR use --clean_dockers option"   >> build_cmd.txt
    echo "git clone -b $BRANCH $GIT_BRANCH_PARAM $GIT_HUB_URL" >> build_cmd.txt
    if [[ -v BRANCH_COMMIT && $BRANCH_COMMIT != $BRANCH ]]; then
        echo "git checkout $BRANCH_COMMIT" >> build_cmd.txt
        git checkout $BRANCH_COMMIT
        check_error $? "git-checkout-commit"
    fi
    git log -1 > commit_log.txt
}

# commit_id_*
# Function 1: Get and save upstream commit ID
# Function 2: Generate custom COMMIT_ID_STR and update files with sed
commit_id_get_upstream()
{
    export UPSTREAM_ID="$(git rev-parse --short HEAD)"
}

commit_id_update()
{
    if [[ -z "$UPSTREAM_ID" ]]; then
        return 0
    fi
    VER_SH_1=build_debian.sh
    VER_SH_2=platform/vs/sonic-version/build_sonic_version.sh
    HEAD_ID="$(git rev-parse --short HEAD)"
    PATCH_COUNT="$(git rev-list --count ${UPSTREAM_ID}..HEAD)"
    export COMMIT_ID_STR="${UPSTREAM_ID} + ${PATCH_COUNT} mrvl-patches"

    for ver_file in ${VER_SH_1} ${VER_SH_2}; do
        if [[ ! -f "$ver_file" ]]; then
            echo "Warning: $ver_file not found for version updated"
            continue
        fi
        sed -i -E "s|^(export commit_id=).*|\1\"${COMMIT_ID_STR}\"|"  "$ver_file"
        echo "Force commit_id: $COMMIT_ID_STR  in file $ver_file"
    done
    echo ""
}

patch_sai_url_path()
{
    # Handle input --SAI $SAI_URL_PATH like
    # --SAI http://10.2.141.103:8080/mrvllibsai/mrvllibsai_1.16.1-1_arm64.deb

    # Check url file availability
    wget --timeout=2 --spider $SAI_URL_PATH
    check_error $? "SAI-URL check"

    SAI_MK_FILE=platform/${BUILD_PLATFORM}/sai.mk
    SAI_DEB_URL=$(dirname "$SAI_URL_PATH")
    SAI_DEB_FILE=$(basename "$SAI_URL_PATH")

    # Escape ampersands for sed
    safe_url_path=${SAI_DEB_URL//&/\\&}
    safe_file_name=${SAI_DEB_FILE//&/\\&}

    # Use '|' as the sed delimiter to avoid escaping '/'
    sed -i -E \
        -e "s|^MRVL_SAI_URL_PREFIX *=.*|MRVL_SAI_URL_PREFIX = $safe_url_path|" \
        -e "s|^MRVL_SAI *=.*|MRVL_SAI = ${safe_file_name}|" \
        "${SAI_MK_FILE}" >/dev/null 2>&1

    check_error $? "SAI-URL patching"
}

apply_sercomm_patches()
{
	CWD=`pwd`
	cat series_sercomm-prestera_arm64 | grep -v -E '^#|^$' | grep -v sonic-buildimage | while read -r line
 do
        patch=`echo $line | cut -f 1 -d'|'`
        dir=`echo $line | cut -f 2 -d'|'`
        pushd ${dir}
        git am $CWD/patches/${patch}
        ret=$?
        if [ $ret -ne 0 ]; then
        ((err_cnt++))
                if [ "$PATCH_ERR_SKIP" == "" ]; then
                        log "PATCH ERROR: Failed to apply submodule $CWD/patches/${patch}, abort"
                        return $ret
                fi
                log "PATCH ERROR: Failed to apply submodule $CWD/patches/${patch}, skeep and continue"
                git am --skip
        fi
        popd
 done
}

patch_ws()
{
    if [ -v PATCH_SCRIPT_URL ]; then
        if [[ "$PATCH_SCRIPT_URL" == *:* ]]; then
            isUrl=1
        else
            isUrl=
        fi
        URL=${PATCH_SCRIPT_URL%marvell_sonic_patch_script.sh}
        if [ "$isUrl" = "1" ]; then
            wget --timeout=2 -c $PATCH_SCRIPT_URL
        else
            cp $PATCH_SCRIPT_URL .
        fi
        commit_id_get_upstream
        echo "bash marvell_sonic_patch_script.sh --branch ${BRANCH} --platform ${BUILD_PLATFORM} --arch ${BUILD_PLATFORM_ARCH} --url ${URL}" >> build_cmd.txt
        bash marvell_sonic_patch_script.sh --branch ${BRANCH} --platform ${BUILD_PLATFORM} --arch ${BUILD_PLATFORM_ARCH} --url ${URL}
        check_error $? "patch_script"
        commit_id_update

        if ! [ -z "${SAI_URL_PATH}" ]; then
            patch_sai_url_path
        fi

	apply_sercomm_patches
	cp sc_build/kaitian/dts/* platform/marvell-prestera/mrvl-prestera/platform/arm64/common/boot/
	cp sc_build/kaitian/config/* device/marvell/arm64-marvell_rd98DX45xx_cn9131-r0/rd98DX45xx_cn9131/
	echo > patch_done
    fi
}

build_init()
{
    local startTime=$SECONDS

    # Set the build options
    mkdir -p $CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH
    BUILD_OPTIONS=""
    if [ "$NO_CACHE" == "N" ]; then
        BUILD_OPTIONS="DEFAULT_CONTAINER_REGISTRY=${MIRROR} SONIC_VERSION_CONTROL_COMPONENTS=${VERSION_CONTROL_COMPONENTS} SONIC_DPKG_CACHE_METHOD=rwcache SONIC_DPKG_CACHE_SOURCE=$CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH/"
    fi
    if [ "$BUILD_RPC" == "Y" ]; then
        if [ "$BUILD_PLATFORM_ARCH" != "armhf" ]; then
            BUILD_OPTIONS="${BUILD_OPTIONS} ENABLE_SYNCD_RPC=y"
        fi
    fi
    if [[ ! -z ${OTHER_BUILD_OPTIONS} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} ${OTHER_BUILD_OPTIONS}"
    fi
    if [[ ! -z ${ADMIN_PASSWORD} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} DEFAULT_PASSWORD=${ADMIN_PASSWORD}"
    fi

    # Check the init has already been done by marvell_sonic_patch_script.sh
    if [ ! -d .git/modules/ ]; then
        echo "make init" >> build_cmd.txt
        make init
        check_error $? "make_init"
        # Fetch/expose advanced submodule hashes which are not taken by "make init"
        git submodule foreach --recursive 'git fetch --all'
    fi

    set +x
    local endTime=$SECONDS
    local elapsedseconds=$(( endTime - startTime ))
    echo   "***************************************************"
    printf ' Build took - %dh:%dm:%ds\n' $((elapsedseconds/3600)) $((elapsedseconds%3600/60)) $((elapsedseconds%60))
    echo   "***************************************************"
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml 2>/dev/null
    echo ""
    echo "" >> commit_log.txt
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml >> commit_log.txt
}

build_configure()
{
    local startTime=$SECONDS

    # Set the build options
    mkdir -p $CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH
    BUILD_OPTIONS=""
    if [ "$NO_CACHE" == "N" ]; then
        BUILD_OPTIONS="DEFAULT_CONTAINER_REGISTRY=${MIRROR} SONIC_VERSION_CONTROL_COMPONENTS=${VERSION_CONTROL_COMPONENTS} SONIC_DPKG_CACHE_METHOD=rwcache SONIC_DPKG_CACHE_SOURCE=$CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH/"
    fi
    if [ "$BUILD_RPC" == "Y" ]; then
        if [ "$BUILD_PLATFORM_ARCH" != "armhf" ]; then
            BUILD_OPTIONS="${BUILD_OPTIONS} ENABLE_SYNCD_RPC=y"
        fi
    fi
    if [[ ! -z ${OTHER_BUILD_OPTIONS} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} ${OTHER_BUILD_OPTIONS}"
    fi
    if [[ ! -z ${ADMIN_PASSWORD} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} DEFAULT_PASSWORD=${ADMIN_PASSWORD}"
    fi

    # Build Sonic
    echo -e "$INPUT\n" > build_args.txt
    echo $BUILD_OPTIONS >> build_args.txt
    echo "" >> build_cmd.txt

    if [ "$BUILD_PLATFORM_ARCH" == "amd64" ]; then
        PLATFORM_ARCH_PARAM=""
    else
        PLATFORM_ARCH_PARAM="PLATFORM_ARCH=${BUILD_PLATFORM_ARCH}"
    fi

    # make configure
    echo "${ENABLE_DOCKER_BASE_PULL_YN} make configure PLATFORM=${BUILD_PLATFORM} $BUILD_OPTIONS ${PLATFORM_ARCH_PARAM}" >> build_cmd.txt
    eval "${ENABLE_DOCKER_BASE_PULL_YN} make configure PLATFORM=${BUILD_PLATFORM} $BUILD_OPTIONS ${PLATFORM_ARCH_PARAM}"
    check_error $? "configure"
    echo "" >> build_cmd.txt

    set +x
    local endTime=$SECONDS
    local elapsedseconds=$(( endTime - startTime ))
    echo   "***************************************************"
    printf ' Build took - %dh:%dm:%ds\n' $((elapsedseconds/3600)) $((elapsedseconds%3600/60)) $((elapsedseconds%60))
    echo   "***************************************************"
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml 2>/dev/null
    echo ""
    echo "" >> commit_log.txt
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml >> commit_log.txt
}

build_image()
{
    local startTime=$SECONDS

    # Set the build options
    mkdir -p $CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH
    BUILD_OPTIONS=""
    if [ "$NO_CACHE" == "N" ]; then
        BUILD_OPTIONS="DEFAULT_CONTAINER_REGISTRY=${MIRROR} SONIC_VERSION_CONTROL_COMPONENTS=${VERSION_CONTROL_COMPONENTS} SONIC_DPKG_CACHE_METHOD=rwcache SONIC_DPKG_CACHE_SOURCE=$CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH/"
    fi
    if [ "$BUILD_RPC" == "Y" ]; then
        if [ "$BUILD_PLATFORM_ARCH" != "armhf" ]; then
            BUILD_OPTIONS="${BUILD_OPTIONS} ENABLE_SYNCD_RPC=y"
        fi
    fi
    if [[ ! -z ${OTHER_BUILD_OPTIONS} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} ${OTHER_BUILD_OPTIONS}"
    fi
    if [[ ! -z ${ADMIN_PASSWORD} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} DEFAULT_PASSWORD=${ADMIN_PASSWORD}"
    fi

    # make target
    if [ "${BUILD_PLATFORM_ARCH}" == "amd64" ] || [ "${BUILD_PLATFORM}" == "marvell-arm64" ] || [ "${BUILD_PLATFORM}" == "marvell-armhf" ]; then
        TARGET_FILE=sonic-${BUILD_PLATFORM}.bin
        TARGET=target/sonic-${BUILD_PLATFORM}.bin
    else
        TARGET_FILE=sonic-${BUILD_PLATFORM}-${BUILD_PLATFORM_ARCH}.bin
        TARGET=target/sonic-${BUILD_PLATFORM}-${BUILD_PLATFORM_ARCH}.bin
    fi
    echo "make $BUILD_OPTIONS ${TARGET}" >> build_cmd.txt
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    if [ "$PATCHING_CONFIG_AND_STOP" == "Y" ]; then
        exit 0
    fi
    make $BUILD_OPTIONS ${TARGET}
    check_error_with_retry $? "${TARGET_FILE}" "make $BUILD_OPTIONS ${TARGET}"

    set +x
    local endTime=$SECONDS
    local elapsedseconds=$(( endTime - startTime ))
    echo   "***************************************************"
    printf ' Build took - %dh:%dm:%ds\n' $((elapsedseconds/3600)) $((elapsedseconds%3600/60)) $((elapsedseconds%60))
    echo   "***************************************************"
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml 2>/dev/null
    echo ""
    echo "" >> commit_log.txt
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml >> commit_log.txt
}

build_target()
{
    local startTime=$SECONDS

    # Set the build options
    mkdir -p $CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH
    BUILD_OPTIONS=""
    if [ "$NO_CACHE" == "N" ]; then
        BUILD_OPTIONS="FORCE_UNINTERRUPTABLE_MAKE=true DEFAULT_CONTAINER_REGISTRY=${MIRROR} SONIC_VERSION_CONTROL_COMPONENTS=${VERSION_CONTROL_COMPONENTS} SONIC_DPKG_CACHE_METHOD=rwcache SONIC_DPKG_CACHE_SOURCE=$CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH/"
    fi
    if [ "$BUILD_RPC" == "Y" ]; then
        if [ "$BUILD_PLATFORM_ARCH" != "armhf" ]; then
            BUILD_OPTIONS="${BUILD_OPTIONS} ENABLE_SYNCD_RPC=y"
        fi
    fi
    if [[ ! -z ${OTHER_BUILD_OPTIONS} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} ${OTHER_BUILD_OPTIONS}"
    fi
    if [[ ! -z ${ADMIN_PASSWORD} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} DEFAULT_PASSWORD=${ADMIN_PASSWORD}"
    fi

    TARGET=target/${BUILD_TARGET}
    echo "make $BUILD_OPTIONS ${TARGET}" >> build_cmd.txt
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    make $BUILD_OPTIONS ${TARGET}

    set +x
    local endTime=$SECONDS
    local elapsedseconds=$(( endTime - startTime ))
    echo   "***************************************************"
    printf ' Build took - %dh:%dm:%ds\n' $((elapsedseconds/3600)) $((elapsedseconds%3600/60)) $((elapsedseconds%60))
    echo   "***************************************************"
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml 2>/dev/null
    echo ""
    echo "" >> commit_log.txt
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml >> commit_log.txt
}

build_ws()
{
    local startTime=$SECONDS

    # Set the build options
    mkdir -p $CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH
    BUILD_OPTIONS=""
    if [ "$NO_CACHE" == "N" ]; then
        BUILD_OPTIONS="DEFAULT_CONTAINER_REGISTRY=${MIRROR} SONIC_VERSION_CONTROL_COMPONENTS=${VERSION_CONTROL_COMPONENTS} SONIC_DPKG_CACHE_METHOD=rwcache SONIC_DPKG_CACHE_SOURCE=$CACHE_DIR/$BRANCH/$BUILD_PLATFORM_ARCH/"
    fi
    if [ "$BUILD_RPC" == "Y" ]; then
        if [ "$BUILD_PLATFORM_ARCH" != "armhf" ]; then
            BUILD_OPTIONS="${BUILD_OPTIONS} ENABLE_SYNCD_RPC=y"
        fi
    fi
    if [[ ! -z ${OTHER_BUILD_OPTIONS} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} ${OTHER_BUILD_OPTIONS}"
    fi
    if [[ ! -z ${ADMIN_PASSWORD} ]]; then
        BUILD_OPTIONS="${BUILD_OPTIONS} DEFAULT_PASSWORD=${ADMIN_PASSWORD}"
    fi

    # Check the init has already been done by marvell_sonic_patch_script.sh
    if [ ! -d .git/modules/ ]; then
        echo "make init" >> build_cmd.txt
        make init
        check_error $? "make_init"
        # Fetch/expose advanced submodule hashes which are not taken by "make init"
        git submodule foreach --recursive 'git fetch --all'
    fi

    # Build Sonic
    echo -e "$INPUT\n" > build_args.txt
    echo $BUILD_OPTIONS >> build_args.txt
    echo "" >> build_cmd.txt

    if [ "$BUILD_PLATFORM_ARCH" == "amd64" ]; then
        PLATFORM_ARCH_PARAM=""
    else
        PLATFORM_ARCH_PARAM="PLATFORM_ARCH=${BUILD_PLATFORM_ARCH}"
    fi

    # make configure
    echo "${ENABLE_DOCKER_BASE_PULL_YN} make configure PLATFORM=${BUILD_PLATFORM} $BUILD_OPTIONS ${PLATFORM_ARCH_PARAM}" >> build_cmd.txt
    eval "${ENABLE_DOCKER_BASE_PULL_YN} make configure PLATFORM=${BUILD_PLATFORM} $BUILD_OPTIONS ${PLATFORM_ARCH_PARAM}"
    check_error $? "configure"
    echo "" >> build_cmd.txt

    # make target
    if [ "${BUILD_PLATFORM_ARCH}" == "amd64" ] || [ "${BUILD_PLATFORM}" == "marvell-arm64" ] || [ "${BUILD_PLATFORM}" == "marvell-armhf" ]; then
        TARGET_FILE=sonic-${BUILD_PLATFORM}.bin
        TARGET=target/sonic-${BUILD_PLATFORM}.bin
    else
        TARGET_FILE=sonic-${BUILD_PLATFORM}-${BUILD_PLATFORM_ARCH}.bin
        TARGET=target/sonic-${BUILD_PLATFORM}-${BUILD_PLATFORM_ARCH}.bin
    fi
    echo "make $BUILD_OPTIONS ${TARGET}" >> build_cmd.txt
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    if [ "$PATCHING_CONFIG_AND_STOP" == "Y" ]; then
        exit 0
    fi
    make $BUILD_OPTIONS ${TARGET}
    check_error_with_retry $? "${TARGET_FILE}" "make $BUILD_OPTIONS ${TARGET}"

    # Build SAI Server
    if [ "$BUILD_SAISERVER" == "Y" ] && [ "$BUILD_PLATFORM_ARCH" != "armhf" ]; then
        echo "make $BUILD_OPTIONS SAITHRIFT_V2=y target/docker-saiserverv2-${PLATFORM_SHORT_NAME}.gz" >> build_cmd.txt
              make $BUILD_OPTIONS SAITHRIFT_V2=y target/docker-saiserverv2-${PLATFORM_SHORT_NAME}.gz
        check_error $? "saiserver"
    fi

    set +x
    local endTime=$SECONDS
    local elapsedseconds=$(( endTime - startTime ))
    echo   "***************************************************"
    printf ' Build took - %dh:%dm:%ds\n' $((elapsedseconds/3600)) $((elapsedseconds%3600/60)) $((elapsedseconds%60))
    echo   "***************************************************"
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml 2>/dev/null
    echo ""
    echo "" >> commit_log.txt
    cat fsroot-marvell-prestera/etc/sonic/sonic_version.yml >> commit_log.txt
}

main()
{
    parse_arguments $@
    # Shell-script DEBUG setting
    # set -x

    cleanup_server

    #clone_ws

    if [ ! -f patch_done ]; then
    	patch_ws
    fi
    if [ "$VERIFY_PATCHES" == "Y" ]; then
        exit 0
    fi
    if [ "${l_DEBIAN}" == "bookworm" ] ||  [ "${l_DEBIAN}" == "trixie" ]; then
        echo "export NOJESSIE=1"   >> build_cmd.txt
        echo "export NOSTRETCH=1"  >> build_cmd.txt
        echo "export NOBUSTER=1"   >> build_cmd.txt
        echo "export NOBULLSEYE=1" >> build_cmd.txt
        #echo "export SONIC_IMAGE_VERSION=${SONIC_SOURCE_DIR}" >> build_cmd.txt
        export NOJESSIE=1
        export NOSTRETCH=1
        export NOBUSTER=1
        export NOBULLSEYE=1
        #export SONIC_IMAGE_VERSION=${SONIC_SOURCE_DIR}
        if [ "${l_DEBIAN}" == "trixie" ]; then
            echo "export NOBOOKWORM=0" >> build_cmd.txt
            echo "export NOTRIXIE=0" >> build_cmd.txt
            export NOBOOKWORM=0
            export NOTRIXIE=0
        fi
    fi

    if [[ ${BUILD_PRODUCT} == "KaiTian" || ${BUILD_PRODUCT} == "DingDing" ]]; then
	    echo "${BUILD_PRODUCT}" > Product
    else
	    echo "ERROR: Invalid product name. Only 'KaiTian' or 'DingDing' are allowed."
	    print_usage
	    exit 1
    fi

    if [ "${BUILD_TYPE}" == "init" ]; then
	    build_init
    fi

    if [ "${BUILD_TYPE}" == "configure" ]; then
	    build_configure
    fi

    if [ "${BUILD_TYPE}" == "image" ]; then
            build_image
    fi

    if [ "${BUILD_TYPE}" == "all" ]; then
    	    build_ws
    fi

    if [ -n "${BUILD_TARGET}" ]; then
            build_target
    fi
    set +x


    echo -e "\n\n Build Successful \n\n"
    exit 0
}

main $@

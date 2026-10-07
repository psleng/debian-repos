#!/bin/bash

set -e

if [ "$#" -eq 0 ]; then
    echo "run.sh: missing operands"
    echo "Requires source package name as argument"
    exit 1
fi

DEB_SUITE="${DEB_SUITE:-trixie}"

topdir=$(git rev-parse --show-toplevel)
projdir="${topdir}/$1"
sourcedir="${topdir}/build/sources"
builddir="${topdir}/build/${DEB_SUITE}/$1"
debcontroldir="${projdir}/suite/${DEB_SUITE}"

if [ ! -d ${projdir} ]; then
    echo "This project does not exist."
    echo "Exiting."
    exit 1
fi

source ${projdir}/version.sh

mkdir -p ${builddir}

package_name=$(cd ${debcontroldir} && dpkg-parsechangelog --show-field Source)
deb_version=$(cd ${debcontroldir} && dpkg-parsechangelog --show-field Version)
package_version=$(echo $deb_version | sed 's/\(.*\)-.*/\1/')
last_tested_commit=$(echo $package_version | sed 's/.*+//')
package_full="${package_name}-${package_version}"
package_full_ll="${package_name}_${package_version}"
echo "Building " $package_name " version " $deb_version

# Generate original source tarball if none found
if [ ! -f "${builddir}/${package_full_ll}.orig.tar.gz" ]; then
    mkdir -p "${sourcedir}"
    if [ ! -d "${sourcedir}/${package_name}" ]; then
        # PSL: Some repos are flaky, so retry the cloning
        for i in 1 2 3
        do
            git clone "${git_repo}" "${sourcedir}/${package_name}" && { i=''; break; }
            st=$?
            sleeptime=$((i * 30))
            echo "warning: Clone failed (status $st); sleeping $sleeptime and retrying"
            sleep $sleeptime
        done
        if test ! -z "$i"; then
            # Backup repo is TexasInstruments github; contains copy of git_repo sourced from version.sh
            backup_repo="https://github.com/TexasInstruments/$1"
            echo "warning: Cloning using backup repo ${backup_repo}"
            git clone "${backup_repo}" "${sourcedir}/${package_name}" && i=''
        fi
        if test ! -z "$i"; then
            # Clone failed. Try user-supplied backup tar file before giving up
            tarf=$topdir/../$package_name.tar.gz
            if [ -f $tarf ]; then
                echo "warning: trying to untar $tarf into $sourcedir"
                tar -C $sourcedir -zxf $tarf || {
                    echo "error: could not clone $git_repo"
                    echo "error:       and untar $tarf failed; giving up"
                    exit 1
                }
                echo "warning: untar $tarf succeeded; proceeding"
            else
                echo "error: could not clone $git_repo and $tarf not found"
                echo "error: giving up"
                exit 1
            fi
        fi
    fi
    git -C "${sourcedir}/${package_name}" remote update
    git -C "${sourcedir}/${package_name}" checkout "${last_tested_commit}"
    tar -czf "${builddir}/${package_full_ll}.orig.tar.gz" \
      --exclude-vcs \
      --absolute-names "${sourcedir}/${package_name}" \
      --transform "s,${sourcedir}/${package_name},${package_full},"
fi

# Generate source package if none found
if [ ! -f "${builddir}/${package_name}_${deb_version}.dsc" ]; then
    # Extract original source tarball
    tar -xzmf "${builddir}/${package_full_ll}.orig.tar.gz" -C "${builddir}"

    # Deploy our Debian control files
    cp -rv "${debcontroldir}/debian" "${builddir}/${package_full}/"

    # Build source package
    (cd "${builddir}/${package_full}" && dpkg-source -b .)

    # Cleanup intermediate source directory
    rm -r "${builddir}/${package_full}"
fi

# Generate binary package for this arch if not found
build_arch=$(dpkg --print-architecture)
if [ ! -f "${builddir}/${package_name}_${deb_version}_${build_arch}.buildinfo" ]; then
    run_prep || true

    # Extract source package
    if [ ! -d "${builddir}/${package_name}_${deb_version}" ]; then
        dpkg-source -x "${builddir}/${package_name}_${deb_version}.dsc" "${builddir}/${package_name}_${deb_version}"
    fi

    # Install build dependencies
    (cd "${builddir}/${package_name}_${deb_version}" && mk-build-deps -ir -t "apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends")

    # Build debian package.
    # HACK: There is an issue with building source package for Linux Kernel. So only build binary packages for Linux.
    if [[ "${package_name}" == "ti-linux-kernel"* ]]; then
        (cd "${builddir}/${package_name}_${deb_version}" && debuild --no-lintian --no-sign -b || true)
    else
        (cd "${builddir}/${package_name}_${deb_version}" && debuild --no-lintian --no-sign -sa || true)
    fi

    # Cleanup intermediate build directory
    rm -r "${builddir}/${package_name}_${deb_version}"
fi

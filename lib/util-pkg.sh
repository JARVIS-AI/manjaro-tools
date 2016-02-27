#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

pkgver_equal() {
	local left right

	if [[ $1 = *-* && $2 = *-* ]]; then
		# if both versions have a pkgrel, then they must be an exact match
		[[ $1 = "$2" ]]
	else
		# otherwise, trim any pkgrel and compare the bare version.
		[[ ${1%%-*} = "${2%%-*}" ]]
	fi
}

get_full_version() {
	# set defaults if they weren't specified in buildfile
	pkgbase=${pkgbase:-${pkgname[0]}}
	epoch=${epoch:-0}
	if [[ -z $1 ]]; then
		if [[ $epoch ]] && (( ! $epoch )); then
			echo $pkgver-$pkgrel
		else
			echo $epoch:$pkgver-$pkgrel
		fi
	else
		for i in pkgver pkgrel epoch; do
			local indirect="${i}_override"
			eval $(declare -f package_$1 | sed -n "s/\(^[[:space:]]*$i=\)/${i}_override=/p")
			[[ -z ${!indirect} ]] && eval ${indirect}=\"${!i}\"
		done
		if (( ! $epoch_override )); then
			echo $pkgver_override-$pkgrel_override
		else
			echo $epoch_override:$pkgver_override-$pkgrel_override
		fi
	fi
}

find_cached_package() {
	local searchdirs=("$PWD" "$PKGDEST") results=()
	local targetname=$1 targetver=$2 targetarch=$3
	local dir pkg pkgbasename pkgparts name ver rel arch size r results

	for dir in "${searchdirs[@]}"; do
		[[ -d $dir ]] || continue

		for pkg in "$dir"/*.pkg.tar.xz; do
			[[ -f $pkg ]] || continue

			# avoid adding duplicates of the same inode
			for r in "${results[@]}"; do
				[[ $r -ef $pkg ]] && continue 2
			done

			# split apart package filename into parts
			pkgbasename=${pkg##*/}
			pkgbasename=${pkgbasename%.pkg.tar?(.?z)}

			arch=${pkgbasename##*-}
			pkgbasename=${pkgbasename%-"$arch"}

			rel=${pkgbasename##*-}
			pkgbasename=${pkgbasename%-"$rel"}

			ver=${pkgbasename##*-}
			name=${pkgbasename%-"$ver"}

			if [[ $targetname = "$name" && $targetarch = "$arch" ]] &&
				pkgver_equal "$targetver" "$ver-$rel"; then
				results+=("$pkg")
			fi
		done
	done

	case ${#results[*]} in
		0)
		return 1
		;;
		1)
		printf '%s\n' "$results"
		return 0
		;;
		*)
		error 'Multiple packages found:'
		printf '\t%s\n' "${results[@]}" >&2
		return 1
		;;
	esac
}

check_build(){
	find_pkg $1
	[[ ! -f $1/PKGBUILD ]] && die "Directory must contain a PKGBUILD!"
}

find_pkg(){
	local result=$(find . -type d -name "$1")
	[[ -z $result ]] && die "%s is not a valid package or buildset!" "$1"
}

load_group(){
	local _multi \
		_space="s| ||g" \
		_clean=':a;N;$!ba;s/\n/ /g' \
		_com_rm="s|#.*||g" \
		devel_group='' \
		file=${DATADIR}/base-devel-udev

        info "Loading Group [%s] ..." "$file"

	if ${is_multilib}; then
		_multi="s|>multilib||g"
	else
		_multi="s|>multilib.*||g"
	fi

	devel_group=$(sed "$_com_rm" "$file" \
			| sed "$_space" \
			| sed "$_multi" \
			| sed "$_clean")

        echo ${devel_group}
}

init_base_devel(){
	if ${udev_root};then
		base_packages=( "$(load_group)" )
	else
		if ${is_multilib};then
			base_packages=('base-devel' 'multilib-devel')
		else
			base_packages=('base-devel')
		fi
	fi
}

chroot_create(){
	msg "Creating chroot for [%s] (%s)..." "${branch}" "${arch}"
	mkdir -p "${work_dir}"
	setarch "${arch}" \
		mkchroot ${mkchroot_args[*]} \
		"${work_dir}/root" \
		${base_packages[*]} || abort
}

chroot_clean(){
	msg "Cleaning chroot for [%s] (%s)..." "${branch}" "${arch}"
	for copy in "${work_dir}"/*; do
		[[ -d ${copy} ]] || continue
		msg2 "Deleting chroot copy %s ..." "$(basename "${copy}")"

		lock 9 "${copy}.lock" "Locking chroot copy '${copy}'"

		if [[ "$(stat -f -c %T "${copy}")" == btrfs ]]; then
			{ type -P btrfs && btrfs subvolume delete "${copy}"; } &>/dev/null
		fi
		rm -rf --one-file-system "${copy}"
	done
	exec 9>&-

	rm -rf --one-file-system "${work_dir}"
}

chroot_update(){
	msg "Updating chroot for [%s] (%s)..." "${branch}" "${arch}"
	chroot-run ${mkchroot_args[*]} \
			"${work_dir}/${OWNER}" \
			pacman -Syu --noconfirm || abort

}

clean_up(){
	msg "Cleaning up ..."
	msg2 "Cleaning [%s]" "${pkg_dir}"
	find ${pkg_dir} -maxdepth 1 -name "*.*" -delete #&> /dev/null
	if [[ -z $SRCDEST ]];then
		msg2 "Cleaning [source files]"
		find $PWD -maxdepth 1 -name '*.?z?' -delete #&> /dev/null
	fi
}

sign_pkg(){
	su ${OWNER} -c "signfile ${pkg_dir}/$1"
}

post_build(){
	local _arch=${arch}
	source PKGBUILD
	local ext='pkg.tar.xz' pinfo loglist=() lname
	if [[ ${arch} == "any" ]]; then
		pinfo=${pkgver}-${pkgrel}-any
	else
		pinfo=${pkgver}-${pkgrel}-${_arch}
	fi
	if [[ -n $PKGDEST ]];then
		if [[ -n ${pkgbase} ]];then
			for p in ${pkgname[@]};do
				mv $PKGDEST/${p}-${pinfo}.${ext} ${pkg_dir}/
				${sign} && sign_pkg ${p}-${pinfo}.${ext}
				loglist+=("*$p*.log")
				lname=${pkgbase}
			done
		else
			mv $PKGDEST/${pkgname}-${pinfo}.${ext} ${pkg_dir}/
			${sign} && sign_pkg ${pkgname}-${pinfo}.${ext}
			loglist+=("*${pkgname}*.log")
			lname=${pkgname}
		fi
	else
		mv *.${ext} ${pkg_dir}
		${sign} && sign_pkg ${pkgname}-${pinfo}.${ext}
		loglist+=("*${pkgname}*.log")
		lname=${pkgname}
	fi
	chown -R "${OWNER}:users" "${pkg_dir}"
	if [[ -z $LOGDEST ]];then
		tar -cJf ${lname}-${pinfo}.log.tar.xz ${loglist[@]}
		find . -maxdepth 1 -name '*.log' -delete #&> /dev/null
	fi
	arch=$_arch
}

chroot_init(){
	local timer=$(get_timer)
	if ${clean_first}; then
		chroot_clean
		chroot_create
	elif [[ ! -d "${work_dir}" ]]; then
		chroot_create
	else
		chroot_update
	fi
	show_elapsed_time "${FUNCNAME}" "${timer}"
}

build_pkg(){
	setarch "${arch}" \
		mkchrootpkg ${mkchrootpkg_args[*]}
}

make_pkg(){
	check_build "$1"
	msg "Start building [%s]" "$1"
	cd $1
		build_pkg || die
		post_build
	cd ..
	msg "Finished building [%s]" "$1"
	show_elapsed_time "${FUNCNAME}" "${timer_start}"
}

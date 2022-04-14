function webseed() {
	# list of mirrors that host our files
	unset text
	# Hardcoded to EU mirrors since
	local CCODE=$(curl -s redirect.armbian.com/geoip | jq '.continent.code' -r)
	WEBSEED=($(curl -s https://redirect.armbian.com/mirrors | jq -r '.'${CCODE}' | .[] | values'))
	# aria2 simply split chunks based on sources count not depending on download speed
	# when selecting china mirrors, use only China mirror, others are very slow there
	if [[ $DOWNLOAD_MIRROR == china ]]; then
		WEBSEED=(https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/)
	elif [[ $DOWNLOAD_MIRROR == bfsu ]]; then
		WEBSEED=(https://mirrors.bfsu.edu.cn/armbian-releases/)
	fi
	for toolchain in "${WEBSEED[@]}"; do
		text="${text} ${toolchain}${1}"
	done
	text="${text:1}"
	echo "${text}"
}

# Terrible idea, this runs download_and_verify_internal() with error handling disabled.
function download_and_verify() {
	download_and_verify_internal "${@}" || true
}

function download_and_verify_internal() {
	local remotedir=$1
	local filename=$2
	local localdir=$SRC/cache/${remotedir//_/}
	local dirname=${filename//.tar.xz/}
	[[ -z $DISABLE_IPV6 ]] && DISABLE_IPV6="true"

	local server=${ARMBIAN_MIRROR}
	if [[ $DOWNLOAD_MIRROR == china ]]; then
		server="https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/"
	elif [[ $DOWNLOAD_MIRROR == bfsu ]]; then
		server="https://mirrors.bfsu.edu.cn/armbian-releases/"
	fi

	if [[ "x${server}x" == "xx" ]]; then
		display_alert "ARMBIAN_MIRROR is not set, nor valid DOWNLOAD_MIRROR" "not downloading '${filename}'" "debug"
		return 0
	fi

	if [[ -f ${localdir}/${dirname}/.download-complete ]]; then
		return 0
	fi

	# switch to china mirror if US timeouts
	timeout 10 curl --head --fail --silent "${server}${remotedir}/${filename}"
	if [[ $? -ne 7 && $? -ne 22 && $? -ne 0 ]]; then
		display_alert "Timeout from $server" "retrying" "info"
		server="https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/"

		# switch to another china mirror if tuna timeouts
		timeout 10 curl --head --fail --silent ${server}${remotedir}/${filename}
		if [[ $? -ne 7 && $? -ne 22 && $? -ne 0 ]]; then
			display_alert "Timeout from $server" "retrying" "info"
			server="https://mirrors.bfsu.edu.cn/armbian-releases/"
		fi
	fi

	# check if file exists on remote server before running aria2 downloader
	[[ ! $(timeout 10 curl --head --fail --silent ${server}${remotedir}/${filename}) ]] && return

	cd "${localdir}" || exit

	# use local control file
	if [[ -f "${SRC}"/config/torrents/${filename}.asc ]]; then
		local torrent="${SRC}"/config/torrents/${filename}.torrent
		ln -sf "${SRC}/config/torrents/${filename}.asc" "${localdir}/${filename}.asc"
	elif [[ ! $(timeout 10 curl --head --fail --silent "${server}${remotedir}/${filename}.asc") ]]; then
		return
	else
		# download control file
		local torrent=${server}$remotedir/${filename}.torrent
		run_host_command_logged aria2c --download-result=hide --disable-ipv6=${DISABLE_IPV6} --summary-interval=0 --console-log-level=error --auto-file-renaming=false \
			--continue=false --allow-overwrite=true --dir="${localdir}" ${server}${remotedir}/${filename}.asc $(webseed "$remotedir/${filename}.asc") -o "${filename}.asc"
		[[ $? -ne 0 ]] && display_alert "Failed to download control file" "" "wrn"
	fi

	# download torrent first
	if [[ ${USE_TORRENT} == "yes" ]]; then
		display_alert "downloading using torrent network" "$filename"
		local ariatorrent="--summary-interval=0 --auto-save-interval=0 --seed-time=0 --bt-stop-timeout=120 --console-log-level=error \
		--allow-overwrite=true --download-result=hide --rpc-save-upload-metadata=false --auto-file-renaming=false \
		--file-allocation=trunc --continue=true ${torrent} \
		--dht-file-path=${SRC}/cache/.aria2/dht.dat --disable-ipv6=${DISABLE_IPV6} --stderr --follow-torrent=mem --dir=$localdir"

		# exception. It throws error if dht.dat file does not exists. Error suppress needed only at first download.
		if [[ -f "${SRC}"/cache/.aria2/dht.dat ]]; then
			# shellcheck disable=SC2086
			run_host_command_logged aria2c ${ariatorrent}
		else
			# shellcheck disable=SC2035
			run_host_command_logged aria2c ${ariatorrent}
		fi
		# mark complete
		touch "${localdir}/${filename}.complete"
	fi

	# direct download if torrent fails
	if [[ ! -f "${localdir}/${filename}.complete" ]]; then
		if [[ ! $(timeout 10 curl --head --fail --silent ${server}${remotedir}/${filename} 2>&1 > /dev/null) ]]; then
			display_alert "downloading from $(echo $server | cut -d'/' -f3 | cut -d':' -f1) using http(s) network" "$filename"
			run_host_command_logged aria2c --download-result=hide --rpc-save-upload-metadata=false --console-log-level=error \
				--dht-file-path="${SRC}"/cache/.aria2/dht.dat --disable-ipv6=${DISABLE_IPV6} --summary-interval=0 --auto-file-renaming=false --dir="${localdir}" ${server}${remotedir}/${filename} $(webseed "${remotedir}/${filename}") -o "${filename}"
			# mark complete
			[[ $? -eq 0 ]] && touch "${localdir}/${filename}.complete" && echo ""

		fi
	fi

	if [[ -f ${localdir}/${filename}.asc ]]; then

		if grep -q 'BEGIN PGP SIGNATURE' "${localdir}/${filename}.asc"; then

			if [[ ! -d "${SRC}"/cache/.gpg ]]; then
				mkdir -p "${SRC}"/cache/.gpg
				chmod 700 "${SRC}"/cache/.gpg
				touch "${SRC}"/cache/.gpg/gpg.conf
				chmod 600 "${SRC}"/cache/.gpg/gpg.conf
			fi

			# Verify archives with Linaro and Armbian GPG keys

			if [ x"" != x"${http_proxy}" ]; then
				(gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning --list-keys 8F427EAF || gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning \
					--keyserver hkp://keyserver.ubuntu.com:80 --keyserver-options http-proxy="${http_proxy}" \
					--recv-keys 8F427EAF)

				(gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning --list-keys 9F0E78D5 || gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning \
					--keyserver hkp://keyserver.ubuntu.com:80 --keyserver-options http-proxy="${http_proxy}" \
					--recv-keys 9F0E78D5)
			else
				(gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning --list-keys 8F427EAF || gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning \
					--keyserver hkp://keyserver.ubuntu.com:80 \
					--recv-keys 8F427EAF)

				(gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning --list-keys 9F0E78D5 || gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning \
					--keyserver hkp://keyserver.ubuntu.com:80 \
					--recv-keys 9F0E78D5)
			fi

			gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning --verify --trust-model always -q "${localdir}/${filename}.asc"
			[[ ${PIPESTATUS[0]} -eq 0 ]] && verified=true && display_alert "Verified" "PGP" "info"
		else
			md5sum -c --status "${localdir}/${filename}.asc" && verified=true && display_alert "Verified" "MD5" "info"
		fi

		if [[ $verified == true ]]; then
			if [[ "${filename:(-6)}" == "tar.xz" ]]; then
				display_alert "decompressing"
				pv -p -b -r -c -N "$(logging_echo_prefix_for_pv "decompress") ${filename}" "${filename}" |
					xz -dc |
					tar xp --xattrs --no-same-owner --overwrite &&
					touch "${localdir}/${dirname}/.download-complete"
			fi
		else
			exit_with_error "verification failed"
		fi
	fi
}

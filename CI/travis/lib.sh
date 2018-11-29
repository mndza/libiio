#!/bin/sh -xe

export TRAVIS_API_URL="https://api.travis-ci.org"

pipeline_branch() {
	local branch=$1

	[ -n "$branch" ] || return 1

	# master is a always a pipeline branch
	[ "$branch" = "master" ] && return 0

	# Turn off tracing for a while ; log can fill up here
	set +x
	# Check if branch name is 20XX_RY where:
	#   XX - 14 to 99 /* wooh, that's a lot of years */
	#   Y  - 1 to 9   /* wooh, that's a lot of releases per year */
	for year in $(seq 2014 2099) ; do
		for rel_num in $(seq 1 9) ; do
			[ "$branch" = "${year}_R${rel_num}" ] && \
				return 0
		done
	done
	set -x

	return 1
}

should_trigger_next_builds() {
	local branch="$1"

	[ -z "${COVERITY_SCAN_PROJECT_NAME}"] || return 1

	# These Travis-CI vars have to be non-empty
	[ -n "$TRAVIS_PULL_REQUEST" ] || return 1
	[ -n "$branch" ] || return 1
	set +x
	[ -n "$TRAVIS_API_TOKEN" ] || return 1
	set -x

	# Has to be a non-pull-request
	[ "$TRAVIS_PULL_REQUEST" = "false" ] || return 1

	pipeline_branch "$branch" || return 1

	if [ -f CI/travis/jobs_running_cnt.py ] ; then
		local python_script=CI/travis/jobs_running_cnt.py
	elif [ -f build/jobs_running_cnt.py ] ; then
		local python_script=build/jobs_running_cnt.py
	else
		echo "Could not find 'jobs_running_cnt.py'"
		return 1
	fi

	local jobs_cnt=$(python $python_script)

	# Trigger next job if we are the last job running
	[ "$jobs_cnt" = "1" ]
}

trigger_build() {
	local repo_slug="$1"
	local branch="$2"

	[ -n "$repo_slug" ] || return 1
	[ -n "$branch" ] || return 1

	local body="{
		\"request\": {
			\"branch\":\"$branch\"
		}
	}"

	# Turn off tracing here (shortly)
	set +x
	curl -s -X POST \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		-H "Travis-API-Version: 3" \
		-H "Authorization: token $TRAVIS_API_TOKEN" \
		-d "$body" \
		https://api.travis-ci.org/repo/$repo_slug/requests
	set -x
}

trigger_adi_build() {
	local adi_repo="$1"
	local branch="$2"

	[ -n "$adi_repo" ] || return 1
	trigger_build "analogdevicesinc%2F$adi_repo" "$branch"
}

get_ldist() {
	case "$(uname)" in
	Linux*)
		if [ ! -f /etc/os-release ] ; then
			if [ -f /etc/centos-release ] ; then
				echo "centos-$(sed -e 's/CentOS release //' -e 's/(.*)$//' \
					-e 's/ //g' /etc/centos-release)-$(uname -m)"
				return 0
			fi
			ls /etc/*elease
			[ -z "${OSTYPE}" ] || {
				echo "${OSTYPE}-unknown"
				return 0
			}
			echo "linux-unknown"
			return 0
		fi
		. /etc/os-release
		if ! command dpkg --version >/dev/null 2>&1 ; then
			echo $ID-$VERSION_ID-$(uname -m)
		else
			echo $ID-$VERSION_ID-$(dpkg --print-architecture)
		fi
		;;
	Darwin*)
		echo "darwin-$(sw_vers -productVersion)"
		;;
	*)
		echo "$(uname)-unknown"
		;;
	esac
	return 0
}

__brew_install_or_upgrade() {
	brew install $1 || \
		brew upgrade $1 || \
		brew ls --version $1
}

brew_install_or_upgrade() {
	while [ -n "$1" ] ; do
		__brew_install_or_upgrade "$1" || return 1
		shift
	done
}

upload_file_to_swdownloads() {
	if [ "$#" -ne 3 ] ; then
		echo "skipping deployment of something"
		echo "send called with $@"
		return 1
	fi

	if [ "x$1" = "x" ] ; then
		echo no file to send
		return 1
	fi

	if [ ! -r "$1" ] ; then
		echo "file $1 is not readable"
		ls -l $1
		return 1
	fi

	if [ -n "$TRAVIS_PULL_REQUEST_BRANCH" ] ; then
		local branch=$TRAVIS_PULL_REQUEST_BRANCH
	else
		local branch=$TRAVIS_BRANCH
	fi

	local FROM=$1
	local FNAME=$2
	local EXT=$3

	local TO=${branch}_${FNAME}
	local LATE=${branch}_latest_libiio${LDIST}${EXT}
	local GLOB=${DEPLOY_TO}/${branch}_libiio-*

	if curl -m 10 -s -I -f -o /dev/null http://swdownloads.analog.com/cse/travis_builds/${TO} ; then
		local RM_TO="rm ${TO}"
	fi

	if curl -m 10 -s -I -f -o /dev/null http://swdownloads.analog.com/cse/travis_builds/${LATE} ; then
		local RM_LATE="rm ${LATE}"
	fi

	echo attemting to deploy $FROM to $TO
	echo and ${branch}_libiio${LDIST}${EXT}
	ssh -V

	sftp ${EXTRA_SSH} ${SSHUSER}@${SSHHOST} <<-EOF
		cd ${DEPLOY_TO}

		${RM_TO}
		put ${FROM} ${TO}
		ls -l ${TO}

		${RM_LATE}
		symlink ${TO} ${LATE}"
		ls -l ${LATE}
		bye
	EOF

	# limit things to a few files, so things don't grow forever
	if [ "$3" = ".deb" ] ; then
		for files in $(ssh ${EXTRA_SSH} ${SSHUSER}@${SSHHOST} \
			"ls -lt ${GLOB}" | tail -n +100 | awk '{print $NF}')
		do
			ssh ${EXTRA_SSH} ${SSHUSER}@${SSHHOST} \
				"rm ${DEPLOY_TO}/${files}"
		done
	fi
}

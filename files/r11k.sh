#!/bin/bash
## File managed by puppet
#  * module: r11k
#  * file: r11k.sh

set -o errexit # exit on command failure
set -o pipefail # pipes fail when any command fails, not just the last one
set -o nounset # exit on use of undeclared var
#set -o xtrace

DEFAULT_REPO="."
DEFAULT_BASEDIR="environments"
DEFAULT_HOOKSDIR="/etc/r11k/hooks.d"

LOCK="fail"

function _help() {
	cat <<EOHELP
USAGE: $0 [options] [repo]

ARGUMENTS:

    [repo]          Clone of the git repo to map in the basedir.
                    Defaults to \`${DEFAULT_REPO}\`

OPTIONS:

    -b,--basedir    Target base directory.
                    Defaults: \`${DEFAULT_BASEDIR}\`
    -c,--cachedir   Directory to use for caching the git repositories
                    (Including the found submodules).
                    Defaults to a subfolder \`.cache\` in the basedir.
    -k,--hooksdir   Directory with hooks to run after the deploy was executed.
                    Default: \`${DEFAULT_HOOKSDIR}\`
    -i,--include    Branch or regex of branches to map. You can repeat this
                    option to include multiple branches/filters or provide
                    a list separated by colon \`:\`.  Defaults to
                    all found branches in the repository.
    -h,--help       Display this message and exit.
    -w,--no-wait    Don't wait for another r11k run to finish, but fail
                    immediately if another run is detected.

ENVIRONMENT:

    R11K_BASEDIR    Sets the default basedir to use.
    R11K_CACHEDIR   Sets the default cache dir to use.
    R11K_HOOKSDIR   Sets the default hooks dir to use.
    R11K_INCLUDES   A colon separated list with branches/filters to use.

EOHELP
}

## getopt parsing
if `getopt -T >/dev/null 2>&1`; [ $? = 4 ]; then
  true # Enhanced getopt.
else
  echo "Could not find an enhanced \`getopt\`. You have $(getopt -V)"
  exit 69 # EX_UNABAILABLE
fi

## No options = show help + exit EX_USAGE
if GETOPT_TEMP="$( getopt --shell bash --name "$0" \
	-o b:c:k:i:hw \
	-l basedir:,cachedir:,hooksdir:,include:,help,no-wait \
	-- "$@" )"; then
	eval set -- "${GETOPT_TEMP}"
else
	exit 64
fi;

declare -a CMD_INCLUDES=()
while [ $# -gt 0 ]; do
	case "${1}" in
		-b|--basedir)   R11K_BASEDIR="${2}"; shift 2;;
		-c|--cachedir)  R11K_CACHEDIR="${2}"; shift 2;;
		-k|--hooksdir)  R11K_HOOKSDIR="${2}"; shift 2;;
		-i|--include)   IFS=: read -ra NEW_INCLUDES <<<"${2}"
		                CMD_INCLUDES+=("${NEW_INCLUDES[@]}");
		                shift 2;;
		-h|--help)      _help; exit 0;;
		-w|--no-wait)   LOCK="wait"; shift;;
		--)             shift; break;;
		*)              break;;
	esac
done

REPO="${R11K_REPO-${DEFAULT_REPO}}"
BASEDIR="${R11K_BASEDIR-${DEFAULT_BASEDIR}}"
DEFAULT_CACHEDIR="${BASEDIR}/.cache"
CACHEDIR="${R11K_CACHEDIR-${DEFAULT_CACHEDIR}}"
HOOKSDIR="${R11K_HOOKSDIR-${DEFAULT_HOOKSDIR}}"
INCLUDES=("${CMD_INCLUDES[@]:-${R11K_INCLUDES[@]:-}}")

if [ $# -gt 0 ]; then
	REPO="${1}"
	shift
fi

if [ $# -gt 0 ]; then
	echo "Unknown argument(s) left; aborting: $@" >&2
	exit 64
fi

exec 3>&1 # So we can output to stdout from within backticks

function ensure_directory {
	while [ ! -d "$1" ]; do
		if [ -e "$1" -a ! -d "$1" ]; then
			echo "\`$1\` already exists but is not a directory"
			exit 65 # EX_DATAERR
		elif [ ! -e "$1" ]; then
			# Possible race condition here, hence the `||true` and the while-loop
			mkdir -p "$1" || true
		fi
	done
}

function escape_repo {
	echo -n "$1" | perl -pe 's@([^a-zA-Z0-9-])@sprintf "_%02x", ord($1)@ge;'
}

function git_mirror {
	local repo="$1"
	local erepo="$( escape_repo "$repo" )"
	if [ ! -d "$CACHEDIR/$erepo" ]; then
		if ! git clone --mirror "$repo" "$CACHEDIR/$erepo"; then
			return 1
		fi
	fi
	echo "$CACHEDIR/$erepo"
	touch "$SCRATCH/refreshed"
	if ! grep -q "$erepo" "$SCRATCH/refreshed"; then
		echo "Updating $repo" >&3
		(
			cd "$CACHEDIR/$erepo"
			if ! git remote update --prune >/dev/null; then
				return 1
			fi
		)
		echo "$erepo" >> "$SCRATCH/refreshed"
	fi
}

# We need to acquire a lock as soon as possible, but we need to create our
# $BASEDIR first.

ensure_directory "$BASEDIR"

LOCKFILE="${BASEDIR}/.lock"
if ( set -o noclobber; echo "$$" > "$LOCKFILE") 2> /dev/null; then
	SCRATCH="$( mktemp -d 2>/dev/null || mktemp -d -t 'r11k' )"
	function cleanup {
		rm -rf "$SCRATCH"
		rm "$LOCKFILE"
	}
	trap cleanup EXIT
else
	echo "Could not create \`${LOCKFILE}\`. Not running."
	exit 75 # TEMPERR
fi

ensure_directory "$CACHEDIR"

CACHEDIR="$( cd "$CACHEDIR"; pwd )" # make absolute path

MASTER_GIT_DIR="$( git_mirror "$REPO" )"

if [ -t 1 ]; then
	FONT_GREEN="$(echo -e "\x1b[32m")"
	FONT_GREEN_BOLD="$(echo -e "\x1b[32;1m")"
	FONT_RED="$(echo -e "\x1b[31m")"
	FONT_NORMAL="$(echo -e "\x1b[39;22;49m")"
else
	FONT_GREEN=""
	FONT_GREEN_BOLD=""
	FONT_RED=""
	FONT_NORMAL=""
fi

function do_submodules() {
	local branch="$1"
	local url lmirror mod
	git submodule init
	git submodule sync >/dev/null
	git submodule | awk '{print $2}' | while read mod; do
		echo "${FONT_GREEN}Checking out submodule ${FONT_NORMAL}${FONT_GREEN_BOLD}${branch}${FONT_NORMAL}${FONT_GREEN}/${mod}${FONT_NORMAL}"

		url="$( git config --get "submodule.${mod}.url" )"
		lmirror="$( git_mirror "${url}" )"
		if [ $? -ne 0 ]; then
			return 1
		fi

		git submodule update --reference "${lmirror}" "${mod}"
		## TODO: Recursive checkout.
		#
		# 	cd "${mod}"
		#	do_submodules # recurse down
		#)
	done
}
function translate_branch_to_env() {
	echo -n "$1" | perl -pe 's@/@__@g;s@([^a-zA-Z0-9_-])@sprintf "_%02x", ord($1)@ge;'
}

function do_submodules_for_branch() {
	local branch="$1"
	local branch_envname="$(translate_branch_to_env "$branch")"
	local new_branch='false'
	echo "$branch_envname" >> "$SCRATCH/branches"
	echo "${FONT_GREEN_BOLD}Checking out branch ${branch} into ${branch_envname}${FONT_NORMAL}"

	# `git worktree` is not usable with submodules: the submodule URL is saved
	# in the $GIT_COMMON_DIR/config, which is common for all workdir's (git
	# v2.5.0)

	if [ ! -e "$BASEDIR/$branch_envname/.git" ]; then
		# Not a git repo, remove it, so it will be created below
		rm -rf "$BASEDIR/$branch_envname"
	fi
	if [ ! -e "$BASEDIR/$branch_envname" ]; then
		git clone --reference "$MASTER_GIT_DIR" --shared \
			-b "$branch" "$MASTER_GIT_DIR" "$BASEDIR/$branch_envname"
		let CHANGE_COUNTER+=1
		new_branch='true'
	fi
	(
		cd "${BASEDIR}/${branch_envname}"
		git remote set-url origin "${MASTER_GIT_DIR}"
		git remote update
		if git status -uno | grep -q -i 'Your branch is up-to-date' && [[ ${new_branch} == 'false' ]]
		then
			echo "${FONT_GREEN}Branch has no changes. ${FONT_NORMAL}${FONT_GREEN_BOLD}${branch}${FONT_NORMAL}"
		else
			echo "${FONT_GREEN}Branch is new or has changes! Updating. ${FONT_NORMAL}${FONT_GREEN_BOLD}${branch}${FONT_NORMAL}"
			git fetch origin "$branch"
			git reset --hard "origin/$branch"
			git clean -ffdx
			if ! do_submodules $branch; then
				echo "${FONT_RED}Could not check out branch ${branch}, removing...${FONT_NORMAL}"
				cd "${BASEDIR}"
				rm -rf "${branch_envname}"
			fi
		fi
	)
}

function collect_branches() {
	local includes
	local tmpfilter="${SCRATCH}/filter_branches.txt"
	if [ ${#INCLUDES} -eq 0 ]; then
		GIT_DIR="$MASTER_GIT_DIR" git show-ref --heads | sed 's%.\{40\} refs/heads/%%'
	else
		for include in "${INCLUDES[@]}"; do
			GIT_DIR="$MASTER_GIT_DIR" git show-ref --heads | sed 's%.\{40\} refs/heads/%%' | \
				{ grep -e "^${include}\$" || true; } >> "$tmpfilter"
		done
		cat "${tmpfilter}" | sort -u
	fi
}

BRANCHES=( "$( collect_branches )" );
CHANGE_COUNTER=0

if [ ${#BRANCHES} -eq 0 ]; then
	echo "No branches found to checkout"
	exit 66;
fi;

# Map branches to environments
while read branch; do
	do_submodules_for_branch "$branch"
done <<<"${BRANCHES[@]}"

# Cleanup old environments
while read dir; do
	if ! grep -q "${dir}$" "$SCRATCH/branches"; then
		echo "${FONT_GREEN_BOLD}Removing non-existant branch ${dir}${FONT_NORMAL}"
		rm -rf "$BASEDIR/$dir"
		let CHANGE_COUNTER+=1
	fi
done < <(cd "$BASEDIR"; ls -1)

# if CHANGE_COUNTER > 0, run the all the hooks found in $HOOKSDIR
if [ -d $HOOKSDIR ]; then
  if [ ${CHANGE_COUNTER} -gt 0 ]; then
	for SCRIPT in `ls ${HOOKSDIR}`; do
		# run script
		${HOOKSDIR}/${SCRIPT}
	done
  fi
else
	echo "WARNING: HOOKSDIR ${HOOKSDIR} not found"
fi

# vim: set ts=4 sw=2 tw=0 noet :

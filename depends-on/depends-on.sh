#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Hold pull requests on their "Depends-on:" lines and comment on them when
# their "Notify-when:" lines are met. The forms of a line, the statuses and
# the settings are described in README.md.
#
set -euo pipefail

repo="${DEPENDS_ON_REPOSITORY:?}"
context="${DEPENDS_ON_CONTEXT:-depends-on}"
override_label="${DEPENDS_ON_OVERRIDE_LABEL:-depends-on: override}"
override_role="${DEPENDS_ON_OVERRIDE_ROLE:-maintain}"
notify_label="${DEPENDS_ON_NOTIFY_LABEL:-notify-pending}"
notify_ttl_days="${DEPENDS_ON_NOTIFY_TTL_DAYS:-365}"
git_every_hours="${DEPENDS_ON_GIT_EVERY_HOURS:-6}"
git_max_fetches="${DEPENDS_ON_GIT_MAX_FETCHES:-10}"
git_fetch_timeout="${DEPENDS_ON_GIT_FETCH_TIMEOUT:-300}"
max_lines="${DEPENDS_ON_MAX_LINES:-20}"
# These go into shell arithmetic, which would run anything but a number.
for one_setting in notify_ttl_days git_every_hours git_max_fetches git_fetch_timeout max_lines; do
	if [[ ! "${!one_setting}" =~ ^[0-9]+$ ]]; then
		echo "${one_setting} must be a number, got '${!one_setting}'" >&2
		exit 1
	fi
done
if ((git_every_hours == 0)); then
	echo "git_every_hours must be at least 1" >&2
	exit 1
fi
run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Result of check_condition: ok, wait, bad, or skip (a git fetch not due in
# this run), a short reason, and for comments a link to the commit found.
dep_state="" dep_reason="" dep_link=""

# Commit page per host: {repo} is the URL path without ".git", {path} the
# path as given, {sha} the full commit. DEPENDS_ON_COMMIT_LINKS adds or
# overrides lines of the same form.
declare -A commit_links=()
while read -r one_host one_template; do
	[[ -n "${one_host}" && -n "${one_template}" ]] && commit_links[${one_host}]="${one_template}"
done <<- LINKS
	github.com https://github.com/{repo}/commit/{sha}
	gitlab.com https://gitlab.com/{repo}/-/commit/{sha}
	source.denx.de https://source.denx.de/{repo}/-/commit/{sha}
	git.u-boot-project.org https://git.u-boot-project.org/{repo}/-/commit/{sha}
	gitlab.freedesktop.org https://gitlab.freedesktop.org/{repo}/-/commit/{sha}
	salsa.debian.org https://salsa.debian.org/{repo}/-/commit/{sha}
	codeberg.org https://codeberg.org/{repo}/commit/{sha}
	git.sr.ht https://git.sr.ht/{repo}/commit/{sha}
	git.kernel.org https://git.kernel.org/{path}/commit/?id={sha}
	git.openwrt.org https://git.openwrt.org/{repo}/commit/?id={sha}
	${DEPENDS_ON_COMMIT_LINKS:-}
LINKS

# The body is anyone's text and the token can write: words from it reach git
# and the API only in these shapes, never as an option.
ref_pattern='^[A-Za-z0-9_][A-Za-z0-9_./-]*$'
url_pattern='^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9_./~%+-]*$'

# Fetching other git servers is the expensive part. On an event the user
# waits for the answer; on the schedule it runs every git_every_hours only.
git_due=yes
if [[ "${GITHUB_EVENT_NAME:-}" == "schedule" ]]; then
	git_due=no
	if (($(date -u +%-H) % git_every_hours == 0 && $(date -u +%-M) < 30)); then
		git_due=yes
	fi
fi

# One bare repository per URL, shared by all conditions of a run.
declare -A git_dirs=() git_fetched=()
git_fetches=0
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

# git limited to https: a line cannot name ext::, ssh or file transports.
safe_git_options=(-c protocol.allow=never -c protocol.https.allow=always -c core.sshCommand=false)
function safe_git() {
	git "${safe_git_options[@]}" "$@"
}

function role_rank() {
	case "${1}" in
		admin) echo 5 ;;
		maintain) echo 4 ;;
		write) echo 3 ;;
		triage) echo 2 ;;
		read) echo 1 ;;
		*) echo 0 ;;
	esac
}

# Print the values of the "<keyword>:" lines of a pull request body, one per
# line. We skip lines inside fenced code blocks, so that examples do not count.
# <keyword>
function parse_lines() {
	tr -d '\r' | awk -v k="${1}" '
		/^[[:space:]]*```/ { fenced = !fenced; next }
		fenced { next }
		index(tolower($0), k ":") == 1 || match(tolower($0), "^[[:space:]]+" k ":") {
			sub(/^[^:]*:[[:space:]]*/, "")
			sub(/[[:space:]]+$/, "")
			if (length($0)) print
		}'
}

function line_hash() {
	printf '%s\n' "${1}" | sha1sum | cut -c1-12
}

# Set dep_link to a Markdown link to commit $2 of repository URL $1, or to
# the full commit and the repository when the host has no template.
function set_commit_link() {
	declare url="${1}" sha="${2}" host path template
	[[ "${url}" =~ ^https://([^/:]+)(:[0-9]+)?/(.*)$ ]] || return 0
	host="${BASH_REMATCH[1]}" path="${BASH_REMATCH[3]%/}"
	template="${commit_links[${host}]:-}"
	if [[ -z "${template}" ]]; then
		dep_link="\`${sha}\` in ${url}"
		return 0
	fi
	template="${template//\{repo\}/${path%.git}}"
	template="${template//\{path\}/${path}}"
	dep_link="[${sha:0:12}](${template//\{sha\}/${sha}})"
}

# Print dep_reason for a comment: a short commit at its end becomes the link,
# else the link follows in parentheses.
function linked_reason() {
	if [[ -z "${dep_link}" ]]; then
		echo "${dep_reason}"
	elif [[ "${dep_link}" == "["* && "${dep_reason}" == *" ${dep_link:1:12}" ]]; then
		echo "${dep_reason% *} ${dep_link}"
	else
		echo "${dep_reason} (${dep_link})"
	fi
}

# Is commit $3 contained in ref $4 of GitHub repository $1/$2?
function github_contains() {
	declare status
	status="$(gh api "repos/${1}/${2}/compare/${3}...${4}" --jq '.status' 2> /dev/null)" || return 2
	[[ "${status}" == "ahead" || "${status}" == "identical" ]]
}

# <owner/repo#N | #N | https://github.com/owner/repo/pull/N> [released | in <ref>]
function check_github_pull_request() {
	declare spec="${1}" modifier="${2:-}" in_ref="${3:-}"
	declare owner name number
	if [[ "${spec}" =~ ^#([0-9]+)$ ]]; then
		owner="${repo%%/*}" name="${repo#*/}" number="${BASH_REMATCH[1]}"
	elif [[ "${spec}" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
		owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
	elif [[ "${spec}" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)/?$ ]]; then
		owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
	else
		dep_state=bad dep_reason="cannot parse '${spec}'"
		return
	fi
	declare ref="${owner}/${name}#${number}" info merged merge_sha state
	if ! info="$(gh api "repos/${owner}/${name}/pulls/${number}" --jq '[.merged, .merge_commit_sha, .state] | @tsv' 2> /dev/null)"; then
		dep_state=bad dep_reason="${ref}: cannot read"
		return
	fi
	IFS=$'\t' read -r merged merge_sha state <<< "${info}"
	if [[ "${merged}" != "true" ]]; then
		if [[ "${state}" == "closed" ]]; then
			dep_state=bad dep_reason="${ref}: closed without merge"
		else
			dep_state=wait dep_reason="${ref}: not merged"
		fi
		return
	fi
	case "${modifier}" in
		"")
			dep_state=ok dep_reason="${ref}: merged"
			;;
		released)
			declare tag
			if ! tag="$(gh api "repos/${owner}/${name}/releases/latest" --jq '.tag_name' 2> /dev/null)"; then
				dep_state=wait dep_reason="${ref}: merged, no release yet"
				return
			fi
			if github_contains "${owner}" "${name}" "${merge_sha}" "${tag}"; then
				dep_state=ok dep_reason="${ref}: released in ${tag}"
			elif [[ $? -eq 2 ]]; then
				dep_state=bad dep_reason="${ref}: cannot compare with ${tag}"
			else
				dep_state=wait dep_reason="${ref}: merged, not in ${tag} yet"
			fi
			;;
		in)
			if [[ ! "${in_ref}" =~ ${ref_pattern} ]]; then
				dep_state=bad dep_reason="${ref}: bad ref name"
				return
			fi
			if github_contains "${owner}" "${name}" "${merge_sha}" "${in_ref}"; then
				dep_state=ok dep_reason="${ref}: in ${in_ref}"
			elif [[ $? -eq 2 ]]; then
				dep_state=bad dep_reason="${ref}: cannot compare with ${in_ref}"
			else
				dep_state=wait dep_reason="${ref}: merged, not in ${in_ref} yet"
			fi
			;;
		*)
			dep_state=bad dep_reason="${ref}: unknown '${modifier}'"
			;;
	esac
}

# Resolve ref $2 of $1 to a commit. Sets git_sha: empty if the ref does not
# exist (yet). Returns 1 if the remote does not answer.
function git_resolve() {
	declare listed
	git_sha=""
	listed="$(timeout --kill-after=5 60 git "${safe_git_options[@]}" ls-remote "${1}" "${2}" "${2}^{}" 2> /dev/null)" || return 1
	# A peeled tag names the commit; prefer it over the tag object.
	git_sha="$(awk '$2 ~ /\^\{\}$/ { print $1; exit } !first { first = $1 } END { if (first) print first }' <<< "${listed}" | head -n1)"
}

# One fetch into this run's repository for URL $1, within the time and count
# limits. Logs it for the summary. Returns 0, 1 (failed), 2 (over the number
# of fetches of this run) or 3 (over the time of one fetch).
# <url> <what, for the log> <git fetch arguments>...
function git_fetch_once() {
	declare url="${1}" what="${2}" && shift 2
	if ((git_fetches >= git_max_fetches)); then
		return 2
	fi
	git_fetches=$((git_fetches + 1))
	declare start=${SECONDS} rc=0
	timeout --kill-after=10 "${git_fetch_timeout}" git "${safe_git_options[@]}" -C "${git_dir}" fetch -q --filter=tree:0 "$@" 2> /dev/null || rc=$?
	echo "| ${url} | ${what} | $((SECONDS - start)) s | $( ((rc == 0)) && echo ok || echo "failed (${rc})") |" | tee -a "${work_dir}/fetches" >&2
	if ((rc == 124 || rc == 137)); then
		return 3
	fi
	((rc == 0)) || return 1
}

# Fetch the commits of ref $2 of $1, without trees or files where the server
# can leave them out; with tag $3, only those after the tag where the server
# can cut there, else all of them and the tag. Sets git_dir and git_range,
# the local commits to search. Returns as git_fetch_once.
function git_fetch() {
	declare url="${1}" ref="${2}" after="${3:-}"
	declare key="${url} ${ref} ${after}" mine rc=0
	if [[ -z "${git_dirs[${url}]:-}" ]]; then
		git_dirs[${url}]="${work_dir}/${#git_dirs[@]}"
		git init -q --bare "${git_dirs[${url}]}"
	fi
	git_dir="${git_dirs[${url}]}"
	mine="refs/depends-on/$(printf '%s' "${key}" | sha1sum | cut -c1-12)"
	if [[ -n "${git_fetched[${key}]:-}" ]]; then
		git_range="${git_fetched[${key}]#* }"
		return "${git_fetched[${key}]%% *}"
	fi
	git_range="${mine}"
	if [[ -n "${after}" ]]; then
		git_fetch_once "${url}" "${ref} after ${after}" --shallow-exclude="${after}" "${url}" "+${ref}:${mine}" || rc=$?
		if ((rc == 1)); then
			# If the cut fails, take the whole history and the tag.
			rc=0
			git_fetch_once "${url}" "${ref} and ${after}" "${url}" "+${ref}:${mine}" "+refs/tags/${after}:${mine}-after" || rc=$?
			git_range="${mine}-after..${mine}"
		fi
	else
		git_fetch_once "${url}" "${ref}" "${url}" "+${ref}:${mine}" || rc=$?
	fi
	git_fetched[${key}]="${rc} ${git_range}"
	return "${rc}"
}

# Set dep_state and dep_reason for a git_fetch return code other than 0. A
# fetch cut by a limit holds the pull request: skip would keep an old success.
function fetch_failed() {
	case "${1}" in
		1) dep_state=bad dep_reason="${2}: cannot fetch ${3}" ;;
		2) dep_state=wait dep_reason="${2}: ${3} over the fetch limit of this run" ;;
		*) dep_state=wait dep_reason="${2}: ${3} fetch over ${git_fetch_timeout} s" ;;
	esac
}

# git <url> contains "<text>" in <ref> after <tag>
function check_git_contains() {
	declare url="${1}" text="${2}" container="${3}" after="${4}"
	if [[ "${git_due}" != "yes" ]]; then
		dep_state=skip dep_reason="${url}: ${container} not due in this run"
		return
	fi
	if ! git_resolve "${url}" "${container}"; then
		dep_state=bad dep_reason="${url}: cannot read"
		return
	fi
	if [[ -z "${git_sha}" ]]; then
		dep_state=wait dep_reason="${url}: no ${container} yet"
		return
	fi
	if ! git_resolve "${url}" "refs/tags/${after}"; then
		dep_state=bad dep_reason="${url}: cannot read"
		return
	fi
	if [[ -z "${git_sha}" ]]; then
		dep_state=bad dep_reason="${url}: no tag ${after}"
		return
	fi
	declare rc=0 found
	git_fetch "${url}" "${container}" "${after}" || rc=$?
	if ((rc != 0)); then
		fetch_failed "${rc}" "${url}" "${container}"
		return
	fi
	# A merge can quote the subjects it brings in: prefer the commit itself.
	found="$(git -C "${git_dir}" log --no-merges -F --grep="${text}" --format=%H -1 "${git_range}" 2> /dev/null || true)"
	[[ -n "${found}" ]] || found="$(git -C "${git_dir}" log -F --grep="${text}" --format=%H -1 "${git_range}" 2> /dev/null || true)"
	if [[ -n "${found}" ]]; then
		dep_state=ok dep_reason="${url}: in ${container} as ${found:0:12}"
		set_commit_link "${url}" "${found}"
	else
		dep_state=wait dep_reason="${url}: not in ${container} after ${after}"
	fi
}

# git <url> <ref|sha> [in <ref>]
function check_git() {
	declare url="${1:-}" ref="${2:-}" keyword="${3:-}" container="${4:-}"
	if [[ -z "${url}" || -z "${ref}" || (-n "${keyword}" && ("${keyword}" != "in" || -z "${container}")) ]]; then
		dep_state=bad dep_reason="git: expected 'git <url> <ref> [in <ref>]'"
		return
	fi
	if [[ ! "${url}" =~ ${url_pattern} || ! "${ref}" =~ ${ref_pattern} || (-n "${container}" && ! "${container}" =~ ${ref_pattern}) ]]; then
		dep_state=bad dep_reason="git: only https:// URLs and plain ref names"
		return
	fi
	declare sha
	if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
		sha="${ref}"
	else
		if ! git_resolve "${url}" "${ref}"; then
			dep_state=bad dep_reason="${url}: cannot read"
			return
		fi
		sha="${git_sha}"
		if [[ -z "${sha}" ]]; then
			dep_state=wait dep_reason="${url}: no ${ref} yet"
			return
		fi
	fi
	if [[ -z "${container}" ]]; then
		if [[ "${ref}" == "${sha}" ]]; then
			dep_state=bad dep_reason="${url}: a commit needs 'in <ref>'"
		else
			dep_state=ok dep_reason="${url}: ${ref} exists"
			set_commit_link "${url}" "${sha}"
		fi
		return
	fi
	# GitHub answers through its API, without fetching any history.
	if [[ "${url}" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$ ]]; then
		declare owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]%.git}"
		if github_contains "${owner}" "${name}" "${sha}" "${container}"; then
			dep_state=ok dep_reason="${owner}/${name}: ${ref} in ${container}"
			set_commit_link "${url}" "${sha}"
		elif [[ $? -eq 2 ]]; then
			dep_state=wait dep_reason="${owner}/${name}: cannot compare ${ref} with ${container}"
		else
			dep_state=wait dep_reason="${owner}/${name}: ${ref} not in ${container}"
		fi
		return
	fi
	if [[ "${git_due}" != "yes" ]]; then
		dep_state=skip dep_reason="${url}: ${container} not due in this run"
		return
	fi
	if ! git_resolve "${url}" "${container}"; then
		dep_state=bad dep_reason="${url}: cannot read"
		return
	fi
	if [[ -z "${git_sha}" ]]; then
		dep_state=wait dep_reason="${url}: no ${container} yet"
		return
	fi
	declare rc=0
	git_fetch "${url}" "${container}" || rc=$?
	if ((rc != 0)); then
		fetch_failed "${rc}" "${url}" "${container}"
	elif git -C "${git_dir}" merge-base --is-ancestor "${sha}" "${git_range}" 2> /dev/null; then
		dep_state=ok dep_reason="${url}: ${ref} in ${container}"
		set_commit_link "${url}" "${sha}"
	else
		dep_state=wait dep_reason="${url}: ${ref} not in ${container}"
	fi
}

function check_condition() {
	dep_state="" dep_reason="" dep_link=""
	if [[ "${1}" =~ ^[Gg][Ii][Tt][[:space:]]+([^[:space:]]+)[[:space:]]+contains[[:space:]]+\"([^\"]{1,200})\"[[:space:]]+in[[:space:]]+([^[:space:]]+)[[:space:]]+after[[:space:]]+([^[:space:]]+)$ ]]; then
		declare url="${BASH_REMATCH[1]}" text="${BASH_REMATCH[2]}" container="${BASH_REMATCH[3]}" after="${BASH_REMATCH[4]}"
		if [[ ! "${url}" =~ ${url_pattern} || ! "${container}" =~ ${ref_pattern} || ! "${after}" =~ ${ref_pattern} ]]; then
			dep_state=bad dep_reason="git: only https:// URLs and plain ref names"
			return
		fi
		check_git_contains "${url}" "${text}" "${container}" "${after}"
		return
	fi
	declare -a words
	read -r -a words <<< "${1}"
	if [[ "${words[0],,}" == "git" ]]; then
		check_git "${words[@]:1}"
	else
		check_github_pull_request "${words[0]}" "${words[1]:-}" "${words[2]:-}"
	fi
}

# Print the login that last added the override label, if any.
function override_actor() {
	gh api --paginate "repos/${repo}/issues/${1}/events?per_page=100" 2> /dev/null |
		jq -rs --arg l "${override_label}" '[.[][] | select(.event == "labeled" and .label.name == $l)] | last | .actor.login // empty'
}

# Print one JSON object with the decision for pull request $1. Needs read
# access only. state empty: leave the status alone. comments: texts to post.
# label: add or remove the notify label, or nothing.
function evaluate_pull_request() {
	declare number="${1}" pr sha body labels pr_state merged_at comments
	pr="$(gh api "repos/${repo}/pulls/${number}")"
	sha="$(jq -r '.head.sha' <<< "${pr}")"
	body="$(jq -r '.body // ""' <<< "${pr}")"
	labels="$(jq -r '.labels[].name' <<< "${pr}")"
	pr_state="$(jq -r '.state' <<< "${pr}")"
	merged_at="$(jq -r '.merged_at // ""' <<< "${pr}")"
	comments="$(gh api --paginate "repos/${repo}/issues/${number}/comments?per_page=100" --jq '.[].body' 2> /dev/null || true)"

	declare -a deps notifies new_comments=()
	mapfile -t deps < <(parse_lines "depends-on" <<< "${body}")
	mapfile -t notifies < <(parse_lines "notify-when" <<< "${body}")
	# We watch merged pull requests too: cap their lines as well.
	[[ "${pr_state}" == "open" ]] || notifies=("${notifies[@]:0:max_lines}")

	# Depends-on: a status on open pull requests only.
	declare state="" description="" one
	if [[ "${pr_state}" == "open" ]]; then
		declare -a waiting=() broken=() met=() met_linked=() skipped=()
		if ((${#deps[@]} + ${#notifies[@]} > max_lines)); then
			broken+=("more than ${max_lines} Depends-on and Notify-when lines")
			deps=() notifies=()
		fi
		for one in "${deps[@]}"; do
			check_condition "${one}"
			echo "#${number} Depends-on: ${dep_state}: ${dep_reason}" >&2
			case "${dep_state}" in
				ok)
					met+=("${dep_reason}")
					met_linked+=("$(linked_reason)")
					;;
				wait) waiting+=("${dep_reason}") ;;
				skip) skipped+=("${dep_reason}") ;;
				*) broken+=("${dep_reason}") ;;
			esac
		done
		state=success description="no dependencies"
		if [[ ${#broken[@]} -gt 0 ]]; then
			state=failure description="$(IFS=';' && echo "${broken[*]}")"
		elif [[ ${#waiting[@]} -gt 0 ]]; then
			state=pending description="waiting: $(IFS=';' && echo "${waiting[*]}")"
		elif [[ ${#skipped[@]} -gt 0 ]]; then
			# Only a scheduled run skips, and every change to the lines brings an
			# event run that checks them all: the status it set still stands.
			state="" description="not due: $(IFS=';' && echo "${skipped[*]}")"
		elif [[ ${#met[@]} -gt 0 ]]; then
			description="met: $(IFS=';' && echo "${met[*]}")"
			declare marker
			marker="<!-- depends-on: met $(printf '%s\n' "${deps[@]}" | LC_ALL=C sort | sha1sum | cut -c1-12) -->"
			if ! grep -qF "${marker}" <<< "${comments}"; then
				new_comments+=("$(printf 'All dependencies are met:\n%s\n\n%s' "$(printf -- '- %s\n' "${met_linked[@]}")" "${marker}")")
			fi
		fi
		if [[ -n "${state}" && "${state}" != "success" ]] && grep -qxF "${override_label}" <<< "${labels}"; then
			declare actor role
			actor="$(override_actor "${number}")"
			role="$(gh api "repos/${repo}/collaborators/${actor:-none}/permission" --jq '.role_name' 2> /dev/null || true)"
			if [[ -n "${actor}" && "$(role_rank "${role}")" -ge "$(role_rank "${override_role}")" ]]; then
				state=success description="overridden by @${actor} (${role})"
			else
				description="override label ignored: @${actor:-unknown} is ${role:-not a collaborator}; ${description}"
			fi
		fi
	fi

	# Notify-when: one comment per line, also after the merge.
	declare label="" pending=0 hash expired=no
	if [[ -n "${merged_at}" ]] && (($(date -u +%s) - $(date -u -d "${merged_at}" +%s) > notify_ttl_days * 86400)); then
		expired=yes
	fi
	for one in "${notifies[@]}"; do
		hash="$(line_hash "${one}")"
		grep -qF "<!-- notify-when: ${hash} -->" <<< "${comments}" && continue
		if [[ "${pr_state}" == "closed" && -z "${merged_at}" ]]; then
			continue # closed without merge: nothing to watch for
		fi
		if [[ "${expired}" == "yes" ]]; then
			new_comments+=("$(printf 'Notify-when gave up after %s days:\n- %s\n\n<!-- notify-when: %s -->' "${notify_ttl_days}" "${hash}" "${hash}")")
			continue
		fi
		check_condition "${one}"
		echo "#${number} Notify-when: ${dep_state}: ${dep_reason}" >&2
		case "${dep_state}" in
			ok) new_comments+=("$(printf 'Notify-when met:\n- %s\n\n<!-- notify-when: %s -->' "$(linked_reason)" "${hash}")") ;;
			*) pending=$((pending + 1)) ;;
		esac
	done
	if ((pending > 0)); then
		grep -qxF "${notify_label}" <<< "${labels}" || label=add
	else
		grep -qxF "${notify_label}" <<< "${labels}" && label=remove
	fi

	echo "#${number} ${sha:0:12} ${state:-unchanged}: ${description} notify-pending=${pending} label=${label:-none}" >&2
	echo "| #${number} | ${state:-unchanged} | ${description//|/\\|} | ${pending} |" >> "${summary}"
	printf '%s\0' "${new_comments[@]}" | jq -Rsc --argjson number "${number}" --arg sha "${sha}" \
		--arg state "${state}" --arg description "${description:0:140}" --arg label "${label}" \
		'{number: $number, sha: $sha, state: $state, description: $description, label: $label,
		comments: (split("\u0000") | map(select(length > 0)))}'
}

# Is $1 one of the comments evaluate_pull_request writes: a fixed heading,
# "- " items, a marker of 12 hex digits?
function is_known_comment() {
	[[ ${#1} -le 4000 ]] || return 1
	declare -a lines
	mapfile -t lines <<< "${1}"
	declare last=$((${#lines[@]} - 1)) i
	case "${lines[0]}" in
		"All dependencies are met:")
			[[ "${lines[last]}" =~ ^\<!--\ depends-on:\ met\ [0-9a-f]{12}\ --\>$ ]] || return 1
			;;
		"Notify-when met:" | "Notify-when gave up after "[0-9]*" days:")
			[[ "${lines[last]}" =~ ^\<!--\ notify-when:\ [0-9a-f]{12}\ --\>$ ]] || return 1
			;;
		*)
			return 1
			;;
	esac
	for ((i = 1; i < last; i++)); do
		[[ -z "${lines[i]}" || "${lines[i]}" == "- "* ]] || return 1
	done
}

# Carry out a JSON array of decisions. Needs write access, reads no pull
# request body. The decisions come from the evaluate step and are trusted as
# far as that step is: a forged one can at most set the status of the head
# commit of an open pull request it names, post a comment of a fixed shape,
# and add or remove the notify label.
function apply_decisions() {
	declare item number sha state description label head one
	while IFS= read -r item; do
		number="$(jq -r '.number' <<< "${item}")"
		sha="$(jq -r '.sha' <<< "${item}")"
		state="$(jq -r '.state' <<< "${item}")"
		description="$(jq -r '.description' <<< "${item}")"
		label="$(jq -r '.label' <<< "${item}")"
		if [[ ! "${number}" =~ ^[0-9]+$ || ! "${sha}" =~ ^[0-9a-f]{40}$ || ! "${state}" =~ ^(success|pending|failure|)$ || ! "${label}" =~ ^(add|remove|)$ ]]; then
			echo "Skipping a malformed decision: ${item:0:200}" >&2
			continue
		fi
		if [[ -n "${state}" ]]; then
			head="$(gh api "repos/${repo}/pulls/${number}" --jq 'select(.state == "open") | .head.sha' 2> /dev/null || true)"
			if [[ "${head}" == "${sha}" ]]; then
				gh api -X POST "repos/${repo}/statuses/${sha}" -f state="${state}" -f context="${context}" \
					-f description="${description:0:140}" -f target_url="${run_url}" > /dev/null
			else
				echo "Not setting a status on #${number}: ${sha:0:12} is not the head of an open pull request (now ${head:-none})" >&2
			fi
		fi
		while IFS= read -r -d '' one; do
			if is_known_comment "${one}"; then
				gh api -X POST "repos/${repo}/issues/${number}/comments" -f body="${one}" > /dev/null
			else
				echo "Dropping an unexpected comment for #${number}" >&2
			fi
		done < <(jq -j '.comments[] | ., "\u0000"' <<< "${item}")
		case "${label}" in
			add) gh api -X POST "repos/${repo}/issues/${number}/labels" -f "labels[]=${notify_label}" > /dev/null ;;
			remove) gh api -X DELETE "repos/${repo}/issues/${number}/labels/$(jq -rn --arg l "${notify_label}" '$l|@uri')" > /dev/null 2>&1 || true ;;
		esac
		echo "#${number} ${sha:0:12} ${state:-unchanged} label=${label:-none}"
	done < <(jq -c '.[]' <<< "${1}")
}

function pull_requests_to_check() {
	if [[ -n "${DEPENDS_ON_PULL_REQUESTS:-}" && "${DEPENDS_ON_PULL_REQUESTS}" != "all" ]]; then
		tr ' ,' '\n\n' <<< "${DEPENDS_ON_PULL_REQUESTS}" | awk 'NF'
		return
	fi
	if [[ -z "${DEPENDS_ON_PULL_REQUESTS:-}" && -r "${GITHUB_EVENT_PATH:-}" ]]; then
		declare number action
		number="$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH}")"
		action="$(jq -r '.action // empty' "${GITHUB_EVENT_PATH}")"
		if [[ -n "${number}" ]]; then
			echo "${number}"
			# A closed pull request may be what others wait for: check them all.
			[[ "${action}" == "closed" ]] || return 0
		fi
	fi
	{
		gh api --paginate "repos/${repo}/pulls?state=open&per_page=100" --jq '.[].number'
		# Merged pull requests are watched only while they carry the notify label.
		gh api --paginate "repos/${repo}/issues?state=all&per_page=100&labels=$(jq -rn --arg l "${notify_label}" '$l|@uri')" \
			--jq '.[] | select(.pull_request) | .number'
	} | awk '!seen[$0]++'
}

# Print the decisions for the pull requests to check as a JSON array.
function evaluate() {
	{
		echo "| Pull request | Status | Details | Notify pending |"
		echo "|---|---|---|---|"
	} >> "${summary}"
	declare one_pr
	while read -r one_pr; do
		evaluate_pull_request "${one_pr}"
	done < <(pull_requests_to_check) | jq -sc '.'
	if [[ -s "${work_dir}/fetches" ]]; then
		{
			echo
			echo "| Fetched from | Ref | Commits | Time | Result |"
			echo "|---|---|---|---|---|"
			cat "${work_dir}/fetches"
		} >> "${summary}"
	fi
}

# evaluate: read-only, writes the decisions to the step output 'result'.
# apply: carries out the decisions in DEPENDS_ON_RESULT.
# all: both in one step, with one token.
function main() {
	declare result
	case "${DEPENDS_ON_MODE:-all}" in
		evaluate)
			result="$(evaluate)"
			echo "result=${result}" >> "${GITHUB_OUTPUT:-/dev/null}"
			;;
		apply)
			apply_decisions "${DEPENDS_ON_RESULT:?}"
			;;
		all)
			result="$(evaluate)"
			apply_decisions "${result}"
			;;
		*)
			echo "Unknown mode '${DEPENDS_ON_MODE}'" >&2
			return 1
			;;
	esac
}

# Sourcing defines the functions only, for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main
fi

#!/usr/bin/env bash
set -euo pipefail

######################################
# Color definitions
######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color / reset

######################################
# Utility Functions
######################################

check_rate_limit() {
  local headers="$1"
  local rem reset now wait
  rem=$(grep -Fi 'X-RateLimit-Remaining:' "$headers" | awk '{print $2}' | tr -d '\r' || echo "")
  reset=$(grep -Fi 'X-RateLimit-Reset:' "$headers" | awk '{print $2}' | tr -d '\r' || echo "")
  if [[ -n "$rem" && "$rem" -eq 0 ]]; then
    now=$(date +%s)
    wait=$(( reset - now + 5 ))
    if (( wait > 0 )); then
      echo -e "${YELLOW}⏱ Rate limit reached—sleeping for $wait seconds...${NC}"
      sleep "$wait"
    fi
  fi
}

# Perform a GitHub API GET request with retry/backoff on rate-limited responses
# Change gh_api_get to optionally write headers to a file passed as $2
gh_api_get() {
  local url="$1"
  local out_headers_file="${2:-}"
  local attempt=0 max_attempts=5 backoff=60
  local headers body status

  while (( attempt < max_attempts )); do
    headers=$(mktemp)
    body=$(curl -sS -w "%{http_code}" -D "$headers" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: bash-script" \
      "$url")
    status="${body: -3}"
    body="${body%???}"

    if [[ "$status" == "200" ]]; then
      check_rate_limit "$headers"
      [[ -n "$out_headers_file" ]] && cp "$headers" "$out_headers_file"
      rm -f "$headers"
      printf "%s" "$body"
      return 0
    elif [[ "$status" == "403" || "$status" == "429" ]]; then
      echo -e "${RED}⚠️ Rate-limited (HTTP $status), retrying in $backoff seconds...${NC}"
      rm -f "$headers"
      sleep "$backoff"
      backoff=$(( backoff * 2 ))
      (( attempt++ ))
    else
      echo -e "${RED}GitHub API error: HTTP $status${NC}"
      rm -f "$headers"
      exit 1
    fi
  done

  echo -e "${RED}Exceeded $max_attempts retries—exiting.${NC}"
  exit 1
}

######################################
# Core Functions
######################################

# Fetch all repo names (with gh_api_get), handling pagination
# In fetch_all_repos, capture and read the Link header
fetch_all_repos() {
  local org="$1"
  local page=1 per_page=100 link url tmp_body tmp_headers

  REPOS=()

  while :; do
    echo -e "${CYAN}→ Fetching page $page of repositories for org $org${NC}..."

    url="https://api.github.com/orgs/$org/repos?type=all&per_page=$per_page&page=$page"
    tmp_body=$(mktemp)
    tmp_headers=$(mktemp)

    gh_api_get "$url" "$tmp_headers" > "$tmp_body"

    # collect repo names
    while IFS= read -r repo; do
      [ -n "$repo" ] && REPOS+=( "$repo" )
    done < <(jq -r '.[].name' "$tmp_body")

    # read Link header (headers, not body!)
    link=$(grep -i '^Link:' "$tmp_headers" || true)

    rm -f "$tmp_body" "$tmp_headers"

    [[ "$link" =~ rel=\"next\" ]] || break
    (( page++ ))
  done
}

process_repository() {
  local repo="$1"
  echo
  echo -e "▶︎ Processing repo:$ ${repo}"
  local matches=0

  if [ -d "$repo/.git" ]; then
    echo -e "${CYAN}Pulling latest changes...${NC}"
    git -C "$repo" pull --ff-only &>/dev/null \
      || echo -e "${YELLOW}(pull failed)${NC}"
  else
    echo -e "${CYAN}Cloning repository...${NC}"
    if [ "${USE_SSH:-false}" = true ]; then
      git clone --quiet "git@github.com:$ORG/$repo.git" "$repo" &>/dev/null \
        || { echo -e "${RED}(clone failed)${NC}"; return; }
    else
      git clone --quiet "https://github.com/$ORG/$repo.git" "$repo" &>/dev/null \
        || { echo -e "${RED}(clone failed)${NC}"; return; }
    fi
  fi

  echo -e "${BLUE}Searching for vulnerable versions...${NC}"
  local files
  files=$(find "$repo" -type f \( -name "package-lock.json" -o -name "yarn.lock" -o -name "pnpm-lock.yaml" -o -name "bun.lockb" \) 2>/dev/null)

  if [ -z "$files" ]; then
    echo -e "${YELLOW}No lockfiles found in ${repo}.${NC}"
    echo -e "◀︎ Done with repo: ${repo}"
    return
  fi

  for entry in "${KEYWORDS[@]}"; do
    [ -z "$entry" ] && continue
    pkg="${entry%@*}"
    ver="${entry#*@}"

    # Yarn/pnpm style: single line with @version
    grep -RIn --exclude-dir=".git" -E "${pkg}@[^[:space:]]*${ver}" $files &>/dev/null \
      && { echo -e "${RED}Found ${pkg}@${ver} in $repo${NC}"; matches=1; }

    # NPM package-lock style: name and version on different lines
    if grep -q "\"$pkg\"" $files 2>/dev/null; then
      grep -RInA1 --exclude-dir=".git" -E "\"$pkg\"" $files \
        | grep -B1 -A1 "\"version\": \"$ver\"" &>/dev/null \
        && { echo -e "${RED}Found $pkg version $ver in lockfile in $repo${NC}"; matches=1; }
    fi
  done

  if [ "$matches" -eq 0 ]; then
    echo -e "${GREEN}No matches found in ${repo}.${NC}"
  fi

  echo -e "◀︎ Done with repo: ${repo}"
}

######################################
# Main Entrypoint
######################################

main() {
  if [ $# -lt 2 ]; then
    echo -e "${YELLOW}Usage: $0 <org-name> <keywords-file> [--ssh]${NC}"
    exit 1
  fi

  ORG="$1"
  KEYWORDS_FILE="$2"
  USE_SSH=false
  [ "${3:-}" = "--ssh" ] && USE_SSH=true

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo -e "${RED}Error: GITHUB_TOKEN environment variable not set.${NC}"
    exit 1
  fi
  TOKEN="$GITHUB_TOKEN"

  if [ ! -f "$KEYWORDS_FILE" ]; then
    echo -e "${RED}Error: Keywords file not found: $KEYWORDS_FILE${NC}"
    exit 1
  fi

  # Parse keywords file where each line is like:
  # pkg@ver1,ver2,ver3
  KEYWORDS_RAW=()
  while IFS= read -r line || [ -n "$line" ]; do
    # Trim leading/trailing whitespace
    trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$trimmed" ] && KEYWORDS_RAW+=( "$trimmed" )
  done < "$KEYWORDS_FILE"

  KEYWORDS=()
  for raw in "${KEYWORDS_RAW[@]}"; do
    # Extract the versions part (after the *last* "@")
    versions_part="${raw##*@}"
    pkg_name="${raw%@$versions_part}"
    # Split the comma-separated versions
    IFS=',' read -r -a version_array <<< "$versions_part"
    for ver in "${version_array[@]}"; do
      ver_trim="$(printf '%s' "$ver" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -n "$ver_trim" ] && KEYWORDS+=( "${pkg_name}@${ver_trim}" )
    done
  done

  mkdir -p "./${ORG}_repos"
  cd "./${ORG}_repos" || exit 1

  fetch_all_repos "$ORG"
  echo -e "${GREEN}Fetched ${#REPOS[@]} repositories.${NC}"

  for repo in "${REPOS[@]}"; do
    process_repository "$repo"
  done
}

main "$@"

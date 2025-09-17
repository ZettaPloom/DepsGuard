# DepsGuard

A command-line tool to scan all repositories in a GitHub organization, fetch their lockfiles, and check for specific package versions that might be vulnerable or compromised.

---

## Requirements

Make sure your environment meets the following:

| Requirement                                                                                                                                                                                         | Why it’s needed                                            |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| **Git**                                                                                                                                                                                             | To clone or pull repositories.                             |
| **curl**                                                                                                                                                                                            | To call the GitHub API.                                    |
| **jq**                                                                                                                                                                                              | To parse JSON responses from GitHub.                       |
| **grep**                                                                                                                                                                                            | To search inside lockfiles for matches.                    |
| **awk / sed**                                                                                                                                                                                       | For version / name extraction and regex matching.          |
| **Bash** (version >= 3 preferred)                                                                                                                                                                   | Script uses Bash features, needs `set -euo pipefail`, etc. |
| A **GitHub Personal Access Token** (`GITHUB_TOKEN`) with permissions to read organization repos. If using private repos, the token needs appropriate scopes (e.g. `repo` or organization metadata). |
| A **keywords file** with lines like `@package@1.2.3,1.2.4,...` that list the package name and comma-separated versions to check.                                                                    |

---

## 🚀 Installation

1. Clone this repository:

   ```bash
   git clone https://github.com/<your_username>/<repo_name>.git
   cd <repo_name>
   ```

2. Make the script executable:

   ```bash
   chmod +x search_keywords.sh
   ```

3. Ensure dependencies are installed. On Ubuntu/Debian, for example:

   ```bash
   sudo apt update
   sudo apt install git curl jq grep sed awk
   ```

   On macOS, you may need to install `jq` via Homebrew:

   ```bash
   brew install jq
   ```

---

## 🔧 Setup

1. Export your GitHub token:

   ```bash
   export GITHUB_TOKEN="your_personal_access_token"
   ```

2. Create your `keywords.txt` file with the package/version format, one per line.
   Example:

   ```
   @operato/board@9.0.36,9.0.37,9.0.38
   somepackage@2.1.0,2.2.0
   ```

> Note: This repository contains a keywords file `vulnerable-list.txt` with the compromised/vulnerable repositories from these two articles: [S1ngularity/nx attackers strike again](https://www.aikido.dev/blog/s1ngularity-nx-attackers-strike-again) and [npm debug and chalk packages compromised](https://www.aikido.dev/blog/npm-debug-and-chalk-packages-compromised)

---

## 📦 Usage

Run the script with your organization name and the keywords file:

```bash
./search_keywords.sh <organization> vulnerable-list.txt [--ssh]
```

* `<organization>` — GitHub org to scan.
* `keywords.txt` — file with package/version lines.
* `--ssh` — optional flag to clone via SSH instead of HTTPS.

## ⚠️ Notes & Tips

* Scoped package names (like `@org/pkg`) are supported.
* Version matching is literal: if you list `9.0.36`, the script looks for that version. Wildcards or semver ranges are not supported (unless you modify the regex).
* The script handles pagination when listing organization repos.
* It uses rate-limit retry/backoff logic for GitHub API calls.

---

## 🧪 Troubleshooting

| Problem                                               | Possible Cause                                                              | Solution                                                                             |
| ----------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| No repositories are found                             | Token lacks the right permissions                                           | Ensure the `GITHUB_TOKEN` has access to list org repos (public & private as needed). |
| No matches for a package/version that you know exists | Version mismatch (e.g. the version in lockfile includes caret, tilde, etc.) | Ensure version in keywords file matches exactly or adjust matching logic.            |
| Script fails with “command not found”                 | Missing dependency                                                          | Install the missing tool (`jq`, `grep`, etc.).                                       |

#!/bin/bash
# Push mirror: GitLab (source of truth) -> GitHub (backup).
#
# After cutover (issue #218), GitLab is the source of truth.
# This script pushes main + tags from GitLab to GitHub as a backup mirror.
#
# Runs as root inside the gitlab-runner-admin container. The administrator's SSH
# keys are bind-mounted at /home/administrator/.ssh. GitHub uses id_ed25519.
set -euo pipefail

KEYDIR="/home/administrator/.ssh"
GH_SSH="ssh -i ${KEYDIR}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

cd "$CI_PROJECT_DIR"

# Add github remote if not present (CI checkout won't have it).
git remote get-url github 2>/dev/null \
  || git remote add github "git@github.com:WebSurfinMurf/portainer.git"

echo "Pushing main + tags -> github ..."
GIT_SSH_COMMAND="$GH_SSH" git push github HEAD:refs/heads/main --tags --force

echo "Mirror complete: gitlab/main -> github/main"

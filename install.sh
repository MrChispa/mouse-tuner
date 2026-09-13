#!/usr/bin/env bash
# Mouse Tuner - local install helper.
#
# Validates the source folder, copies it into the user plugin directory
# (never a symlink), and enables it in the right bar section.
#
#   ./install.sh            install and enable
#   ./install.sh uninstall  disable and remove
set -euo pipefail

PLUGIN_ID="io.github.mrchispa.mouse-tuner"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="${HOME}/.config/omarchy/plugins"
DEST_DIR="${PLUGINS_DIR}/${PLUGIN_ID}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [uninstall]

  (no argument)  validate, install and enable Mouse Tuner
  uninstall      disable and remove Mouse Tuner
EOF
}

install_plugin() {
  echo "Validating ${SRC_DIR} ..."
  omarchy plugin validate "${SRC_DIR}"

  echo "Installing into ${DEST_DIR} ..."
  mkdir -p "${PLUGINS_DIR}"

  # Only ever remove the path we own.
  case "$DEST_DIR" in
    "${PLUGINS_DIR}"/*) ;;
    *) echo "error: refusing to remove unexpected path: ${DEST_DIR}" >&2; exit 1 ;;
  esac
  rm -rf "${DEST_DIR}"
  mkdir -p "${DEST_DIR}"

  # Copy the project without .git and without introducing symlinks.
  tar -C "${SRC_DIR}" --exclude='.git' -cf - . | tar -C "${DEST_DIR}" -xf -

  if find "${DEST_DIR}" -type l -print -quit | grep -q .; then
    echo "error: installed plugin contains a symlink; aborting" >&2
    rm -rf "${DEST_DIR}"
    exit 1
  fi

  # The running shell only learns about the new folder after a rescan, and
  # `omarchy plugin enable` refuses ids it has not discovered yet.
  echo "Asking the running shell to rescan plugins ..."
  omarchy-shell -q shell rescanPlugins || true

  echo "Enabling ${PLUGIN_ID} in the right bar section ..."
  omarchy plugin enable "${PLUGIN_ID}" right

  echo
  echo "Installed. If the icon does not appear at once, run:"
  echo "  omarchy-shell shell rescanPlugins"
  echo "or restart the shell with:"
  echo "  omarchy restart shell"
}

uninstall_plugin() {
  echo "Disabling ${PLUGIN_ID} ..."
  omarchy plugin disable "${PLUGIN_ID}" >/dev/null 2>&1 || true
  echo "Removing ${PLUGIN_ID} ..."
  omarchy plugin remove "${PLUGIN_ID}" --yes
  echo "Removed. The managed block in ~/.config/hypr/input.lua was left intact;"
  echo "delete it from the widget or with: ${DEST_DIR}/bin/mouse-tuner.sh reset"
}

case "${1:-}" in
  ""|install|--yes) install_plugin ;;
  uninstall|remove) uninstall_plugin ;;
  -h|--help) usage ;;
  *) echo "unknown option: $1" >&2; usage; exit 1 ;;
esac

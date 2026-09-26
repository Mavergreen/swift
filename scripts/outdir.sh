# platform: host-agnostic
#   usage: . scripts/outdir.sh; refuse_root_outdir <who> <out-dir>
#          Exits 2, naming <who>, when <out-dir> is empty or is / by any name. The staging scripts
#          remove <out-dir>/usr, and 10.9 has no SIP to save /usr.
refuse_root_outdir() {
  # set -u does not catch an EMPTY argument.
  case "$2" in
    ''|/) echo "$1: refusing out-dir '$2'" >&2; exit 2 ;;
  esac
  # Nor does that catch / by another name (//, /., /tmp/.., a symlink's ..). So resolve an existing
  # out-dir both ways: logically, as cd reads it (/tmp/.. is /), and physically, as rm does (/tmp/..
  # is /private). CDPATH could send cd somewhere rm never goes, and this sh keeps a leading // in
  # pwd's answer, so / is any string of nothing but slashes.
  if [ -d "$2" ]; then
    _logical="$(CDPATH='' cd "$2" && pwd -P)"
    _physical="$(CDPATH='' cd -P "$2" && pwd -P)"
    for _r in "$_logical" "$_physical"; do
      case "$_r" in
        *[!/]*) ;;
        *) echo "$1: refusing out-dir '$2' (it is /)" >&2; exit 2 ;;
      esac
    done
  fi
}

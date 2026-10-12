#!/usr/bin/env bash
#
# migrate-from-srv.sh -- import OBS projects/packages from a SOURCE
# installation whose database is broken, using ONLY its raw on-disk source
# tree (the OBS backend's content-addressed source layout), into a TARGET
# instance via the osc client.
#
# Source layout (verified against the OBS 2.10 backend: BSRevision.pm,
# BSSrcrep.pm, BSFileDB.pm):
#
#   $ROOT/projects/<proj>.xml              project metadata (readable XML)
#   $ROOT/projects/<proj>.conf             project-wide build config (optional)
#   $ROOT/projects/<proj>.pkg/_pubkey      project GPG public key (NOT imported
#                                           -- there's no clean osc verb for it
#                                           and it's not needed to re-create
#                                           sources; re-add manually if required)
#   $ROOT/projects/<proj>.pkg/_project.mrev  project meta revision index
#   $ROOT/projects/<proj>.pkg/<pack>.mrev    package meta revision index
#   $ROOT/projects/<proj>.pkg/<pack>.rev     package content revision index
#   $ROOT/projects/<proj>.pkg/<pack>.xml     package metadata (readable XML)
#
# The .rev/.mrev files are plain-text FileDBs: pipe-delimited, %XX-escaped,
# layout rev|vrev|srcmd5|version|time|user|comment|requestid; the LAST line
# is the latest revision. The srcmd5 (field 3) selects the package's source
# tree:
#
#   $ROOT/trees/<pack>/<srcmd5>-MD5SUMS   one "<md5>  <filename>" per line
#   $ROOT/trees/<pack>/<md5>-<filename>   the file content
#
# (shared trees; if the source ran with nosharedtrees the tree lives under
# trees/<proj>/<pack>/ or sources/<pack>/ -- pick with --tree-layout.)
#
# How each package is pushed to the target:
#   1. `osc meta prj -F <_project> <proj>`    create/refresh project meta
#   2. `osc meta pkg -F <_meta> <proj> <pack>` create the package
#   3. `osc co <proj> <pack>`                 check out an empty working copy
#   4. copy the staged source files in
#   5. `osc add <files>` (from the wc)        mark the new files for commit
#   6. `osc ci` (from the wc)                 upload / check the package in
#
# `osc meta prj/pkg/prjconf` read their XML from -F (NOT a positional arg --
# a positional file is "Too many arguments"). `osc ci` (do_commit) is the
# upload verb; it only commits files that are tracked or have been `osc add`ed,
# which is why step 5 exists. Override the verb with --upload-cmd only if your
# osc is older and lacks `ci`.
#
# Linked packages (a tree containing a "_link" file) are checked out with
# their _link + patches and re-uploaded, so they re-create as links. As long
# as all projects are imported under their original names, local links
# resolve on the destination; links that pointed at another instance keep
# doing so and need a reachable interconnect on the target.
#
# Usage:
#   ./migrate-from-srv.sh --source /path/to/srv/obs --target https://obs-api.example.com
#   ./migrate-from-srv.sh --source ... --target ... --list                  # show projects
#   ./migrate-from-srv.sh ... --projects Squid                              # canary: one project
#   ./migrate-from-srv.sh ... --dry-run                                     # print, no changes
#   ./migrate-from-srv.sh ... --upload-cmd ci                               # pin the upload verb
#   ./migrate-from-srv.sh ... --tree-layout shared|per-project|sources
#
# Credentials: prefer ~/.oscrc (osc config-user) over --user/--password so the
# password isn't on the command line / in shell history.
set -euo pipefail

ROOT=""
TARGET=""
OSC_USER=""
OSC_PASSWORD=""
DRY_RUN=0
LIST_ONLY=0
ONLY_PROJECTS=""
TREE_LAYOUT="shared"
UPLOAD_CMD="ci"        # the upload verb (confirmed `osc ci` = do_commit); override only if needed

usage() { sed -n '2,50p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --source)       ROOT="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --user)         OSC_USER="$2"; shift 2 ;;
    --password)     OSC_PASSWORD="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --list)         LIST_ONLY=1; shift ;;
    --projects)     ONLY_PROJECTS="$2"; shift 2 ;;
    --tree-layout)  TREE_LAYOUT="$2"; shift 2 ;;
    --upload-cmd)   UPLOAD_CMD="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$ROOT" ] || { echo "ERROR: --source is required (the backend source dir, e.g. .../srv/obs)" >&2; exit 1; }
[ -d "$ROOT/projects" ] || { echo "ERROR: $ROOT/projects not found -- is --source the backend source dir (contains projects/ and trees/)?" >&2; exit 1; }
case "$TREE_LAYOUT" in shared|per-project|sources) : ;; *) echo "ERROR: --tree-layout must be shared|per-project|sources" >&2; exit 1 ;; esac
[ -n "$TARGET" ] || { [ "$LIST_ONLY" -eq 1 ] || { echo "ERROR: --target is required unless --list" >&2; exit 1; }; }
if [ "$LIST_ONLY" -ne 1 ]; then
  command -v osc  >/dev/null 2>&1 || { echo "ERROR: 'osc' not on PATH" >&2; exit 1; }
  command -v perl >/dev/null 2>&1 || { echo "ERROR: 'perl' not on PATH (needed for FileDB/tree handling)" >&2; exit 1; }
fi

OSC=(osc)
[ -n "$TARGET" ]       && OSC+=(-A "$TARGET")
[ -n "$OSC_USER" ]     && OSC+=(--user "$OSC_USER")
[ -n "$OSC_PASSWORD" ] && OSC+=(--password "$OSC_PASSWORD")

STAGE_ROOT="$(mktemp -d /tmp/obs-migrate.XXXXXX)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
# $STAGE_ROOT/stage holds the tree files we stage for each package; $STAGE_ROOT/wc
# holds the osc working copies (kept separate so `osc co` doesn't collide with
# the staged files).
mkdir -p "$STAGE_ROOT/stage" "$STAGE_ROOT/wc"

# ---- Perl helpers (FileDB parsing, percent-decoding, tree mapping) ----

# Print field $ARGV[1] (0-based) of the LAST FileDB line of $ARGV[0],
# percent-decoded. FileDB lines are f0|f1|f2|... with %XX escapes.
P_FIELD='
sub pct { my ($s)=@_; $s="" unless defined $s; $s=~s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; return $s; }
my ($file,$fld)=@ARGV;
open(my $F,"<",$file) or exit 0;
my @l=<$F>; close $F;
chomp @l; @l=grep{length} @l;
exit 0 unless @l;
my @f=split(/\|/,pop @l,-1);
print pct($f[$fld]);
1;
'

# Given root layout proj pack md5 filename -> print the first existing candidate.
P_MAPPATH='
my ($root,$layout,$proj,$pack,$md5,$fn)=@ARGV;
my @cand;
if($layout eq "shared"){@cand=("$root/trees/$pack/$md5-$fn","$root/trees/$proj/$pack/$md5-$fn","$root/sources/$pack/$md5-$fn");}
elsif($layout eq "per-project"){@cand=("$root/trees/$proj/$pack/$md5-$fn","$root/trees/$pack/$md5-$fn","$root/sources/$pack/$md5-$fn");}
else{@cand=("$root/sources/$pack/$md5-$fn","$root/trees/$pack/$md5-$fn","$root/trees/$proj/$pack/$md5-$fn");}
for my $c (@cand){ print "$c\n" if -e $c; }
1;
'

# Copy every file listed in $md5s ("<md5>  <fn>" per line, skipping the /LINK,
# /LOCAL, /SERVICE markers) into $stage, percent-decoding filenames and
# preserving subpaths.
P_STAGEFILES='
use File::Copy qw(copy);
sub pct { my ($s)=@_; $s="" unless defined $s; $s=~s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; return $s; }
my ($root,$layout,$proj,$pack,$md5s,$stage)=@ARGV;
open(my $F,"<",$md5s) or die "open $md5s: $!";
while(my $line=<$F>){
  chomp $line;
  next unless $line=~/^([0-9a-fA-F]{32})\s+(.*)$/s;
  my ($md5,$fn)=($1,pct($2));
  next if $fn=~/^\/(LINK|LOCAL|SERVICE|LSERVICE|LXSERVICE)$/;
  my @cand;
  if($layout eq "shared"){@cand=("$root/trees/$pack/$md5-$fn","$root/trees/$proj/$pack/$md5-$fn","$root/sources/$pack/$md5-$fn");}
  elsif($layout eq "per-project"){@cand=("$root/trees/$proj/$pack/$md5-$fn","$root/trees/$pack/$md5-$fn","$root/sources/$pack/$md5-$fn");}
  else{@cand=("$root/sources/$pack/$md5-$fn","$root/trees/$pack/$md5-$fn","$root/trees/$proj/$pack/$md5-$fn");}
  my $src; for my $c (@cand){ $src=$c; last if -e $c; }
  next unless defined $src && -e $src;
  my $dst="$stage/$fn";
  if ($fn=~/\//){
    my $dir=$dst; $dir=~s{/[^/]*$}{};
    system("mkdir","-p",$dir)==0 or die "mkdir $dir: $!";
  }
  copy($src,$dst) or die "copy $src -> $dst: $!";
}
1;
'

list_projects() {
  local f
  for f in "$ROOT"/projects/*.xml; do
    [ -e "$f" ] || continue
    basename "$f" .xml
  done | sort
}

if [ "$LIST_ONLY" -eq 1 ]; then
  list_projects
  exit 0
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN: %s\n' "$*"
    return 0
  fi
  "$@"
}

selected() {
  [ -z "$ONLY_PROJECTS" ] && return 0
  local IFS=',' p
  for p in $ONLY_PROJECTS; do
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

# Check in a package working copy: mark every copied-in file for commit with
# `osc add` (a freshly `co`'d package has no tracked files, and `osc ci` only
# commits added/tracked files), then `osc ci` from inside the working copy.
# Files (not dirs) are added so subdirs are committed recursively without
# triggering osc's "archive this directory?" prompt.
upload_package() {
  local wc="$1"
  [ -d "$wc" ] || { echo "      ERROR: working copy not found: $wc" >&2; return 1; }
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN: (cd %s && osc add <files> && osc %s --noservice -m "Automatically imported")\n' "$wc" "$UPLOAD_CMD"
    return 0
  fi
  # Add only the real source files. _meta is osc's store-managed package
  # definition (already set via `meta pkg -F` before the checkout), and the
  # .osc/_osc dirs are osc's own store -- neither is a source file to commit.
  ( cd "$wc" && find . -type f \
      -not -path './.osc/*' -not -path './_osc/*' -not -name '_meta' -print0 \
      | xargs -0 -r "${OSC[@]}" add )
  # -m: supply the commit message non-interactively (ci otherwise opens an
  # editor / prompts); --noservice: skip running local source services at
  # commit time (services may need the full OBS toolchain / network; they
  # re-run on the server at build time anyway).
  ( cd "$wc" && "${OSC[@]}" "$UPLOAD_CMD" --noservice -m "Automatically imported" )
}

import_project() {
  local proj="$1"
  echo
  echo "==> project: $proj"

  local pdir="$STAGE_ROOT/stage/$proj"
  rm -rf "$pdir"; mkdir -p "$pdir"
  [ -f "$ROOT/projects/$proj.xml" ] && cp "$ROOT/projects/$proj.xml" "$pdir/_project"
  [ -f "$ROOT/projects/$proj.conf" ] && cp "$ROOT/projects/$proj.conf" "$pdir/_config"

  # 1) Create/refresh the project. `osc meta prj -F <file> <proj>`: the XML is
  #    read from -F, NOT a positional argument.
  if [ -f "$pdir/_project" ]; then
    run "${OSC[@]}" meta prj -F "$pdir/_project" "$proj"
  else
    echo "    WARN: no project meta XML for $proj -- skipping"
    return 0
  fi

  # 1b) Project-wide build config (osc meta prjconf, also -F-based).
  if [ -f "$pdir/_config" ]; then
    run "${OSC[@]}" meta prjconf -F "$pdir/_config" "$proj"
  fi

  local pkgdir="$ROOT/projects/$proj.pkg"
  [ -d "$pkgdir" ] || return 0

  local f base
  for f in "$pkgdir"/*.mrev; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .mrev)"
    case "$base" in _project|.*) continue ;; esac
    [ -f "$pkgdir/$base.xml" ] || continue

    echo "    package: $base"
    local tdir="$STAGE_ROOT/stage/$proj/$base"
    rm -rf "$tdir"; mkdir -p "$tdir"

    # 2) Package metadata, read straight from <pack>.xml (the current _meta).
    cp "$pkgdir/$base.xml" "$tdir/_meta"

    # 3) Stage the package's file contents: resolve the latest srcmd5 from
    #    <pack>.rev, then copy every file in that tree (sources + _service +
    #    _link + patches, percent-decoded names).
    local srcmd5 md5s
    srcmd5="$(perl -e "$P_FIELD" "$pkgdir/$base.rev" 2)"
    if [ -n "$srcmd5" ] && [ "$srcmd5" != "d41d8cd98f00b204e9800998ecf8427e" ]; then
      md5s="$(perl -e "$P_MAPPATH" "$ROOT" "$TREE_LAYOUT" "$proj" "$base" "$srcmd5" "MD5SUMS" | head -n1 || true)"
      if [ -n "$md5s" ] && [ -f "$md5s" ]; then
        perl -e "$P_STAGEFILES" "$ROOT" "$TREE_LAYOUT" "$proj" "$base" "$md5s" "$tdir"
      else
        echo "      WARN: no MD5SUMS tree for srcmd5=$srcmd5 (empty/linked-remote?)"
      fi
    fi

    # 4) Create the package, check out a working copy, drop the files in, and
    #    check them in. (meta pkg reads the XML from -F.)
    run "${OSC[@]}" meta pkg -F "$tdir/_meta" "$proj" "$base"
    local wc="$STAGE_ROOT/wc/$proj/$base"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'DRY-RUN: osc -A %s co %s %s\n' "$TARGET" "$proj" "$base"
      printf 'DRY-RUN: cp -a staged -> wc, then add + ci\n'
    else
       rm -rf "$STAGE_ROOT/wc/$proj"
       ( cd "$STAGE_ROOT/wc" && "${OSC[@]}" co "$proj" "$base" >/dev/null )
       # Copy the staged source files (sources + _service + _link) into the
       # working copy. The package definition itself already comes from the
       # server via `co` (stored in the wc's .osc dir), so drop the _meta we
       # copied -- leaving it in is an untracked special file that makes
       # `osc ci` fail with "'_meta' is not under version control".
       cp -a "$tdir/." "$wc/"
       rm -f "$wc/_meta"
       upload_package "$wc"
    fi
  done
}

count_projects=0
count_skipped=0
count_failed=0

for proj in $(list_projects); do
  if ! selected "$proj"; then
    echo "skip (not selected): $proj"
    count_skipped=$((count_skipped+1)); continue
  fi
  if [ ! -f "$ROOT/projects/$proj.xml" ]; then
    echo "skip (no project meta): $proj"
    count_skipped=$((count_skipped+1)); continue
  fi
  if import_project "$proj"; then
    count_projects=$((count_projects+1))
  else
    echo "FAILED: $proj" >&2
    count_failed=$((count_failed+1))
  fi
done

echo
echo "==> done. projects imported: $count_projects, skipped: $count_skipped, failed: $count_failed"
[ -n "$TARGET" ] && echo "Verify: osc -A $TARGET ls"

# calibre's content server, with calibre's own metadata backup: the thread
# calibre's program runs to keep each book's metadata.opf current, started
# here on each library the server opens. One process holds the library's
# lock, serves it, renames its book folders and writes its opf files, as in
# calibre's program. Nothing of lulibre's writes anything in the library.
#
# Run it with calibre's own Python, in place of calibre-server, with the
# same arguments after `--`:
#
#   /opt/calibre/calibre-debug -e calibre-server-opf.py -- [calibre-server options] LIBRARY...
#
# It depends on calibre's internals, not on an interface calibre promises:
#   calibre.srv.standalone.Server, .main
#   Server.handler.router.ctx.library_broker  (lmap, get(library_id))
#   Server.serve_forever                      (an attribute, wrapped here)
#   calibre.db.backup.MetadataBackup          (start, stop, join)
# Tested with calibre 9.15. A calibre update may change any of them: the
# server is then started without the thread (the library stays reachable),
# the reason goes to the log, and the status file says so; with
# LULIBRE_OPF_REQUIRED=1 in the environment, the server does not start.
# `make check-offline` checks the whole arrangement against the installed
# calibre (docs/development.md, "calibre's server and the opf files").
#
# Status, for lulibre (lua/lulibre/calibre.lua): a small JSON file at
# $XDG_STATE_HOME/lulibre/calibre-server.json (~/.local/state/...), written
# at start and removed at a clean stop. Not written where it cannot be (a
# hardened unit with a read-only home): nothing else depends on it.
import json
import os
import sys
import time

from calibre.constants import numeric_version
from calibre.srv import standalone

STATUS_DIR = os.path.join(os.environ.get('XDG_STATE_HOME') or os.path.expanduser('~/.local/state'), 'lulibre')
STATUS = os.path.join(STATUS_DIR, 'calibre-server.json')
REQUIRED = os.environ.get('LULIBRE_OPF_REQUIRED') == '1'


def log(*args):
    print('lulibre opf:', *args, file=sys.stderr, flush=True)


def write_status(**fields):
    fields.update(pid=os.getpid(), started=int(time.time()), calibre='.'.join(map(str, numeric_version)))
    try:
        os.makedirs(STATUS_DIR, exist_ok=True)
        tmp = STATUS + '.%d' % os.getpid()
        with open(tmp, 'w') as f:
            json.dump(fields, f)
        os.replace(tmp, STATUS)
    except OSError as err:
        log('no status file (%s): lulibre cannot tell that the opf files are being written' % err)


def remove_status():
    try:
        with open(STATUS) as f:
            if json.load(f).get('pid') == os.getpid():
                os.remove(STATUS)
    except (OSError, ValueError):
        pass


def start_backups(server):
    """calibre's MetadataBackup on each library the server opens; the
    threads, or an exception if calibre's internals are not as expected."""
    from calibre.db.backup import MetadataBackup

    broker = server.handler.router.ctx.library_broker
    threads, libraries = [], []
    for library_id in list(broker.lmap):
        db = broker.get(library_id)
        if db is None:
            continue
        mb = MetadataBackup(db)
        mb.start()
        threads.append(mb)
        libraries.append(broker.lmap[library_id])
    if not threads:
        raise RuntimeError('the server opened no library')
    return threads, libraries


_init = standalone.Server.__init__


def init(self, libraries, opts):
    _init(self, libraries, opts)
    try:
        threads, opened = start_backups(self)
    except Exception as err:  # calibre's internals changed, most likely
        why = '%s: %s' % (type(err).__name__, err)
        log('calibre metadata backup NOT started (%s); calibre %s may have changed what this relies on'
            % (why, '.'.join(map(str, numeric_version))))
        write_status(opf_thread=False, error=why)
        if REQUIRED:
            raise SystemExit('LULIBRE_OPF_REQUIRED is set: not serving without the opf thread')
        return
    log('calibre metadata backup running for %d librar%s' % (len(threads), 'y' if len(threads) == 1 else 'ies'))
    write_status(opf_thread=True, libraries=opened)
    serve = self.serve_forever

    def serve_then_stop(*a, **kw):
        try:
            return serve(*a, **kw)
        finally:
            # the server has stopped (SIGTERM, SIGHUP, Ctrl-C): let each
            # thread finish the file it may be writing, then end
            for mb in threads:
                mb.stop()
            for mb in threads:
                mb.join(10)
            remove_status()

    self.serve_forever = serve_then_stop


if not callable(getattr(standalone, 'main', None)) or not hasattr(standalone, 'Server'):
    # calibre's server is not where it was: this cannot start it at all
    raise SystemExit('lulibre opf: calibre %s has no calibre.srv.standalone.Server and main; run calibre-server '
                     'itself (the unit as calibre documents it) until calibre-server-opf.py is updated'
                     % '.'.join(map(str, numeric_version)))

standalone.Server.__init__ = init
sys.exit(standalone.main(['calibre-server'] + sys.argv[1:]))

# Runs a command and writes its wall, user and system time and peak RSS:
#   python3 -I rusage.py OUTFILE COMMAND [ARG...]
import resource, subprocess, sys, time

t0 = time.monotonic()
rc = subprocess.call(sys.argv[2:])
wall = time.monotonic() - t0
r = resource.getrusage(resource.RUSAGE_CHILDREN)
with open(sys.argv[1], "w") as f:
    f.write(f"wall {wall:.2f} s  user {r.ru_utime:.2f} s  sys {r.ru_stime:.2f} s  peak RSS {r.ru_maxrss / 1024:.0f} MB  exit {rc}\n")

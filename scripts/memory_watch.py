#!/usr/bin/env python3
"""Sample selected processes and descendants without collecting command arguments."""
import argparse
import csv
import datetime
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pid', type=int, nargs='+', help='App PID; optionally local TTS server PID')
    parser.add_argument('--interval', type=float, default=15)
    parser.add_argument('--samples', type=int, default=40, help='Default: 10 minutes')
    args = parser.parse_args()
    if args.interval <= 0 or args.samples <= 0 or any(pid <= 0 for pid in args.pid):
        parser.error('PID, interval and samples must be positive')
    writer = csv.writer(sys.stdout)
    writer.writerow(['timestamp', 'pid', 'ppid', 'rssKiB', 'cpuPercent', 'executable'])
    # Remember discovered children so reparenting after app exit does not hide them.
    selected = set(args.pid)
    for sample in range(args.samples):
        result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,rss=,%cpu=,comm='],
                                check=True, capture_output=True, text=True)
        rows = [line.split(None, 4) for line in result.stdout.splitlines()]
        rows = [row for row in rows if len(row) == 5]
        while True:
            children = {int(row[0]) for row in rows if int(row[1]) in selected}
            if children <= selected:
                break
            selected.update(children)
        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        for row in rows:
            if int(row[0]) in selected:
                writer.writerow([stamp] + row)
        sys.stdout.flush()
        if sample + 1 < args.samples:
            time.sleep(args.interval)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass

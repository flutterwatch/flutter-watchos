#!/usr/bin/env python3
# Copyright 2026 The FlutterWatch Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Runs a command in a pseudo-terminal and lets a script type into it.

`flutter-watchos run` and `attach` read single keys (r, R, q, d) only from a
terminal. This driver starts the command in a pty, appends everything the
command prints to a log file, and writes into the pty whatever is written to a
control FIFO. When the command exits, the driver appends one line with its exit
code and exits with the same code.

Usage:
    ptydrive.py LOG FIFO -- COMMAND [ARG...]

Example, from a shell script:
    python3 ptydrive.py run.log keys.fifo -- flutter-watchos run -d "$UDID" &
    printf r > keys.fifo
"""

import errno
import os
import pty
import select
import sys
import time


def _parse_args(argv):
    """Returns (log_path, fifo_path, command) from the command line.

    Args:
        argv: sys.argv without the program name.

    Raises:
        SystemExit: when the arguments are malformed.
    """
    if len(argv) < 4 or argv[2] != '--':
        sys.stderr.write(
            'usage: ptydrive.py LOG FIFO -- COMMAND [ARG...]\n')
        sys.exit(2)
    return argv[0], argv[1], argv[3:]


def _pump(child_fd, control_fd, log, start):
    """Copies the child's output to the log and the control input to the child.

    Returns when the child closes its side of the pty.

    Args:
        child_fd: the pty master of the child.
        control_fd: the read end of the control FIFO.
        log: the log file, opened unbuffered in binary append mode.
        start: the monotonic time the child started.
    """
    while True:
        try:
            ready, _, _ = select.select([child_fd, control_fd], [], [], 1.0)
        except InterruptedError:
            continue
        if child_fd in ready:
            try:
                data = os.read(child_fd, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    return
                raise
            if not data:
                return
            log.write(data)
        if control_fd in ready:
            data = os.read(control_fd, 1024)
            if data:
                log.write(b'\n[[ptydrive %.1fs: sending %r]]\n' %
                          (time.monotonic() - start, data))
                os.write(child_fd, data)


def main(argv):
    """Runs the command and returns its exit code."""
    log_path, fifo_path, command = _parse_args(argv)
    if os.path.exists(fifo_path):
        os.unlink(fifo_path)
    os.mkfifo(fifo_path)
    try:
        pid, child_fd = pty.fork()
        if pid == 0:
            try:
                os.execvp(command[0], command)
            finally:
                os._exit(127)  # Only reached when exec fails.
        start = time.monotonic()
        control_fd = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
        # A writer that stays open keeps the FIFO from reading as EOF between
        # the script's writes.
        keep_open_fd = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)
        with open(log_path, 'ab', buffering=0) as log:
            _pump(child_fd, control_fd, log, start)
            _, status = os.waitpid(pid, 0)
            code = os.waitstatus_to_exitcode(status)
            log.write(b'\n[[ptydrive: exit %d after %.1fs]]\n' %
                      (code, time.monotonic() - start))
        os.close(keep_open_fd)
        os.close(control_fd)
        return code if code >= 0 else 128 - code
    finally:
        if os.path.exists(fifo_path):
            os.unlink(fifo_path)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""
Cron service helper

Modes:
  --run         Run scheduled functions once for the current minute (one-shot).
  --list        List all scheduled functions and their cron spec.
  --list-now    List functions that match the current time.
  --daemon      Run continuously, invoking cron.run_now() every minute on the minute.

Optional:
  --pidfile     Path to a PID file to help wrappers manage start/stop/status.
  --log-level   Logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL). Default: INFO.
"""

import argparse
import atexit
import logging
import os
import signal
import sys
import time
from datetime import datetime
from pathlib import Path

import paths

paths.load_apps()

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "settings")

import django

django.setup()

from mojo.helpers import cron


log = logging.getLogger("cron")


def configure_logging(level):
    lvl = getattr(logging, level.upper(), logging.INFO)
    logging.basicConfig(
        level=lvl,
        format="%(asctime)s %(levelname)s [cron] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def fully_qualified_name(func):
    module = getattr(func, "__module__", "") or ""
    qual = getattr(func, "__qualname__", getattr(func, "__name__", repr(func)))
    name = f"{module}.{qual}"
    return name[1:] if name.startswith(".") else name


def list_all_scheduled():
    cron.load_app_cron()
    scheduled = getattr(cron.schedule, "scheduled_functions", [])
    if not scheduled:
        print("No scheduled functions found.")
        return 0

    for item in scheduled:
        func = item.get("func")
        minutes = item.get("minutes", "*")
        hours = item.get("hours", "*")
        days = item.get("days", "*")
        months = item.get("months", "*")
        weekdays = item.get("weekdays", "*")
        name = fully_qualified_name(func)
        print(f"{name} minutes={minutes} hours={hours} days={days} months={months} weekdays={weekdays}")
    return 0


def list_matching_now():
    cron.load_app_cron()
    funcs = cron.find_scheduled_functions()
    if not funcs:
        print("No functions match the current time.")
        return 0
    for func in funcs:
        print(fully_qualified_name(func))
    return 0


def run_once():
    cron.load_app_cron()
    try:
        cron.run_now()
    except Exception as exc:
        log.exception("Error during run_now: %s", exc)
        return 1
    return 0


def process_is_running(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    else:
        return True


def read_pid(pidfile):
    try:
        data = pidfile.read_text(encoding="utf-8").strip()
        if not data:
            return None
        return int(data)
    except FileNotFoundError:
        return None
    except Exception:
        return None


def write_pid(pidfile):
    pidfile.parent.mkdir(parents=True, exist_ok=True)
    pidfile.write_text(str(os.getpid()), encoding="utf-8")


def remove_pidfile(pidfile):
    if pidfile and pidfile.exists():
        try:
            pidfile.unlink()
        except Exception:
            pass


def daemon_loop(pidfile=None):
    cron.load_app_cron()

    stop_flag = {"stop": False}

    def handle_signal(signum, frame):
        log.info("Received signal %s; shutting down...", signum)
        stop_flag["stop"] = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    if pidfile:
        existing_pid = read_pid(pidfile)
        if existing_pid and process_is_running(existing_pid):
            print(f"cron.py: daemon already running with PID {existing_pid}")
            return 0

        write_pid(pidfile)
        atexit.register(remove_pidfile, pidfile)

    log.info("Cron daemon starting...")

    try:
        while not stop_flag["stop"]:
            now = time.time()
            next_boundary = (int(now) // 60 + 1) * 60
            sleep_for = max(0.0, next_boundary - now)
            time.sleep(sleep_for)

            if stop_flag["stop"]:
                break

            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            log.debug("Tick at %s", ts)
            try:
                cron.run_now()
            except Exception as exc:
                log.exception("Error during run_now: %s", exc)
                continue
    finally:
        log.info("Cron daemon stopped.")
    return 0


def build_arg_parser():
    parser = argparse.ArgumentParser(description="Cron helper")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--run", action="store_true", help="Run scheduled functions for current time (one-shot)")
    group.add_argument("--list", action="store_true", help="List all scheduled functions")
    group.add_argument("--list-now", action="store_true", help="List functions matching current time")
    group.add_argument("--daemon", action="store_true", help="Run continuously, every minute on the minute")

    parser.add_argument("--pidfile", type=Path, help="Optional path to PID file (useful for wrappers)")
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Set logging level (default: INFO)",
    )
    return parser


def main(argv):
    parser = build_arg_parser()

    if len(argv) == 0:
        parser.print_help()
        return 0

    args = parser.parse_args(argv)
    configure_logging(args.log_level)

    if args.list:
        return list_all_scheduled()
    if args.list_now:
        return list_matching_now()
    if args.run:
        return run_once()
    if args.daemon:
        return daemon_loop(args.pidfile)

    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

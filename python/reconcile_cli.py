#!/usr/bin/env python3
"""reconcile: compare a bank statement against Meridian settlement records.

Usage:
    reconcile_cli.py STATEMENT.csv --settlements DIR [--concurrency N] [--tolerance MINOR]
                 [--json] [--fail-on-unmatched]

Each statement line is matched to a settlement payout by reference first and
by (amount, value date) second. Settlement files are read concurrently; the
statement is streamed. The exit code is 0 when every line reconciles, 1 when
some do not and --fail-on-unmatched was given, and 2 on a usage or input error.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import signal
import sys
import time
from collections import defaultdict
from collections.abc import AsyncIterator, Sequence
from dataclasses import asdict, dataclass, field
from datetime import date
from decimal import Decimal, InvalidOperation
from enum import StrEnum
from pathlib import Path


class Outcome(StrEnum):
    MATCHED = "matched"
    MATCHED_FUZZY = "matched-fuzzy"
    AMOUNT_MISMATCH = "amount-mismatch"
    UNMATCHED = "unmatched"


@dataclass(frozen=True, slots=True)
class StatementLine:
    line_no: int
    booked: date
    reference: str
    amount_minor: int


@dataclass(frozen=True, slots=True)
class Payout:
    batch_id: str
    reference: str
    value_date: date
    net_minor: int
    source: str


@dataclass(slots=True)
class Result:
    line: StatementLine
    outcome: Outcome
    payout: Payout | None = None
    note: str = ""


@dataclass(slots=True)
class Report:
    results: list[Result] = field(default_factory=list)
    files_read: int = 0
    elapsed_s: float = 0.0

    def counts(self) -> dict[str, int]:
        tally: dict[str, int] = defaultdict(int)
        for r in self.results:
            tally[r.outcome] += 1
        return {o.value: tally[o] for o in Outcome}

    @property
    def clean(self) -> bool:
        return all(r.outcome in (Outcome.MATCHED, Outcome.MATCHED_FUZZY) for r in self.results)


def to_minor(text: str, *, where: str) -> int:
    """Parse '1 234.50' or '-12.5' into integer minor units, exactly."""
    try:
        value = Decimal(text.replace(" ", "").replace(",", ""))
    except InvalidOperation as exc:
        raise ValueError(f"{where}: not an amount: {text!r}") from exc
    scaled = value * 100
    if scaled != scaled.to_integral_value():
        raise ValueError(f"{where}: more than two decimals in {text!r}")
    return int(scaled)


async def read_payouts(path: Path, gate: asyncio.Semaphore) -> list[Payout]:
    """Read one settlement export. File I/O runs in a worker thread."""
    async with gate:
        text = await asyncio.to_thread(path.read_text, encoding="utf-8")

    payouts: list[Payout] = []
    for row_no, row in enumerate(csv.DictReader(text.splitlines()), start=2):
        where = f"{path.name}:{row_no}"
        try:
            payouts.append(
                Payout(
                    batch_id=row["batch"],
                    reference=row["reference"].strip().upper(),
                    value_date=date.fromisoformat(row["value_date"]),
                    net_minor=to_minor(row["net"], where=where),
                    source=path.name,
                )
            )
        except KeyError as exc:
            raise ValueError(f"{where}: missing column {exc.args[0]!r}") from None
    return payouts


async def stream_statement(path: Path) -> AsyncIterator[StatementLine]:
    """Yield statement lines without loading the whole file at once."""
    handle = await asyncio.to_thread(open, path, newline="", encoding="utf-8")
    try:
        reader = csv.reader(handle)
        header = await asyncio.to_thread(next, reader, None)
        if header is None:
            return
        cols = {name.strip().lower(): i for i, name in enumerate(header)}
        for needed in ("date", "reference", "amount"):
            if needed not in cols:
                raise ValueError(f"{path.name}: statement has no {needed!r} column")

        line_no = 1
        while (row := await asyncio.to_thread(next, reader, None)) is not None:
            line_no += 1
            if not any(cell.strip() for cell in row):
                continue
            yield StatementLine(
                line_no=line_no,
                booked=date.fromisoformat(row[cols["date"]].strip()),
                reference=row[cols["reference"]].strip().upper(),
                amount_minor=to_minor(row[cols["amount"]], where=f"{path.name}:{line_no}"),
            )
    finally:
        await asyncio.to_thread(handle.close)


class Matcher:
    """Index payouts once, then answer each statement line in O(1)."""

    def __init__(self, payouts: Sequence[Payout], tolerance_minor: int) -> None:
        self.tolerance = tolerance_minor
        self.by_ref: dict[str, Payout] = {}
        self.by_amount: dict[tuple[int, date], list[Payout]] = defaultdict(list)
        self.used: set[str] = set()
        for p in payouts:
            self.by_ref.setdefault(p.reference, p)
            self.by_amount[(p.net_minor, p.value_date)].append(p)

    def match(self, line: StatementLine) -> Result:
        if (p := self.by_ref.get(line.reference)) and p.batch_id not in self.used:
            delta = line.amount_minor - p.net_minor
            if abs(delta) <= self.tolerance:
                self.used.add(p.batch_id)
                return Result(line, Outcome.MATCHED, p)
            return Result(line, Outcome.AMOUNT_MISMATCH, p, note=f"off by {delta / 100:+.2f}")

        for candidate in self.by_amount.get((line.amount_minor, line.booked), []):
            if candidate.batch_id not in self.used:
                self.used.add(candidate.batch_id)
                return Result(line, Outcome.MATCHED_FUZZY, candidate, note="matched on amount and date")

        return Result(line, Outcome.UNMATCHED)


async def run(args: argparse.Namespace) -> Report:
    started = time.perf_counter()
    files = sorted(args.settlements.glob("*.csv"))
    if not files:
        raise ValueError(f"no settlement exports (*.csv) in {args.settlements}")

    gate = asyncio.Semaphore(args.concurrency)
    async with asyncio.TaskGroup() as tg:
        tasks = [tg.create_task(read_payouts(f, gate)) for f in files]
    payouts = [p for t in tasks for p in t.result()]

    matcher = Matcher(payouts, args.tolerance)
    report = Report(files_read=len(files))
    async for line in stream_statement(args.statement):
        report.results.append(matcher.match(line))

    report.elapsed_s = time.perf_counter() - started
    return report


def render_text(report: Report, out=sys.stdout) -> None:
    marks = {
        Outcome.MATCHED: "  ok ",
        Outcome.MATCHED_FUZZY: "  ~  ",
        Outcome.AMOUNT_MISMATCH: " AMT ",
        Outcome.UNMATCHED: " ??? ",
    }
    for r in report.results:
        if r.outcome is Outcome.MATCHED:
            continue
        batch = r.payout.batch_id if r.payout else "-"
        print(
            f"{marks[r.outcome]} line {r.line.line_no:>5}  {r.line.booked}  "
            f"{r.line.reference:<18} {r.line.amount_minor / 100:>12,.2f}  {batch:<12} {r.note}",
            file=out,
        )
    counts = report.counts()
    summary = ", ".join(f"{v} {k}" for k, v in counts.items() if v)
    print(f"\n{len(report.results)} lines from {report.files_read} exports in {report.elapsed_s:.2f}s: {summary}", file=out)


def render_json(report: Report, out=sys.stdout) -> None:
    def encode(obj: object) -> object:
        if isinstance(obj, date):
            return obj.isoformat()
        raise TypeError(type(obj).__name__)

    payload = {
        "clean": report.clean,
        "counts": report.counts(),
        "elapsed_s": round(report.elapsed_s, 3),
        "exceptions": [asdict(r) for r in report.results if r.outcome is not Outcome.MATCHED],
    }
    json.dump(payload, out, default=encode, indent=2, ensure_ascii=False)
    out.write("\n")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="reconcile", description=__doc__.split("\n\n")[0])
    parser.add_argument("statement", type=Path, help="bank statement CSV (date, reference, amount)")
    parser.add_argument("--settlements", type=Path, required=True, help="folder of settlement exports")
    parser.add_argument("--concurrency", type=int, default=8, help="files read at once (default 8)")
    parser.add_argument("--tolerance", type=int, default=0, help="allowed difference in minor units")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--fail-on-unmatched", action="store_true", help="exit 1 unless everything reconciles")
    args = parser.parse_args(argv)
    if args.concurrency < 1:
        parser.error("--concurrency must be at least 1")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)

    loop = asyncio.new_event_loop()
    main_task = loop.create_task(run(args))
    try:
        loop.add_signal_handler(signal.SIGINT, main_task.cancel)
    except NotImplementedError:  # platforms without signal handlers on the loop
        pass

    try:
        report = loop.run_until_complete(main_task)
    except asyncio.CancelledError:
        print("reconcile: interrupted", file=sys.stderr)
        return 130
    except (ValueError, OSError) as exc:
        print(f"reconcile: {exc}", file=sys.stderr)
        return 2
    except ExceptionGroup as group:  # failures raised inside the TaskGroup
        for exc in group.exceptions:
            print(f"reconcile: {exc}", file=sys.stderr)
        return 2
    finally:
        loop.close()

    (render_json if args.json else render_text)(report)
    return 1 if args.fail_on_unmatched and not report.clean else 0


if __name__ == "__main__":
    raise SystemExit(main())

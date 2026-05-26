#!/usr/bin/env python3
"""
ui_rich.py — Python rich UI helper for do-snap-tool.
Invoked per-call from bash (richpy mode) via:
  uv run --quiet --with rich python3 lib/ui_rich.py <cmd> [args...]

Commands:
  banner TITLE
  header TITLE
  panel  TITLE  KEY1 VAL1  KEY2 VAL2 ...
"""

import sys
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich import box

W = 78
console = Console(width=W, highlight=False)


def cmd_banner(title: str) -> None:
    console.print()
    console.print(
        Panel(
            f"[bold cyan]✦  {title}  ✦[/bold cyan]",
            border_style="cyan",
            box=box.DOUBLE,
            padding=(0, 4),
            width=W,
        )
    )
    console.print()


def cmd_header(title: str) -> None:
    console.print()
    console.print(f"  [bold cyan]── {title} ──[/bold cyan]")
    console.print()


def cmd_panel(title: str, *pairs: str) -> None:
    grid = Table.grid(padding=(0, 2))
    grid.add_column(style="bold", min_width=18)
    grid.add_column()
    for i in range(0, len(pairs) - 1, 2):
        grid.add_row(pairs[i], pairs[i + 1])
    console.print()
    console.print(
        Panel(
            grid,
            title=f"[bold cyan]{title}[/bold cyan]",
            border_style="cyan",
            box=box.ROUNDED,
            padding=(0, 1),
            width=W,
        )
    )
    console.print()


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(1)
    cmd, *args = sys.argv[1], sys.argv[2:]
    if cmd == "banner" and args:
        cmd_banner(args[0])
    elif cmd == "header" and args:
        cmd_header(args[0])
    elif cmd == "panel" and args:
        cmd_panel(args[0], *args[1:])
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()

"""todo: a tiny command-line task list."""
import argparse
import os
import sys

from .storage import Store


def format_item(item):
    mark = "x" if item["done"] else " "
    return f"[{mark}] {item['id']}: {item['title']}"


def main(argv=None):
    parser = argparse.ArgumentParser(prog="todo", description=__doc__)
    parser.add_argument("--file", default=os.environ.get("TODO_FILE", "todo.json"))
    sub = parser.add_subparsers(dest="command", required=True)
    p_add = sub.add_parser("add")
    p_add.add_argument("title")
    sub.add_parser("list")
    p_done = sub.add_parser("done")
    p_done.add_argument("id", type=int)
    args = parser.parse_args(argv)

    store = Store(args.file)
    if args.command == "add":
        item = store.add(args.title)
        print(format_item(item))
    elif args.command == "list":
        for item in store.load():
            print(format_item(item))
    elif args.command == "done":
        try:
            print(format_item(store.mark_done(args.id)))
        except KeyError:
            print(f"no item {args.id}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

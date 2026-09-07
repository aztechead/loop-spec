"""JSON-file storage for todo items."""
import json
import os


class Store:
    def __init__(self, path):
        self.path = path

    def load(self):
        if not os.path.exists(self.path):
            return []
        with open(self.path, encoding="utf-8") as fh:
            return json.load(fh)

    def save(self, items):
        with open(self.path, "w", encoding="utf-8") as fh:
            json.dump(items, fh, indent=2)

    def add(self, title):
        items = self.load()
        item = {"id": (max([i["id"] for i in items]) + 1) if items else 1,
                "title": title, "done": False}
        items.append(item)
        self.save(items)
        return item

    def mark_done(self, item_id):
        items = self.load()
        for item in items:
            if item["id"] == item_id:
                item["done"] = True
                self.save(items)
                return item
        raise KeyError(item_id)

"""Turn a title into a URL slug."""
import re


def slugify(title):
    slug = title.lower()
    slug = re.sub(r"[^a-z0-9]", "-", slug)
    return slug

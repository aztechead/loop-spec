"""docs-probe.py - Current version and documentation for a named dependency, from live sources.

Why: the grounding protocol says model memory of a fast-moving library is a hypothesis
and the current docs are the fact, and the version directive says a version comes from
a tool, never recall. Neither named the tool. A live run asked a stale local catalog
which Python 3.14 was current, took the release candidate it answered, and spent twenty
commands on a crash the final release did not have. This module is the tool: it asks
the registry or the release tracker over the network, resolves where the docs live, and
returns the sections that answer a topic. Nothing here is specific to one language:
every source is a row in SOURCES, and the ecosystem comes from the flag, else the
manifest in the directory, else every row in turn.

lib/docs-probe.sh owns arguments and paths; this module owns the work.

Subcommands (argv[1]):
  resolve <name>   one JSON line {name, ecosystem, version, homepage, docs, repo, source}
  latest  <name>   one line: version=<v> source=<url> ecosystem=<e>
  docs    <name>   header "docs: <name>@<v> source=<url>" then the selected text

Options: --ecosystem E, --version V, --topic WORD (repeatable), --max-lines N, --dir DIR.
Exit: 0 answered; 1 nothing answered (the one line says version=unverified or
docs: unverified with the reason); 2 bad invocation.

Environment:
  LOOP_SPEC_DOCS_FIXTURES   directory of canned responses keyed by sha1(url)[:16];
                            set, no network is touched (the test double)
  LOOP_SPEC_DOCS_CACHE_DIR  fetch cache (default $TMPDIR/loop-spec-docs-cache)
  LOOP_SPEC_DOCS_CACHE_TTL_SECS  cache lifetime (default 3600)
"""
import hashlib
import html.parser
import json
import os
import re
import subprocess
import sys
import time

# ecosystem -> how to resolve a name. `url` is a format with {name}; `parse` reads the
# JSON into the common record. A runtime (python, nodejs, go, ...) is one more row.
SOURCES = {
    "runtime": {
        "url": "https://endoflife.date/api/{name}.json",
        "parse": lambda d: {
            "version": (d[0].get("latest") if isinstance(d, list) and d else None),
            "homepage": None, "docs": None, "repo": None},
        "manifests": (),
    },
    "pypi": {
        "url": "https://pypi.org/pypi/{name}/json",
        "version_url": "https://pypi.org/pypi/{name}/{version}/json",
        "parse": lambda d: {
            "version": d.get("info", {}).get("version"),
            "homepage": (d.get("info", {}).get("home_page")
                         or _url_key(d.get("info", {}).get("project_urls"), "homepage")),
            "docs": _url_key(d.get("info", {}).get("project_urls"), "documentation", "docs"),
            "repo": _repo_str(_url_key(d.get("info", {}).get("project_urls"), "source", "repository", "code", "github")),
            "readme": d.get("info", {}).get("description")},
        "manifests": ("pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"),
    },
    "npm": {
        "url": "https://registry.npmjs.org/{name}",
        "version_url": "https://registry.npmjs.org/{name}/{version}",
        "parse": lambda d: {
            "version": (d.get("dist-tags") or {}).get("latest") or d.get("version"),
            "homepage": d.get("homepage"),
            "docs": None,
            "repo": _repo_str(d.get("repository")),
            "readme": d.get("readme")},
        "manifests": ("package.json",),
    },
    "crates": {
        "url": "https://crates.io/api/v1/crates/{name}",
        "parse": lambda d: {
            "version": (d.get("crate") or {}).get("max_stable_version"),
            "homepage": (d.get("crate") or {}).get("homepage"),
            "docs": (d.get("crate") or {}).get("documentation"),
            "repo": (d.get("crate") or {}).get("repository")},
        "manifests": ("Cargo.toml",),
    },
    "rubygems": {
        "url": "https://rubygems.org/api/v1/gems/{name}.json",
        "parse": lambda d: {
            "version": d.get("version"),
            "homepage": d.get("homepage_uri"),
            "docs": d.get("documentation_uri"),
            "repo": d.get("source_code_uri")},
        "manifests": ("Gemfile",),
    },
    "go": {
        "url": "https://proxy.golang.org/{name}/@latest",
        "parse": lambda d: {
            "version": d.get("Version"),
            "homepage": None,
            "docs": None,
            "repo": None},
        "manifests": ("go.mod",),
    },
}
ORDER = ("runtime", "pypi", "npm", "crates", "rubygems", "go")
UA = "loop-spec-docs-probe"


def _url_key(urls, *keys):
    for k, v in (urls or {}).items():
        if any(key in k.lower() for key in keys):
            return v
    return None


def _repo_str(repo):
    if isinstance(repo, dict):
        repo = repo.get("url")
    if not isinstance(repo, str):
        return None
    return re.sub(r"^git\+|\.git$", "", repo.replace("git://", "https://").replace("ssh://git@", "https://"))


def fetch(url):
    """Body text or None. Fixture dir first (tests), then cache, then curl."""
    key = hashlib.sha1(url.encode()).hexdigest()[:16]
    fixtures = os.environ.get("LOOP_SPEC_DOCS_FIXTURES")
    if fixtures:
        path = os.path.join(fixtures, key)
        return open(path, encoding="utf-8").read() if os.path.isfile(path) else None
    cache_dir = os.environ.get("LOOP_SPEC_DOCS_CACHE_DIR") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "loop-spec-docs-cache")
    ttl = int(os.environ.get("LOOP_SPEC_DOCS_CACHE_TTL_SECS") or 3600)
    cached = os.path.join(cache_dir, key)
    if os.path.isfile(cached) and time.time() - os.path.getmtime(cached) < ttl:
        return open(cached, encoding="utf-8").read()
    try:
        proc = subprocess.run(["curl", "-sSL", "-A", UA, "--max-time", "20", "--fail", url],
                              capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0 or not proc.stdout:
        return None
    try:
        os.makedirs(cache_dir, exist_ok=True)
        with open(cached, "w", encoding="utf-8") as fh:
            fh.write(proc.stdout)
    except OSError:
        pass
    return proc.stdout


def ecosystems_for(flag, directory):
    if flag:
        if flag not in SOURCES:
            sys.exit("docs-probe: unknown ecosystem '%s' (known: %s)" % (flag, ", ".join(ORDER)))
        return [flag]
    found = [e for e in ORDER if any(os.path.exists(os.path.join(directory, m)) for m in SOURCES[e]["manifests"])]
    return found or list(ORDER)


def resolve(name, ecosystems, version=None):
    tried = []
    for eco in ecosystems:
        src = SOURCES[eco]
        url = src["url"].format(name=name)
        if version and src.get("version_url"):
            url = src["version_url"].format(name=name, version=version)
        body = fetch(url)
        if body is None:
            tried.append(url)
            continue
        try:
            data = json.loads(body)
        except ValueError:
            tried.append(url)
            continue
        rec = src["parse"](data)
        if not rec.get("version"):
            tried.append(url)
            continue
        rec.update({"name": name, "ecosystem": eco, "source": url})
        if version:
            rec["version"] = version
        return rec, tried
    return None, tried


class _Text(html.parser.HTMLParser):
    """Docs page to text: headings kept as markdown, chrome and scripts dropped."""
    SKIP = {"script", "style", "nav", "header", "footer"}

    def __init__(self):
        super().__init__()
        self.out, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        elif tag in ("p", "br", "li", "h1", "h2", "h3", "h4", "pre", "div", "tr"):
            self.out.append("\n")
        if tag in ("h1", "h2", "h3", "h4") and not self.skip:
            self.out.append("#" * int(tag[1]) + " ")

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skip:
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.out.append(data)



def doc_candidates(rec):
    """URLs to try, most specific first: llms.txt where the docs live, the README at
    the version's tag, the registry's own readme, the docs page itself."""
    urls = []
    for base in (rec.get("docs"), rec.get("homepage")):
        if base and base.startswith("http"):
            base = base.rstrip("/")
            urls += [(base + "/llms-full.txt", "llms"), (base + "/llms.txt", "llms")]
    repo = rec.get("repo") or ""
    m = re.match(r"https?://github\.com/([^/]+)/([^/#?]+)", repo)
    if m:
        owner, project = m.group(1), m.group(2)
        for ref in ("v" + str(rec.get("version")), str(rec.get("version")), "HEAD"):
            urls.append(("https://raw.githubusercontent.com/%s/%s/%s/README.md" % (owner, project, ref), "readme"))
    if rec.get("readme"):
        urls.append(("registry:readme", "registry"))
    if rec.get("docs") and rec["docs"].startswith("http"):
        urls.append((rec["docs"], "html"))
    return urls


def sections(text):
    """Markdown split on headings: [(heading, body_lines)]. Text before the first
    heading is its own section."""
    out, head, body = [], "", []
    for line in text.splitlines():
        if re.match(r"^#{1,6}\s", line):
            if head or body:
                out.append((head, body))
            head, body = line, []
        else:
            body.append(line)
    if head or body:
        out.append((head, body))
    return out


def select(text, topics, max_lines):
    if not topics:
        return "\n".join(text.splitlines()[:max_lines])
    terms = [t.lower() for t in topics]
    scored = []
    for i, (head, body) in enumerate(sections(text)):
        h, b = head.lower(), "\n".join(body).lower()
        score = sum(3 for t in terms if t in h) + sum(b.count(t) for t in terms)
        if score:
            scored.append((-score, i, head, body))
    scored.sort()
    out, used = [], 0
    for _, _, head, body in scored:
        chunk = ([head] if head else []) + body
        if used + len(chunk) > max_lines and out:
            chunk = chunk[: max(0, max_lines - used)]
        out += chunk
        used += len(chunk)
        if used >= max_lines:
            break
    return "\n".join(out)


def cmd_docs(rec, topics, max_lines):
    for url, kind in doc_candidates(rec):
        if kind == "registry":
            body = rec.get("readme")
            url = rec["source"]
        else:
            body = fetch(url)
        if not body or len(body.strip()) < 40:
            continue
        if kind == "html" or body.lstrip().startswith("<"):
            parser = _Text()
            parser.feed(body)
            body = re.sub(r"\n{3,}", "\n\n", "".join(parser.out)).strip()
        text = body
        print("docs: %s@%s source=%s" % (rec["name"], rec["version"], url))
        print(select(text, topics, max_lines))
        return 0
    print("docs: unverified reason=no documentation source answered for %s@%s (tried llms.txt, README, registry readme, docs page)"
          % (rec["name"], rec["version"]))
    return 1


def main(argv):
    if len(argv) < 3 or argv[1] not in ("resolve", "latest", "docs"):
        print("docs-probe: usage: docs-probe.py resolve|latest|docs <name> [options]", file=sys.stderr)
        sys.exit(2)
    cmd, name = argv[1], argv[2]
    eco = version = None
    topics, max_lines, directory = [], 120, os.getcwd()
    args = argv[3:]
    while args:
        flag = args.pop(0)
        if flag == "--ecosystem" and args:
            eco = args.pop(0)
        elif flag == "--version" and args:
            version = args.pop(0)
        elif flag == "--topic" and args:
            topics.append(args.pop(0))
        elif flag == "--max-lines" and args and args[0].isdigit():
            max_lines = int(args.pop(0))
        elif flag == "--dir" and args:
            directory = args.pop(0)
        else:
            print("docs-probe: unknown option '%s'" % flag, file=sys.stderr)
            sys.exit(2)
    rec, tried = resolve(name, ecosystems_for(eco, directory), version)
    if rec is None:
        reason = "no source answered for '%s' (tried %s)" % (name, ", ".join(tried) or "nothing")
        print(("docs: unverified reason=%s" if cmd == "docs" else "version=unverified reason=%s") % reason)
        return 1
    if cmd == "resolve":
        print(json.dumps({k: rec.get(k) for k in ("name", "ecosystem", "version", "homepage", "docs", "repo", "source")}))
        return 0
    if cmd == "latest":
        print("version=%s source=%s ecosystem=%s" % (rec["version"], rec["source"], rec["ecosystem"]))
        return 0
    return cmd_docs(rec, topics, max_lines)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

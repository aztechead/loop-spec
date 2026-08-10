#!/usr/bin/env bash
# plain-language-lint.sh - Deterministic READABILITY probe for model-authored prose.
#
# Why: "write plainly" is unenforceable as prose -- every run judges its own writing
# generous, exactly the failure CLAUDE.md's "Probes, not judgments" names. This turns
# Orwell's six rules ("Politics and the English Language", 1946) and a small set of
# STE-informed structural rules (skills/shared/plain-language.md is the canonical
# contract; read it first) into eight countable, greppable checks: long sentences,
# passive voice, bureaucratic long words, foreign/Latin phrases, tired metaphors, "/"
# used as and/or, run-on paragraphs, and gerund-headed instructions.
#
# Scope guard: this is READABILITY only. It does not duplicate lib/comment-tells.sh,
# which flags comments that narrate the diff, narrate history, or restate the next
# line of code -- a different failure mode (machine-written tells, not prose style).
#
# ADVISORY ONLY: this script only ever reports. Nothing here is wired to block a
# phase, and callers decide what to do with a non-zero exit. Do not wire it into a
# gate without a separate, deliberate change.
#
# Usage:
#   plain-language-lint.sh prose    <file|-> [file...]   # markdown artifacts
#   plain-language-lint.sh comments <file|-> [file...]   # #-comments (sh/py), py docstrings
#   plain-language-lint.sh text     -                    # stdin: PR bodies, commit messages
#   plain-language-lint.sh --rules                       # print every check name, one per line
#   plain-language-lint.sh <mode> --max-flags N ...      # cap FLAG lines printed (0 = no cap)
#
# Output: one `FLAG <path>:<line>: <message>` per defect (message is
# `<check-name>: <detail>`, greppable on the check name), then one final answer line:
# `plain-language-lint: ok (<mode>: <path>)` or
# `plain-language-lint: <n> flag(s) (<mode>: <path>)`.
#
# Exit codes: 0 clean, 1 any flag (including unreadable/empty input -- fail safe),
# 2 bad invocation.
set -uo pipefail

MAX_FLAGS=0
SHOW_RULES=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rules) SHOW_RULES=1; shift ;;
    --max-flags)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "usage: plain-language-lint.sh --max-flags N (N is a non-negative integer)" >&2; exit 2; }
      MAX_FLAGS="$2"; shift 2 ;;
    --max-flags=*)
      MAX_FLAGS="${1#*=}"
      [[ "$MAX_FLAGS" =~ ^[0-9]+$ ]] || { echo "usage: plain-language-lint.sh --max-flags N (N is a non-negative integer)" >&2; exit 2; }
      shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ "$SHOW_RULES" == "1" ]]; then
  python3 - "--rules" "$MAX_FLAGS" <<'PY'
import sys
print("\n".join([
    "long-sentence", "passive-voice", "long-word", "foreign-phrase",
    "stock-phrase", "slash-and-or", "long-paragraph", "gerund-heading",
]))
PY
  exit 0
fi

mode="${ARGS[0]:-}"
case "$mode" in
  prose|comments) [[ ${#ARGS[@]} -ge 2 ]] || { echo "usage: plain-language-lint.sh $mode <file|-> [file...]" >&2; exit 2; } ;;
  text) [[ ${#ARGS[@]} -eq 2 && "${ARGS[1]}" == "-" ]] || { echo "usage: plain-language-lint.sh text -" >&2; exit 2; } ;;
  *) echo "usage: plain-language-lint.sh <prose|comments|text|--rules> <file|-> [...]" >&2; exit 2 ;;
esac
unset 'ARGS[0]'

# A `-` path can't also be read from stdin inside the python heredoc below, so it
# is slurped into a temp file first -- same trick lib/artifact-lint.sh uses.
paths=()
stdin_tmp=""
for p in "${ARGS[@]}"; do
  if [[ "$p" == "-" ]]; then
    stdin_tmp="$(mktemp "${TMPDIR:-/tmp}/plain-language-lint-stdin.XXXXXX")"
    cat > "$stdin_tmp"
    paths+=("--stdin:$stdin_tmp")
  else
    paths+=("$p")
  fi
done
trap '[[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"' EXIT

python3 - "$mode" "$MAX_FLAGS" "${paths[@]}" <<'PY'
import re
import sys

mode = sys.argv[1]
max_flags = int(sys.argv[2])
paths = sys.argv[3:]

flags = []


def flag(path, line, message):
    flags.append((path, line, message))


def read_source(path):
    display = path
    real = path
    if path.startswith('--stdin:'):
        display, real = '<stdin>', path[len('--stdin:'):]
    try:
        data = open(real, 'rb').read()
    except OSError as exc:
        flag(display, 0, 'input is unreadable: %s' % exc)
        return display, None
    if not data.strip():
        flag(display, 0, 'input is empty')
        return display, None
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as exc:
        flag(display, 0, 'input is not valid UTF-8: %s' % exc)
        return display, None
    return display, text


# ---------------------------------------------------------------------------
# Curated lists. These are loop-spec's OWN short lists, written from scratch --
# not a reproduction of ASD-STE100's controlled vocabulary. See
# skills/shared/plain-language.md for the copyright note this repo must respect.
# ---------------------------------------------------------------------------

RULE_LONG_SENTENCE = 'long-sentence'
RULE_PASSIVE_VOICE = 'passive-voice'
RULE_LONG_WORD = 'long-word'
RULE_FOREIGN_PHRASE = 'foreign-phrase'
RULE_STOCK_PHRASE = 'stock-phrase'
RULE_SLASH_AND_OR = 'slash-and-or'
RULE_LONG_PARAGRAPH = 'long-paragraph'
RULE_GERUND_HEADING = 'gerund-heading'

LONG_WORDS = {
    'utilize': 'use', 'utilizes': 'uses', 'utilized': 'used', 'utilizing': 'using',
    'utilization': 'use',
    'facilitate': 'help', 'facilitates': 'helps', 'facilitated': 'helped',
    'facilitating': 'helping',
    'endeavor': 'try', 'endeavour': 'try', 'endeavors': 'tries', 'endeavours': 'tries',
    'terminate': 'end', 'terminates': 'ends', 'terminated': 'ended', 'terminating': 'ending',
    'sufficient': 'enough',
    'commence': 'start', 'commences': 'starts', 'commenced': 'started',
    'commencing': 'starting',
    'purchase': 'buy', 'purchases': 'buys', 'purchased': 'bought', 'purchasing': 'buying',
    'ascertain': 'find out', 'ascertains': 'finds out', 'ascertained': 'found out',
    'additional': 'more',
    'approximately': 'about',
    'numerous': 'many',
    'cognizant': 'aware',
    'notify': 'tell', 'notifies': 'tells', 'notified': 'told', 'notifying': 'telling',
    'obtain': 'get', 'obtains': 'gets', 'obtained': 'got', 'obtaining': 'getting',
    'demonstrate': 'show', 'demonstrates': 'shows', 'demonstrated': 'showed',
    'demonstrating': 'showing',
    'indicate': 'show', 'indicates': 'shows', 'indicated': 'showed', 'indicating': 'showing',
    'attempt': 'try', 'attempts': 'tries', 'attempted': 'tried', 'attempting': 'trying',
    'leverage': 'use', 'leverages': 'uses', 'leveraged': 'used', 'leveraging': 'using',
    'optimal': 'best',
    'subsequent': 'later',
    'remainder': 'rest',
    'transmit': 'send', 'transmits': 'sends', 'transmitted': 'sent', 'transmitting': 'sending',
    'modify': 'change', 'modifies': 'changes', 'modified': 'changed', 'modifying': 'changing',
    'initiate': 'start', 'initiates': 'starts', 'initiated': 'started',
    'initiating': 'starting',
    'finalize': 'finish', 'finalizes': 'finishes', 'finalized': 'finished',
    'finalizing': 'finishing',
    'eliminate': 'remove', 'eliminates': 'removes', 'eliminated': 'removed',
    'eliminating': 'removing',
}

FOREIGN_PHRASES = {
    'e.g.': 'for example', 'i.e.': 'that is',
    'vis-a-vis': 'compared to', 'vis-à-vis': 'compared to',
    'per se': 'in itself', 'ad hoc': 'improvised', 'inter alia': 'among other things',
    'et al.': 'and others', 'etc.': 'and so on', 'a priori': 'presumed',
    'de facto': 'in practice', 'status quo': 'the current situation',
    'vice versa': 'the other way around', 'bona fide': 'genuine',
}

STOCK_PHRASES = [
    'at the end of the day', 'low-hanging fruit', 'move the needle',
    'think outside the box', 'boil the ocean', 'circle back', 'touch base',
    'paradigm shift', 'on the same page', 'level the playing field',
    'tip of the iceberg', 'in this day and age', 'when all is said and done',
    'each and every', 'first and foremost', 'needless to say', 'game changer',
    'silver bullet',
]

SLASH_PAIRS = [
    'and/or', 'he/she', 'his/her', 'him/her', 's/he', 'pass/fail', 'yes/no',
    'true/false', 'on/off', 'read/write', 'buyer/seller', 'employer/employee',
]

IMPERATIVE_VERBS = {
    'run', 'add', 'use', 'check', 'read', 'set', 'create', 'remove', 'ensure', 'do',
    'make', 'call', 'pass', 'return', 'write', 'update', 'verify', 'confirm', 'avoid',
    'never', 'always', 'open', 'close', 'start', 'stop', 'wait', 'install', 'configure',
    'enable', 'disable', 'skip', 'keep', 'move', 'delete', 'copy', 'edit', 'save',
    'load', 'build', 'test', 'deploy', 'fix', 'follow', 'apply', 'provide', 'include',
    'see', 'refer', 'note', 'click', 'type', 'enter', 'select', 'choose', 'navigate',
    'review', 'revert',
}

GERUND_MAP = {
    'installing': 'install', 'configuring': 'configure', 'running': 'run',
    'adding': 'add', 'creating': 'create', 'setting': 'set', 'building': 'build',
    'deploying': 'deploy', 'updating': 'update', 'removing': 'remove',
    'writing': 'write', 'testing': 'test', 'checking': 'check', 'enabling': 'enable',
    'disabling': 'disable', 'starting': 'start', 'stopping': 'stop',
    'connecting': 'connect', 'using': 'use', 'sending': 'send', 'receiving': 'receive',
    'loading': 'load', 'saving': 'save', 'deleting': 'delete', 'editing': 'edit',
    'reviewing': 'review', 'verifying': 'verify', 'initializing': 'initialize',
    'registering': 'register', 'publishing': 'publish',
}

BE_FORMS = {'am', 'is', 'are', 'was', 'were', 'be', 'been', 'being'}
IRREGULAR_PARTICIPLES = {
    'done', 'made', 'given', 'taken', 'written', 'shown', 'seen', 'known', 'sent',
    'built', 'brought', 'bought', 'thought', 'held', 'put', 'set', 'found', 'kept',
    'left', 'lost', 'meant', 'paid', 'said', 'sold', 'told', 'understood', 'chosen',
    'broken', 'spoken', 'driven', 'eaten', 'forgotten', 'hidden', 'ridden', 'risen',
    'stolen', 'torn', 'worn', 'drawn', 'born', 'begun', 'gone', 'grown', 'flown',
    'thrown', 'blown',
}

WORD_RE = re.compile(r"[A-Za-z][A-Za-z'-]*")


def words_in(text):
    return WORD_RE.findall(text)


def count_words(text):
    return len(words_in(text))


def _alt_re(keys):
    ordered = sorted(keys, key=len, reverse=True)
    return re.compile(
        r'(?<![A-Za-z])(' + '|'.join(re.escape(k) for k in ordered) + r')(?![A-Za-z])',
        re.I)


LONGWORD_RE = re.compile(
    r'\b(' + '|'.join(re.escape(w) for w in sorted(LONG_WORDS, key=len, reverse=True)) + r')\b',
    re.I)
FOREIGN_RE = _alt_re(FOREIGN_PHRASES.keys())
STOCK_RE = _alt_re(STOCK_PHRASES)
SLASH_RE = _alt_re(SLASH_PAIRS)
PASSIVE_RE = re.compile(r'\b(' + '|'.join(BE_FORMS) + r')\s+(\w+)\b', re.I)
GERUND_HEAD_RE = re.compile(
    r'^(' + '|'.join(GERUND_MAP.keys()) + r')\b(.*)$', re.I)


def find_passive(text):
    hits = []
    for m in PASSIVE_RE.finditer(text):
        participle = m.group(2).lower()
        if participle in IRREGULAR_PARTICIPLES or (participle.endswith('ed') and len(participle) > 3):
            hits.append(m.group(0).strip())
    return hits


def check_line(display, lineno, text):
    if not text.strip():
        return
    for hit in find_passive(text):
        flag(display, lineno,
             "%s: passive construction '%s' -- name the actor instead"
             % (RULE_PASSIVE_VOICE, hit))
    for m in LONGWORD_RE.finditer(text):
        w = m.group(1).lower()
        flag(display, lineno,
             "%s: '%s' has a shorter plain-language option ('%s')"
             % (RULE_LONG_WORD, m.group(1), LONG_WORDS[w]))
    for m in FOREIGN_RE.finditer(text):
        p = m.group(1).lower()
        flag(display, lineno,
             "%s: '%s' has an everyday equivalent ('%s')"
             % (RULE_FOREIGN_PHRASE, m.group(1), FOREIGN_PHRASES[p]))
    for m in STOCK_RE.finditer(text):
        flag(display, lineno,
             "%s: tired phrase '%s' -- say it plainly" % (RULE_STOCK_PHRASE, m.group(1)))
    for m in SLASH_RE.finditer(text):
        flag(display, lineno,
             "%s: '%s' -- write 'and' or 'or' and mean one of them"
             % (RULE_SLASH_AND_OR, m.group(1)))


def check_heading(display, lineno, heading_text):
    text = heading_text.strip()
    m = GERUND_HEAD_RE.match(text)
    if not m:
        return
    rest = m.group(2).strip()
    if not rest:
        return  # a single-word heading ("## Testing") is a noun title, not a clause
    gerund = m.group(1).lower()
    flag(display, lineno,
         "%s: '%s' should be the imperative '%s' -- %s"
         % (RULE_GERUND_HEADING, m.group(1), GERUND_MAP[gerund], text[:60]))


# A '.' with a digit on each side is a decimal or a version (2.35, v1.2.3),
# not a sentence boundary. Splitting there mangles the excerpt AND hides long
# sentences, since the fragments each fall under the cap.
SENTENCE_RE = re.compile(r'(?:[^.!?]|(?<=\d)\.(?=\d))*[.!?]+')


def split_sentences(text):
    out = []
    pos = 0
    for m in SENTENCE_RE.finditer(text):
        s = m.group().strip()
        if s:
            out.append((s, m.start()))
        pos = m.end()
    tail = text[pos:].strip()
    if tail:
        out.append((tail, pos))
    return out


def classify_imperative(is_list_block, sentence_text):
    if is_list_block:
        return True
    w = words_in(sentence_text)
    return bool(w) and w[0].lower() in IMPERATIVE_VERBS


def check_sentence(display, lineno, sentence_text, is_list_block):
    n = count_words(sentence_text)
    imperative = classify_imperative(is_list_block, sentence_text)
    limit = 20 if imperative else 25
    if n > limit:
        kind = 'imperative' if imperative else 'descriptive'
        snippet = sentence_text.strip()
        if len(snippet) > 70:
            snippet = snippet[:67] + '...'
        flag(display, lineno,
             "%s: %d words (max %d for %s %s sentence): %s"
             % (RULE_LONG_SENTENCE, n, limit,
                'an' if kind[:1] in 'aeiou' else 'a', kind, snippet))


LINK_RE = re.compile(r'\[([^\]]*)\]\([^)]*\)')
BARE_URL_RE = re.compile(r'https?://\S+')
INLINE_CODE_RE = re.compile(r'`[^`]*`')


def clean_prose(text):
    # Link labels are prose; the URL inside is not (a URL that happens to contain
    # a banned word must never flag). Inline code spans are not prose either --
    # `utilize()` is an identifier, not a word choice.
    text = LINK_RE.sub(r'\1', text)
    text = BARE_URL_RE.sub('', text)
    text = INLINE_CODE_RE.sub('', text)
    return text


def mask_prose(text):
    text = text.replace('\r\n', '\n')
    lines = text.split('\n')
    n = len(lines)
    body_start = 0
    if lines and lines[0].strip() == '---':
        body_start = n  # unclosed frontmatter: fail safe, skip the whole file
        for i in range(1, n):
            if lines[i].strip() == '---':
                body_start = i + 1
                break
    stream = []
    in_fence = False
    last_kind = 'blank'
    for i in range(n):
        lineno = i + 1
        if i < body_start:
            continue
        stripped = lines[i].strip()
        if stripped.startswith('```') or stripped.startswith('~~~'):
            in_fence = not in_fence
            last_kind = 'other'
            continue
        if in_fence:
            continue
        if not stripped:
            stream.append((lineno, 'blank', ''))
            last_kind = 'blank'
            continue
        if stripped.startswith('|') or (
                '|' in stripped and '-' in stripped
                and re.match(r'^[:\-\|\s]+$', stripped)):
            stream.append((lineno, 'table', ''))
            last_kind = 'other'
            continue
        m = re.match(r'^(#{1,6})\s+(.*)$', stripped)
        if m:
            stream.append((lineno, 'heading', clean_prose(m.group(2))))
            last_kind = 'other'
            continue
        m = re.match(r'^(?:[-*+]|\d+[.)])\s+(.*)$', stripped)
        if m:
            stream.append((lineno, 'list', clean_prose(m.group(1))))
            last_kind = 'list'
            continue
        # An indented run-on line right after a list item is that item's wrapped
        # text, not a new paragraph -- fold it into the same block (list_cont)
        # so a sentence split across two physical lines still counts as one.
        if last_kind in ('list', 'list_cont'):
            stream.append((lineno, 'list_cont', clean_prose(lines[i])))
            last_kind = 'list_cont'
        else:
            stream.append((lineno, 'text', clean_prose(lines[i])))
            last_kind = 'text'
    return stream


def mask_comments(path, text):
    ext = path.rsplit('.', 1)[-1].lower() if '.' in path else ''
    lines = text.split('\n')
    n = len(lines)
    docstring_lines = set()
    if ext == 'py':
        # A regex triple-quote scan, not a parser -- it can mistake a non-docstring
        # triple-quoted string for one. Documented as a heuristic in the contract.
        for m in re.finditer(r'("""|\'\'\')(.*?)\1', text, re.S):
            start = text.count('\n', 0, m.start(2)) + 1
            end = text.count('\n', 0, m.end(2)) + 1
            for ln in range(start, end + 1):
                docstring_lines.add(ln)
    stream = []
    for i in range(n):
        lineno = i + 1
        stripped = lines[i].strip()
        if lineno == 1 and stripped.startswith('#!'):
            stream.append((lineno, 'blank', ''))
            continue
        if ext == 'py' and lineno in docstring_lines:
            cleaned = re.sub(r'^[\'"]{3}', '', stripped)
            cleaned = re.sub(r'[\'"]{3}$', '', cleaned)
            stream.append((lineno, 'text', clean_prose(cleaned)))
            continue
        if stripped.startswith('#'):
            cleaned = re.sub(r'^#+\s?', '', stripped)
            stream.append((lineno, 'text', clean_prose(cleaned)))
            continue
        stream.append((lineno, 'blank', ''))
    return stream


def build_blocks(stream):
    """Group a (lineno, kind, text) stream into paragraph-shaped blocks. 'heading'
    always starts its own single-line block. 'list' starts a new list block;
    'list_cont' (a wrapped continuation line under that bullet) merges into it.
    Contiguous 'text' lines merge into one block. Anything else
    (blank/table/fence/frontmatter) breaks the current block without becoming
    one itself."""
    blocks = []
    current = None
    for lineno, kind, text in stream:
        if kind == 'heading':
            if current:
                blocks.append(current)
                current = None
            blocks.append({'kind': 'heading', 'lines': [(lineno, text)]})
        elif kind == 'list':
            if current:
                blocks.append(current)
            current = {'kind': 'list', 'lines': [(lineno, text)]}
        elif kind == 'list_cont':
            if current and current['kind'] == 'list':
                current['lines'].append((lineno, text))
            else:
                # Defensive: a continuation line with no open list block behaves
                # like an ordinary paragraph line instead of being dropped.
                if current and current['kind'] == 'text':
                    current['lines'].append((lineno, text))
                else:
                    if current:
                        blocks.append(current)
                    current = {'kind': 'text', 'lines': [(lineno, text)]}
        elif kind == 'text':
            if current and current['kind'] == 'text':
                current['lines'].append((lineno, text))
            else:
                if current:
                    blocks.append(current)
                current = {'kind': 'text', 'lines': [(lineno, text)]}
        else:
            if current:
                blocks.append(current)
                current = None
    if current:
        blocks.append(current)
    return blocks


def process_blocks(display, blocks):
    for block in blocks:
        if block['kind'] == 'heading':
            lineno, text = block['lines'][0]
            check_line(display, lineno, text)
            check_heading(display, lineno, text)
            continue
        for lineno, text in block['lines']:
            check_line(display, lineno, text)
        joined_chars = []
        offset_line = []
        for lineno, text in block['lines']:
            for ch in text:
                joined_chars.append(ch)
                offset_line.append(lineno)
            joined_chars.append(' ')
            offset_line.append(lineno)
        joined = ''.join(joined_chars)
        is_list = block['kind'] == 'list'
        first_line = block['lines'][0][0]
        counted = 0
        for sent_text, start in split_sentences(joined):
            ln = offset_line[start] if start < len(offset_line) else first_line
            check_sentence(display, ln, sent_text, is_list)
            if count_words(sent_text) >= 2:
                counted += 1
        if block['kind'] == 'text' and counted > 6:
            flag(display, first_line,
                 "%s: %d sentences (max 6)" % (RULE_LONG_PARAGRAPH, counted))


target_display = []
for p in paths:
    display, text = read_source(p)
    target_display.append(display)
    if text is None:
        continue
    stream = mask_comments(display, text) if mode == 'comments' else mask_prose(text)
    process_blocks(display, build_blocks(stream))

flags.sort(key=lambda f: (f[0], f[1], f[2]))

shown = flags if max_flags <= 0 else flags[:max_flags]
for path, line, message in shown:
    print('FLAG %s:%s: %s' % (path, line, message))
if max_flags > 0 and len(flags) > max_flags:
    print('plain-language-lint: output truncated at %d of %d flag(s) (--max-flags %d)'
          % (max_flags, len(flags), max_flags))

target = ', '.join(target_display)
if flags:
    print('plain-language-lint: %d flag(s) (%s: %s)' % (len(flags), mode, target))
    sys.exit(1)
print('plain-language-lint: ok (%s: %s)' % (mode, target))
PY

#!/usr/bin/env python3
"""Merge review: what a developer's branch changes, and whether it stays in their area.

Reads git only. No checkout, no merge, no fetch: nothing is written to the
repository. Who owns what lives in owners.ini next to this file.

Examples, from the ephem-deploy folder:
  python3 scripts/merge-review/merge_review.py -i 1 origin/18_emt_v2
  python3 scripts/merge-review/merge_review.py -i 1 origin/18_ephem_2_cmp_all --db ephem_1
  python3 scripts/merge-review/merge_review.py --repo odca3/ephem_uganda --target main origin/main

The report has seven parts: where the changes are (by owner), findings,
new modules, hooks into other modules, the merge itself (files changed on
both sides), what to update afterwards, and the commits. A verdict line on
top sums it up: GREEN (only the developer's own area, nothing risky found),
AMBER (read the listed items), RED (the branch reaches platform modules or
another developer's modules, or a high finding).
"""
import argparse
import ast
import configparser
import csv
import fnmatch
import io
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DEPLOY_ROOT = os.path.dirname(os.path.dirname(HERE))

SEV_ORDER = {'high': 0, 'medium': 1, 'low': 2, 'info': 3}
TEXT_EXT = ('.py', '.xml', '.csv', '.js', '.scss', '.css', '.html', '.json', '.txt', '.cfg', '.conf',
            '.sh', '.yml', '.yaml', '.ini', '.sql')
MAX_SCAN_BYTES = 1_000_000
BIG_FILE = 2_000_000

# Methods whose override changes what every user of a model can see or do.
ACCESS_METHODS = {
    'check_access', 'check_access_rule', 'check_access_rights', '_check_access', 'has_access',
    '_filtered_access', '_search', 'search', 'search_fetch', 'search_read', 'search_count', 'read',
    'web_read', 'web_search_read', '_read_group', 'read_group', 'name_search', '_name_search',
    '_register_hook', 'init', '_auto_init', 'fields_get', 'get_views', '_get_view',
}
WRITE_METHODS = {'create', 'write', 'unlink', 'copy', 'default_get', 'name_create', 'web_save',
                 'toggle_active', 'action_archive', 'action_unarchive', 'load', 'export_data'}
# Odoo's own methods: a super() call to them always lands somewhere.
ODOO_METHODS = ACCESS_METHODS | WRITE_METHODS | {
    '_compute_display_name', 'onchange', 'message_post', '_message_post_after_hook', '_track_subtype',
    '_notify_get_recipients', '_creation_subtype', '_get_report_values', '_render_qweb_html',
    '_render_qweb_pdf', '_get_rendering_context', 'get_formview_action', 'get_formview_id',
    '_valid_field_parameter', '_setup_fields', 'name_get', 'execute', 'set_values', 'get_values',
    'action_open', '_get_default_access_link', 'message_subscribe', '_message_get_suggested_recipients',
    'copy_data', '_compute_access_url', '_get_access_action', 'unlink_except', 'flush_model',
}
# Odoo's own plumbing: an override here reaches every module on the database.
INFRA_HIGH = {'ir.http', 'ir.rule', 'ir.ui.menu', 'ir.model.access', 'ir.qweb', 'base', 'ir.ui.view',
              'ir.actions.actions', 'ir.actions.act_window', 'ir.actions.server', 'ir.module.module'}
INFRA_MEDIUM = {'res.users', 'res.partner', 'res.company', 'res.groups', 'mail.thread', 'mail.mail', 'mail.message',
                'mail.activity', 'ir.attachment', 'ir.cron', 'ir.config_parameter', 'res.config.settings'}
SENSITIVE_RECORD_MODELS = {
    'ir.rule', 'ir.model.access', 'res.groups', 'ir.ui.menu', 'ir.config_parameter', 'res.users.role',
    'ir.actions.act_window', 'ir.actions.server', 'ir.cron', 'res.users', 'res.company', 'mail.template',
    'res.partner', 'ir.ui.view',
}
JUNK_PATHS = ['*__pycache__*', '*.pyc', '.idea/*', '*/.idea/*', '.vscode/*', '*node_modules/*', '*.env',
              '.env*', '*.log', '*.DS_Store', '*.dump', '*.backup', '*.bak', '*.sqlite', '*.zip',
              '*.tar.gz', '.claude/*', '*/.claude/*', '*.orig', '*.rej']

# Functions the house patterns call from data files (roles delegation and the like).
HOUSE_FUNCTIONS = {'_ephem_set_delegation'}

HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')


# ------------------------------------------------------------------ git
class Git:
    def __init__(self, repo):
        self.repo = repo

    def _cmd(self, args):
        return ['git', '-c', 'core.quotepath=off', '-C', self.repo] + list(args)

    def run(self, *args, check=True):
        r = subprocess.run(self._cmd(args), capture_output=True)
        if check and r.returncode:
            sys.exit('git %s: %s' % (' '.join(args[:3]), r.stderr.decode(errors='replace').strip()))
        return r.stdout.decode('utf-8', errors='replace')

    def ok(self, *args):
        return subprocess.run(self._cmd(args), capture_output=True).returncode == 0

    def show(self, ref, path):
        r = subprocess.run(self._cmd(['show', '%s:%s' % (ref, path)]), capture_output=True)
        return r.stdout.decode('utf-8', errors='replace') if r.returncode == 0 else None

    def sha(self, ref):
        return self.run('rev-parse', '--verify', '--quiet', ref + '^{commit}', check=False).strip() or None

    def tree(self, ref):
        """{path: size} of every file at ref."""
        out = {}
        for entry in self.run('ls-tree', '-r', '-l', '-z', ref).split('\0'):
            if '\t' not in entry:
                continue
            meta, path = entry.split('\t', 1)
            parts = meta.split()
            out[path] = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else 0
        return out


def chunks(seq, n):
    seq = list(seq)
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


# ------------------------------------------------------------------ owners.ini
def _list(value):
    out = []
    for line in (value or '').replace(',', '\n').splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            out.append(line)
    return out


class Profile:
    def __init__(self, key, sec):
        self.key = key
        self.name = sec.get('name', key)
        self.focus = sec.get('focus', '')
        self.authors = [a.lower() for a in _list(sec.get('authors'))]
        self.branches = _list(sec.get('branches'))
        self.owns = _list(sec.get('owns'))
        self.also = _list(sec.get('also'))
        self.own_repos = _list(sec.get('own_repos'))

    def is_author(self, name, email):
        return name.lower() in self.authors or email.lower() in self.authors


def load_owners(path):
    cp = configparser.ConfigParser(interpolation=None)
    if not cp.read(path, encoding='utf-8'):
        sys.exit('owners file not found: %s' % path)
    core = cp['core'] if cp.has_section('core') else {}
    return {
        'protected': _list(core.get('protected')),
        'shared': _list(core.get('shared')),
        'quiet': _list(core.get('quiet_paths')),
        'team': [a.lower() for a in _list(core.get('team_authors'))],
        'ai': [a.lower() for a in _list(core.get('ai_authors'))],
        'profiles': {s.split(':', 1)[1]: Profile(s.split(':', 1)[1], cp[s])
                     for s in cp.sections() if s.startswith('dev:')},
    }


def matches(patterns, path):
    top = path.split('/', 1)[0]
    for p in patterns:
        if '/' in p:
            if fnmatch.fnmatchcase(path, p):
                return True
        elif fnmatch.fnmatchcase(top, p):
            return True
    return False


# ------------------------------------------------------------------ helpers
def repo_name(git):
    url = git.run('remote', 'get-url', 'origin', check=False).strip()
    if url:
        return re.sub(r'\.git$', '', re.split(r'[/:]', url.rstrip('/'))[-1])
    return os.path.basename(os.path.abspath(git.repo))


def parse_manifest(src):
    if src is None:
        return None
    try:
        value = ast.literal_eval(src.strip())
        return value if isinstance(value, dict) else {}
    except Exception:
        try:
            for node in reversed(ast.parse(src).body):
                if isinstance(node, ast.Expr) and isinstance(node.value, ast.Dict):
                    return ast.literal_eval(node.value)
        except Exception:
            pass
    return {}


def version_tuple(v):
    nums = [int(x) for x in re.findall(r'\d+', str(v or ''))]
    if len(nums) >= 5 and nums[:2] == [18, 0]:
        nums = nums[2:]
    return tuple(nums)


def ago(seconds):
    if seconds < 3600:
        return '%d min' % (seconds // 60)
    if seconds < 86400 * 2:
        return '%d h' % (seconds // 3600)
    return '%d days' % (seconds // 86400)


def short(text, n=150):
    text = ' '.join(text.strip().split())
    return text if len(text) <= n else text[:n - 3] + '...'


def module_of(path):
    return path.split('/', 1)[0] if '/' in path else None


# ------------------------------------------------------------------ the review
class Review:
    def __init__(self, args):
        self.args = args
        self.git = Git(args.repo)
        self.owners = load_owners(args.owners)
        self.findings = []
        self.notes = []
        self.repo = repo_name(self.git)

    # ---------------------------------------------------------- findings
    def add(self, sev, rule, path, line, what, why=''):
        self.findings.append({'sev': sev, 'rule': rule, 'file': path, 'line': line,
                              'what': what, 'why': why})

    # ---------------------------------------------------------- refs
    def resolve_refs(self):
        g, a = self.git, self.args
        self.source = a.source
        self.src_sha = g.sha(a.source)
        if not self.src_sha:
            sys.exit('unknown source ref: %s (fetch first? the agent shell cannot reach GitHub)' % a.source)
        self.target = a.target or g.run('symbolic-ref', '--short', '-q', 'HEAD', check=False).strip() or 'HEAD'
        self.tgt_sha = g.sha(self.target)
        if not self.tgt_sha:
            sys.exit('unknown target ref: %s' % self.target)
        self.base = g.run('merge-base', self.tgt_sha, self.src_sha, check=False).strip()
        if not self.base:
            sys.exit('no common history between %s and %s' % (self.target, a.source))
        # local branch against its origin copy, both ways
        for ref in (a.source, self.target):
            name = ref[len('origin/'):] if ref.startswith('origin/') else ref
            other = name if ref.startswith('origin/') else 'origin/' + name
            osha, rsha = g.sha(other), g.sha(ref)
            if osha and rsha and osha != rsha:
                ahead = int(g.run('rev-list', '--count', '%s..%s' % (other, ref)).strip() or 0)
                behind = int(g.run('rev-list', '--count', '%s..%s' % (ref, other)).strip() or 0)
                self.notes.append('%s differs from %s: %d commits only in %s, %d only in %s.'
                                  % (ref, other, ahead, ref, behind, other))
        fh = g.run('rev-parse', '--git-path', 'FETCH_HEAD', check=False).strip()
        if fh and not os.path.isabs(fh):
            fh = os.path.join(a.repo, fh)
        self.fetch_age = (time.time() - os.path.getmtime(fh)) if fh and os.path.exists(fh) else None

    def commit_info(self, sha):
        out = self.git.run('log', '-1', '--format=%h%x1f%ci%x1f%an%x1f%s', sha).strip().split('\x1f')
        return {'sha': out[0], 'date': out[1][:16], 'author': out[2], 'subject': out[3]}

    # ---------------------------------------------------------- commits and profile
    def load_commits(self):
        raw = self.git.run('log', '--format=%h%x1f%an%x1f%ae%x1f%ci%x1f%P%x1f%s',
                           '%s..%s' % (self.tgt_sha, self.src_sha))
        self.commits = []
        for line in raw.splitlines():
            parts = line.split('\x1f')
            if len(parts) == 6:
                self.commits.append({'sha': parts[0], 'author': parts[1], 'email': parts[2],
                                     'date': parts[3][:16], 'merge': len(parts[4].split()) > 1,
                                     'subject': parts[5]})
        self.target_ahead = int(self.git.run('rev-list', '--count',
                                             '%s..%s' % (self.base, self.tgt_sha)).strip() or 0)

    def pick_profile(self):
        profiles = self.owners['profiles']
        a = self.args
        self.profile, self.profile_reason = None, ''
        if a.dev:
            if a.dev not in profiles:
                sys.exit('no [dev:%s] in %s (have: %s)' % (a.dev, a.owners, ', '.join(profiles)))
            self.profile, self.profile_reason = profiles[a.dev], 'given with --dev'
            return
        for p in profiles.values():
            if self.repo in p.own_repos:
                self.profile, self.profile_reason = p, 'owns the %s repository' % self.repo
                return
        name = a.source[len('origin/'):] if a.source.startswith('origin/') else a.source
        for p in profiles.values():
            if any(fnmatch.fnmatchcase(name, b) for b in p.branches):
                self.profile, self.profile_reason = p, 'branch name %s' % name
                return
        votes = Counter()
        for c in self.commits:
            for p in profiles.values():
                if p.is_author(c['author'], c['email']):
                    votes[p.key] += 1
        if votes:
            key = votes.most_common(1)[0][0]
            self.profile, self.profile_reason = profiles[key], 'most commits (%d)' % votes[key]

    def author_label(self, name, email):
        if self.profile and self.profile.is_author(name, email):
            return self.profile.name
        low = (name.lower(), email.lower())
        if any(x in self.owners['team'] for x in low):
            return 'ePHEM team'
        if any(x in self.owners['ai'] for x in low):
            return 'AI session'
        for p in self.owners['profiles'].values():
            if p.is_author(name, email):
                return 'other developer: ' + p.name
        return 'unknown author'

    # ---------------------------------------------------------- files
    def load_files(self):
        g = self.git
        self.base_tree = g.tree(self.base)
        self.src_tree = g.tree(self.src_sha)
        self.tgt_tree = g.tree(self.tgt_sha)
        man = re.compile(r'^[^/]+/__manifest__\.py$')
        self.base_mods = {p.split('/')[0] for p in self.base_tree if man.match(p)}
        self.src_mods = {p.split('/')[0] for p in self.src_tree if man.match(p)}
        self.tgt_mods = {p.split('/')[0] for p in self.tgt_tree if man.match(p)}
        status = g.run('diff', '--no-renames', '--name-status', '-z', self.base, self.src_sha).split('\0')
        self.files = {}
        it = iter(status)
        for st in it:
            if not st:
                continue
            path = next(it, '')
            self.files[path] = {'status': st[0], 'add': 0, 'del': 0, 'binary': False}
        for entry in g.run('diff', '--no-renames', '--numstat', '-z', self.base, self.src_sha).split('\0'):
            parts = entry.split('\t')
            if len(parts) == 3 and parts[2] in self.files:
                f = self.files[parts[2]]
                if parts[0] == '-':
                    f['binary'] = True
                else:
                    f['add'], f['del'] = int(parts[0]), int(parts[1])
        self.tgt_changed = set(p for p in g.run('diff', '--no-renames', '--name-only', '-z',
                                                self.base, self.tgt_sha).split('\0') if p)

    # ---------------------------------------------------------- classification
    def classify(self):
        """Group the changed paths by top level folder and give each group an owner class."""
        prof, own = self.profile, self.owners
        repo_owned = bool(prof and self.repo in prof.own_repos)
        groups = defaultdict(lambda: {'files': [], 'add': 0, 'del': 0})
        for path, f in self.files.items():
            top = path.split('/', 1)[0] if '/' in path else path
            g = groups[top]
            g['files'].append(path)
            g['add'] += f['add']
            g['del'] += f['del']
        self.groups = {}
        for top, g in sorted(groups.items()):
            is_mod = top in self.src_mods or top in self.base_mods
            new = top in self.src_mods and top not in self.base_mods
            deleted = top in self.base_mods and top not in self.src_mods
            first = g['files'][0]
            probe = top if is_mod else first
            if matches(own['protected'], probe):
                cls = 'core'
            elif repo_owned or (prof and matches(prof.owns, probe)):
                cls = 'own'
            elif prof and matches(prof.also, probe):
                cls = 'own-other'
            else:
                other = next((p for p in own['profiles'].values() if p is not prof
                              and (matches(p.owns, probe) or matches(p.also, probe)
                                   or (is_mod and self.repo in p.own_repos))), None)
                if other:
                    cls = 'other:' + other.name
                elif new:
                    cls = 'new'
                elif not is_mod and matches(own['quiet'], probe):
                    cls = 'docs'
                elif matches(own['shared'], probe):
                    cls = 'shared'
                elif is_mod:
                    cls = 'unassigned'
                else:
                    cls = 'path'
            i18n_only = all('/i18n/' in p for p in g['files'])
            self.groups[top] = dict(g, top=top, cls=cls, module=is_mod, new=new, deleted=deleted,
                                    i18n_only=i18n_only)
            if deleted:
                self.add('high', 'module-deleted', top + '/__manifest__.py', None,
                         'module %s is deleted by the branch' % top,
                         'databases that have it installed lose its code at the next update')
        # what counts as the developer's own when judging hooks into other modules
        mods = self.tgt_mods | self.src_mods
        self.mine = set()
        if repo_owned:
            self.mine = set(mods)
        elif prof:
            self.mine = {m for m in mods if (matches(prof.owns, m) or matches(prof.also, m))
                         and not matches(own['protected'], m)}
        self.mine |= {t for t, g in self.groups.items() if g['new'] and g['cls'] in ('own', 'own-other', 'new')}

    def foreign_module(self, module):
        return bool(module) and module not in self.mine

    # ---------------------------------------------------------- model map
    def build_model_map(self):
        """model -> modules that declare it with _name, in the target and the branch."""
        self.model_defs = defaultdict(set)
        pat = r"^\s+_name\s*=\s*['\"][A-Za-z0-9_.]+['\"]"
        sources = [(self.git, ref) for ref in {self.tgt_sha, self.src_sha}]
        if self.args.core and os.path.isdir(self.args.core):
            sources.append((Git(self.args.core), 'HEAD'))
        for g, ref in sources:
            out = g.run('grep', '-n', '-E', pat, ref, '--', '*.py', check=False)
            for line in out.splitlines():
                parts = line.split(':', 3)
                if len(parts) < 4:
                    continue
                m = re.search(r"['\"]([A-Za-z0-9_.]+)['\"]", parts[3])
                mod = module_of(parts[1])
                if m and mod:
                    self.model_defs[m.group(1)].add(mod)
        self.model_by_ref = {m.replace('.', '_'): m for m in self.model_defs}

    def model_foreign(self, model):
        defs = self.model_defs.get(model, set())
        return (not defs) or bool(defs - self.mine)

    def model_owner_text(self, model):
        defs = self.model_defs.get(model, set())
        defs = sorted(defs - self.mine) or sorted(defs)
        return ', '.join(defs[:3]) if defs else 'Odoo'

    def ref_to_model(self, ref):
        tail = ref.split('.')[-1]
        tail = tail[len('model_'):] if tail.startswith('model_') else tail
        return self.model_by_ref.get(tail) or tail.replace('_', '.')

    # ---------------------------------------------------------- added lines
    def load_added(self):
        wanted = []
        for path, f in self.files.items():
            if f['status'] == 'D' or f['binary'] or not path.endswith(TEXT_EXT):
                continue
            if self.src_tree.get(path, 0) > MAX_SCAN_BYTES:
                continue
            wanted.append(path)
        self.added = defaultdict(list)
        for chunk in chunks(wanted, 150):
            diff = self.git.run('diff', '--no-renames', '--no-color', '-U0', self.base, self.src_sha, '--', *chunk)
            path, ln, header = None, 0, False
            for line in diff.split('\n'):
                if line.startswith('diff --git '):
                    header, path = True, None
                    continue
                if header:
                    if line.startswith('+++ '):
                        path = line[6:] if line.startswith('+++ b/') else None
                    elif line.startswith('@@'):
                        header = False
                    else:
                        continue
                m = HUNK.match(line)
                if m:
                    ln = int(m.group(1))
                    continue
                if path and line.startswith('+'):
                    self.added[path].append((ln, line[1:]))
                    ln += 1

    # ---------------------------------------------------------- line rules
    def scan_lines(self):
        self.sudo_counts = Counter()
        self.colour_counts = Counter()
        mine = self.mine
        for path, lines in self.added.items():
            mod = module_of(path)
            ext = os.path.splitext(path)[1]
            in_migration = '/migrations/' in path
            in_tests = '/tests/' in path
            quiet = (not mod or mod not in self.src_mods | self.base_mods) and matches(self.owners['quiet'], path)
            for ln, text in lines:
                s = text.strip()
                if not s:
                    continue
                # secrets, every text file
                if re.search(r'-----BEGIN [A-Z ]*PRIVATE KEY-----', text) or re.search(
                        r'\b(sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}'
                        r'|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35})', text):
                    self.add('high', 'secret', path, ln, short(text), 'a key or token in the repository')
                elif not in_tests and ext in ('.py', '.json', '.yml', '.yaml', '.ini', '.cfg', '.conf', '.sh') \
                        and re.search(r"(?i)\b(password|passwd|api_?key|secret|token)\b\s*[:=]\s*['\"][^'\"\s]{6,}['\"]", text) \
                        and not re.search(r'fields\.|string=|help=|placeholder|_\(|_lt\(|example|xxx|changeme', text):
                    self.add('medium', 'secret?', path, ln, short(text), 'looks like a hard coded credential')
                if re.search(r'https?://[^"\' )]*(cdn\.|unpkg\.com|jsdelivr|cdnjs|googleapis\.com|bootstrapcdn|'
                             r'fontawesome\.com|gstatic\.com)', text) and ext in ('.js', '.xml', '.scss', '.css', '.html', '.py'):
                    self.add('medium', 'cdn', path, ln, short(text),
                             'ePHEM runs offline in trainings and on closed networks: no CDN assets')
                if re.search(r'\b(pdb\.set_trace|breakpoint)\(\)|^\s*import pdb', text) and ext == '.py':
                    self.add('medium', 'debugger', path, ln, short(text), 'stops the server process')
                if in_tests or quiet:
                    continue
                if ext == '.py' and not s.startswith('#'):
                    self._py_line(path, mod, ln, text, in_migration)
                elif ext == '.xml':
                    if 'ephem_staff_baseline' in text:
                        self.add('medium', 'staff-baseline', path, ln, short(text),
                                 'adds to the baseline role every internal user holds')
                    if re.search(r'\bt-inherit="([\w.]+)\.', text):
                        tmod = re.search(r'\bt-inherit="([\w.]+?)\.', text).group(1)
                        if self.foreign_module(tmod) and 't-inherit-mode="primary"' not in text:
                            self.add('medium', 'owl-template-extension', path, ln, short(text),
                                     'changes a template of %s for every user once this module is installed' % tmod)
                elif ext == '.js':
                    if re.search(r'\.add\([^)]*force\s*:\s*true', text):
                        self.add('medium', 'registry-force', path, ln, short(text),
                                 'replaces an entry another module registered')
                    if re.search(r'registry\.category\([^)]*\)\.remove\(', text):
                        self.add('medium', 'registry-remove', path, ln, short(text),
                                 'removes an entry another module registered')
                elif ext in ('.scss', '.css'):
                    for m in ([] if ('#{' in text or 'unquote(' in text) else re.finditer(r'\b(min|max)\(([^()]*)\)', text)):
                        units = set(re.findall(r'\d(px|rem|em|vw|vh|%)', m.group(2)))
                        if len(units) > 1:
                            self.add('high', 'scss-mixed-min-max', path, ln, short(text),
                                     'libsass evaluates mixed unit min()/max() and the whole CSS bundle dies')
                    if re.match(r'^(body|html|:root|\*|\.modal\b|\.btn\b|\.dropdown|\.table\b|\.form-control|\.navbar|'
                                r'a\b|h[1-6]\b|input\b|select\b|textarea\b|\.o_(form|list|kanban|main_navbar|'
                                r'control_panel|web_client|action_manager|content|field|notebook|statusbar|cp_|searchview|'
                                r'search_panel|menu|navbar|dialog|popover|dropdown|calendar|pivot|graph|mail|chatter|'
                                r'home_menu|app|inner_group|group|input|datetime|notification|technical_modal|data_row|'
                                r'list_renderer|kanban_renderer)\b)', text) and not self._scoped_selector(text):
                        self.add('medium', 'global-css', path, ln, short(text),
                                 'top level selector: restyles every backend page once the bundle loads')
                    self.colour_counts[path] += len(re.findall(r'#[0-9a-fA-F]{3,8}\b', text))
                if re.search(r'(?i)\b(DROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT|VIEW)|TRUNCATE\s|DELETE\s+FROM)\b', text) \
                        and ext in ('.py', '.sql'):
                    sev = 'high' if (in_migration or self.foreign_module(mod)) else 'medium'
                    self.add(sev, 'destructive-sql', path, ln, short(text), 'deletes data or structure')
        if self.sudo_counts:
            for path, n in self.sudo_counts.most_common():
                self.add('info', 'sudo-count', path, None, '%d added sudo() call(s)' % n,
                         'each one must follow an access check on the one record it touches')

    @staticmethod
    def _scoped_selector(text):
        """True when the selector names a class of its own (not one of Odoo's or Bootstrap's)."""
        sel = text.split('{', 1)[0]
        core = re.compile(r'^o_(form|list|kanban|main_navbar|control_panel|web_client|action_manager|action|content|'
                          r'field|notebook|statusbar|cp_|searchview|search_panel|menu|navbar|dialog|popover|dropdown|'
                          r'calendar|pivot|graph|mail|chatter|home_menu|app|inner_group|group|input|datetime|'
                          r'notification|technical_modal|data_row|list_renderer|kanban_renderer)')
        classes = re.findall(r'\.([A-Za-z][\w-]*)', sel)
        return any(c.startswith('o_') and not core.match(c) for c in classes)

    def _py_line(self, path, mod, ln, text, in_migration):
        if '.sudo()' in text:
            self.sudo_counts[path] += text.count('.sudo()')
            if re.search(r"\.sudo\(\)\.(search|search_read|read_group|_read_group|search_count|search_fetch)\(", text):
                self.add('medium' if self.foreign_module(mod) else 'low', 'sudo-search', path, ln, short(text),
                         'a search as superuser ignores record rules: who sees the result?')
        if re.search(r"auth\s*=\s*['\"](public|none)['\"]", text):
            self.add('high', 'public-route', path, ln, short(text), 'reachable without logging in')
        if re.search(r'csrf\s*=\s*False', text):
            self.add('medium', 'csrf-off', path, ln, short(text), 'no CSRF check on this route')
        if re.search(r'\bcors\s*=', text):
            self.add('medium', 'cors', path, ln, short(text), 'other web sites may call this route')
        if re.search(r"\.execute\(\s*f['\"]|\.execute\([^)]*['\"]\s*%\s*[\w(]|\.execute\([^)]*\.format\(", text):
            self.add('high', 'sql-format', path, ln, short(text), 'SQL built by string formatting')
        if re.search(r'(?<![\w.])(eval|exec)\(', text):
            self.add('high', 'eval', path, ln, short(text), 'runs a string as code')
        if re.search(r'\bsubprocess\b|os\.system\(|os\.popen\(', text):
            self.add('high', 'shell', path, ln, short(text), 'runs a program on the server')
        if re.search(r'\brequests\.(get|post|put|patch|delete|request|Session)\b|urllib\.request|urlopen\(|http\.client',
                     text):
            self.add('medium', 'outbound-call', path, ln, short(text),
                     'calls another server: timeout, credentials, offline behaviour')
        m = re.search(r"set_param\(\s*['\"]([\w.]+)['\"]", text)
        if m and self.foreign_module(m.group(1).split('.')[0]) and m.group(1).split('.')[0] != mod:
            self.add('medium', 'foreign-setting', path, ln, short(text),
                     'writes a setting %s does not own (applies to the whole database)' % (mod or 'this file'))
        m = re.search(r"env\.ref\(\s*['\"](\w+)\.[\w.]+['\"][^)]*\)\s*(\.sudo\(\))?\.(write|unlink|toggle_active|"
                      r"action_archive)\(", text)
        if m and self.foreign_module(m.group(1)) and m.group(1) != mod:
            self.add('high', 'foreign-record-write', path, ln, short(text),
                     'changes a record that %s owns' % m.group(1))
        if re.search(r'^\s*(odoo\.)?(models|fields|api|http)\.[A-Z]\w*(\.\w+)+\s*=(?!=)', text) or \
                re.search(r'setattr\(\s*(odoo\.|models\.|fields\.|http\.)', text):
            self.add('high', 'monkey-patch', path, ln, short(text), 'patches Odoo itself, for every module and database')

    # ---------------------------------------------------------- python structure
    def scan_python(self):
        self.hooks = []
        supers = defaultdict(list)
        for path, f in self.files.items():
            if f['status'] == 'D' or not path.endswith('.py') or not module_of(path):
                continue
            src = self.git.show(self.src_sha, path)
            if src is None:
                continue
            new_file = f['status'] == 'A'
            added = {ln for ln, _ in self.added.get(path, [])}
            try:
                tree = ast.parse(src)
            except SyntaxError as e:
                self.add('high', 'python-syntax', path, e.lineno, 'does not parse: %s' % e.msg,
                         'the module cannot load: every database that has it fails to start')
                continue
            for node in ast.walk(tree):
                if not isinstance(node, ast.ClassDef):
                    continue
                name_val, inherits = None, []
                for st in node.body:
                    if isinstance(st, ast.Assign) and len(st.targets) == 1 and isinstance(st.targets[0], ast.Name):
                        t = st.targets[0].id
                        if t == '_name' and isinstance(st.value, ast.Constant):
                            name_val = st.value.value
                        elif t == '_inherit':
                            if isinstance(st.value, ast.Constant) and isinstance(st.value.value, str):
                                inherits = [st.value.value]
                            elif isinstance(st.value, (ast.List, ast.Tuple)):
                                inherits = [e.value for e in st.value.elts if isinstance(e, ast.Constant)]
                if not inherits or (name_val and name_val not in inherits):
                    continue
                models = [name_val] if name_val else inherits
                foreign = [m for m in models if self.model_foreign(m)]
                if not foreign:
                    continue
                cls_span = set(range(node.lineno, (node.end_lineno or node.lineno) + 1))
                if not (new_file or cls_span & added):
                    continue
                methods, fields_added = [], []
                for st in node.body:
                    span = set(range(st.lineno, (getattr(st, 'end_lineno', None) or st.lineno) + 1))
                    touched = new_file or bool(span & added)
                    if isinstance(st, (ast.FunctionDef, ast.AsyncFunctionDef)) and touched:
                        calls = {c.func.attr for c in ast.walk(st)
                                 if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute)
                                 and isinstance(c.func.value, ast.Call) and isinstance(c.func.value.func, ast.Name)
                                 and c.func.value.func.id == 'super'}
                        methods.append({'name': st.name, 'line': st.lineno, 'super': st.name in calls})
                    elif isinstance(st, ast.Assign) and touched and isinstance(st.value, ast.Call) \
                            and isinstance(st.value.func, ast.Attribute) \
                            and isinstance(st.value.func.value, ast.Name) and st.value.func.value.id == 'fields':
                        fields_added += [t.id for t in st.targets if isinstance(t, ast.Name)]
                hook = {'file': path, 'line': node.lineno, 'models': foreign, 'methods': methods,
                        'fields': fields_added}
                self.hooks.append(hook)
                for meth in methods:
                    label = '%s.%s()' % ('/'.join(foreign), meth['name'])
                    owner = ', '.join(self.model_owner_text(m) for m in foreign)
                    infra = [m for m in foreign if m in INFRA_HIGH or m in INFRA_MEDIUM]
                    if meth['name'] in ACCESS_METHODS:
                        self.add('high', 'override-access', path, meth['line'], 'overrides %s (model of %s)' % (label, owner),
                                 'changes what every user of another module\'s model can see, once installed')
                    elif infra and meth['super']:
                        sev = 'high' if any(m in INFRA_HIGH for m in infra) else 'medium'
                        self.add(sev, 'override-odoo-core', path, meth['line'], 'overrides %s' % label,
                                 'Odoo plumbing every module goes through: menus, rules, requests, users')
                    elif meth['name'] in WRITE_METHODS:
                        self.add('medium', 'override-write', path, meth['line'], 'overrides %s (model of %s)' % (label, owner),
                                 'runs on every save of another module\'s model, once installed')
                    if meth['super'] and meth['name'] not in ODOO_METHODS \
                            and any(self.model_defs.get(m) for m in foreign):
                        supers[meth['name']].append((path, meth['line'], label))
        self._check_supers(supers)

    def _check_supers(self, supers):
        """A super() call to a method no other module defines is a dead hook (renamed on the target)."""
        if not supers:
            return
        found = set()
        refs = [(self.git, self.tgt_sha)]
        if self.args.core and os.path.isdir(self.args.core):
            refs.append((Git(self.args.core), 'HEAD'))
        for g, ref in refs:
            for chunk in chunks(sorted(supers), 40):
                pat = r'def (%s)\(' % '|'.join(re.escape(n) for n in chunk)
                out = g.run('grep', '-n', '-E', pat, ref, '--', '*.py', check=False)
                for line in out.splitlines():
                    parts = line.split(':', 3)
                    if len(parts) < 4:
                        continue
                    mod = module_of(parts[1])
                    m = re.search(pat, parts[3])
                    if m and (g is not self.git or mod not in self.mine):
                        found.add(m.group(1))
        missing = [n for n in supers if n not in found]
        odoo_found, odoo_checked = self._odoo_defines(missing)
        for name, places in supers.items():
            if name not in found and name not in odoo_found:
                for path, line, label in places:
                    self.add('medium' if odoo_checked else 'low', 'dead-super', path, line, '%s calls super() but no other module on %s '
                             'defines %s' % (label, self.target, name),
                             'renamed or removed on the target: the hook never runs, or raises')

    def _odoo_defines(self, names):
        """Which of these method names Odoo itself defines, read in a running instance container."""
        if not names:
            return set(), True
        pat = 'def (%s)\\(' % '|'.join(re.escape(n) for n in names)
        script = ('d=$(python3 -c "import odoo,os;print(os.path.dirname(odoo.__file__))" 2>/dev/null) && '
                  'grep -rhoE "%s" "$d" --include=*.py' % pat)
        for container in self.args.odoo_container:
            r = subprocess.run(['docker', 'exec', container, 'sh', '-c', script], capture_output=True, text=True)
            if r.returncode in (0, 1) and 'No such container' not in r.stderr and 'Error' not in r.stderr:
                return {m.group(1) for m in re.finditer(r'def (\w+)\(', r.stdout)}, True
        self.notes.append('Odoo source not reachable (no running instance container): dead-super findings are unverified.')
        return set(), False

    # ---------------------------------------------------------- xml structure
    def scan_xml(self):
        for path, f in self.files.items():
            if f['status'] == 'D' or not path.endswith('.xml') or not module_of(path):
                continue
            if '/static/' in path and '/views/' not in path:
                continue  # OWL templates: covered by the line rules
            src = self.git.show(self.src_sha, path)
            if src is None:
                continue
            mod = module_of(path)
            new_file = f['status'] == 'A'
            added_text = '\n'.join(t for _, t in self.added.get(path, []))
            try:
                root = ET.fromstring(src.encode('utf-8'))
            except ET.ParseError as e:
                self.add('high', 'xml-syntax', path, None, 'does not parse: %s' % e,
                         'the module cannot install or update')
                continue

            def is_added(*needles):
                return new_file or any(n and n in added_text for n in needles)

            for el in root.iter():
                tag = el.tag
                if tag == 'record':
                    rid, model = el.get('id', ''), el.get('model', '')
                    if not is_added('id="%s"' % rid, "id='%s'" % rid):
                        continue
                    if '.' in rid and rid.split('.')[0] != mod and self.foreign_module(rid.split('.')[0]):
                        sev = 'high' if model in SENSITIVE_RECORD_MODELS else 'medium'
                        self.add(sev, 'foreign-record', path, None, 'writes %s (%s)' % (rid, model),
                                 'changes a record %s owns, on every database where this installs'
                                 % rid.split('.')[0])
                    if model == 'ir.rule':
                        self._rule(path, el, rid)
                    if model == 'res.groups':
                        for fld in el.findall('field'):
                            if fld.get('name') in ('users', 'user_ids'):
                                refs = set(re.findall(r"ref\(['\"]([\w.]+)['\"]\)", fld.get('eval', '')))
                                only_admin = refs and refs <= {'base.user_root', 'base.user_admin'}
                                self.add('low' if only_admin else 'medium', 'group-users', path, None,
                                         'group %s lists users directly%s' % (rid, ' (admin only)' if only_admin else ''),
                                         'people get roles, never raw groups')
                elif tag == 'delete':
                    if is_added('<delete'):
                        self.add('high', 'xml-delete', path, None,
                                 'deletes %s' % (el.get('id') or el.get('search') or '?'),
                                 'removes records at install or update')
                elif tag == 'function':
                    if is_added('name="%s"' % el.get('name', '')):
                        self.add('info' if el.get('name') in HOUSE_FUNCTIONS else 'medium', 'xml-function', path, None,
                                 'calls %s.%s at install/update' % (el.get('model'), el.get('name')),
                                 'code that runs on every update of the module: read it')
                elif tag == 'menuitem':
                    mid = el.get('id', '')
                    if not is_added('id="%s"' % mid):
                        continue
                    if not el.get('parent') and not el.get('groups'):
                        self.add('medium', 'menu-root-open', path, None, 'top menu %s has no groups' % mid,
                                 'shown to every internal user')

    def _rule(self, path, el, rid):
        ref, has_groups, global_flag = '', False, None
        for fld in el.findall('field'):
            name = fld.get('name')
            if name == 'model_id':
                ref = fld.get('ref', '')
            elif name == 'groups':
                has_groups = True
            elif name == 'global':
                global_flag = fld.get('eval', fld.text)
        model = self.ref_to_model(ref) if ref else ''
        if model and self.model_foreign(model):
            if not has_groups or str(global_flag).strip() in ('True', '1'):
                self.add('high', 'global-rule-foreign', path, None,
                         'rule %s on %s applies to every user' % (rid, model),
                         'restricts or widens %s for the whole database, not only this module\'s users'
                         % self.model_owner_text(model))
            else:
                self.add('medium', 'rule-foreign', path, None, 'rule %s on %s' % (rid, model),
                         'record rule on a model of %s' % self.model_owner_text(model))

    # ---------------------------------------------------------- access csv
    def scan_acl(self):
        for path, lines in self.added.items():
            if not path.endswith('ir.model.access.csv'):
                continue
            src = self.git.show(self.src_sha, path) or ''
            header = next(csv.reader(io.StringIO(src.splitlines()[0] if src else '')), [])
            idx = {h.strip(): i for i, h in enumerate(header)}
            gi, mi = idx.get('group_id:id'), idx.get('model_id:id')
            perms = [idx.get(k) for k in ('perm_write', 'perm_create', 'perm_unlink')]
            for ln, text in lines:
                if ln == 1 or not text.strip():
                    continue
                row = next(csv.reader(io.StringIO(text)), [])
                if gi is None or len(row) <= max(gi, mi or 0):
                    continue
                group = row[gi].strip()
                writes = any(p is not None and len(row) > p and row[p].strip() == '1' for p in perms)
                model_ref = row[mi].strip() if mi is not None else ''
                model = self.ref_to_model(model_ref) if model_ref else ''
                if not group:
                    self.add('high', 'acl-everyone', path, ln, short(text),
                             'no group: every user, portal and public included')
                elif group in ('base.group_portal', 'base.group_public'):
                    self.add('high', 'acl-portal', path, ln, short(text), 'portal or public users')
                elif group == 'base.group_user' and writes:
                    self.add('medium', 'acl-all-internal', path, ln, short(text),
                             'every internal user may change these records, whatever their roles')
                if model and model in self.model_defs and self.model_foreign(model):
                    self.add('medium', 'acl-foreign-model', path, ln, short(text),
                             'access to %s, a model of %s' % (model, self.model_owner_text(model)))

    # ---------------------------------------------------------- javascript patches
    def scan_js(self):
        for path, lines in self.added.items():
            if not path.endswith('.js'):
                continue
            src = self.git.show(self.src_sha, path) or ''
            imports = {}
            for m in re.finditer(r'import\s*\{([^}]*)\}\s*from\s*["\']([^"\']+)["\']', src):
                for name in m.group(1).split(','):
                    name = name.strip().split(' as ')[-1].strip()
                    if name:
                        imports[name] = m.group(2)
            for m in re.finditer(r'import\s+(\w+)\s+from\s*["\']([^"\']+)["\']', src):
                imports[m.group(1)] = m.group(2)
            for ln, text in lines:
                m = re.search(r'\bpatch\(\s*([\w$]+)', text)
                if not m:
                    continue
                origin = imports.get(m.group(1), '')
                omod = origin[1:].split('/')[0] if origin.startswith('@') else ''
                if omod and self.foreign_module(omod):
                    self.add('medium', 'js-patch', path, ln, short(text),
                             'patches %s from %s: changes it for every user once installed' % (m.group(1), origin))

    # ---------------------------------------------------------- manifests, migrations, junk
    def scan_manifests(self):
        self.new_modules = []
        for top, g in self.groups.items():
            if not g['module'] or g['deleted']:
                continue
            mf_src = parse_manifest(self.git.show(self.src_sha, top + '/__manifest__.py')) or {}
            mf_base = parse_manifest(self.git.show(self.base, top + '/__manifest__.py'))
            mf_tgt = parse_manifest(self.git.show(self.tgt_sha, top + '/__manifest__.py'))
            path = top + '/__manifest__.py'
            deps = list(mf_src.get('depends', []))
            auto = mf_src.get('auto_install', False)
            if g['new']:
                gating = auto if isinstance(auto, list) else deps
                gate_mine = [d for d in gating if d in self.mine]
                entry = {'module': top, 'version': mf_src.get('version', ''), 'depends': deps,
                         'auto_install': bool(auto), 'application': bool(mf_src.get('application')),
                         'gate': gate_mine, 'cls': g['cls']}
                self.new_modules.append(entry)
                if auto and not gate_mine:
                    self.add('high', 'auto-install-ungated', path, None,
                             '%s installs itself on every database that has %s' % (top, ', '.join(gating) or 'base'),
                             'none of those modules belong to the developer: it lands on databases that never asked')
                self._manifest_extras(path, top, mf_src, {})
                continue
            if mf_base is None:
                continue
            added_deps = [d for d in deps if d not in mf_base.get('depends', [])]
            for d in added_deps:
                if self.foreign_module(top) and d in self.mine:
                    self.add('high', 'reverse-depends', path, None,
                             '%s now depends on %s' % (top, d), 'a platform module depending on a developer module')
                else:
                    self.add('medium', 'depends-added', path, None, '%s now depends on %s' % (top, d),
                             'updating %s installs %s on every database that has it' % (top, d))
            if not mf_base.get('auto_install') and auto:
                self.add('high', 'auto-install-on', path, None, '%s became auto_install' % top,
                         'installs itself on databases at the next update')
            vb, vs = version_tuple(mf_base.get('version')), version_tuple(mf_src.get('version'))
            vt = version_tuple((mf_tgt or {}).get('version'))
            if vs and vb and vs < vb:
                self.add('high', 'version-down', path, None,
                         '%s version goes down: %s to %s' % (top, mf_base.get('version'), mf_src.get('version')),
                         'Odoo skips migrations and data upgrades')
            if vs and vt and vt > vb and vs > vb and vs != vt:
                self.add('medium', 'version-both', path, None, '%s version bumped on both sides: target %s, branch %s'
                         % (top, mf_tgt.get('version'), mf_src.get('version')),
                         'pick the higher one when merging, and check both migration folders run')
            self._manifest_extras(path, top, mf_src, mf_base)
            mig_versions = set()
            for p in g['files']:
                m = re.match(r'^[^/]+/migrations/([^/]+)/', p)
                if m:
                    mig_versions.add(m.group(1))
            for mv in mig_versions:
                if vs and version_tuple(mv) > vs:
                    self.add('high', 'migration-never-runs', path, None,
                             'migration %s is above the manifest version %s' % (mv, mf_src.get('version')),
                             'Odoo only runs migration folders up to the manifest version')
        for path, f in self.files.items():
            if re.match(r'^[^/]+/migrations/[^/]+/(pre|post|end)-.*\.(py|sql)$', path) and f['status'] != 'D':
                mod = module_of(path)
                sev = 'high' if self.foreign_module(mod) else 'medium'
                self.add(sev, 'migration', path, None, 'migration script in %s' % mod,
                         'runs once on every production database at update: read it line by line')

    def _manifest_extras(self, path, top, mf, base):
        ext = mf.get('external_dependencies') or {}
        old = (base or {}).get('external_dependencies') or {}
        for kind, names in ext.items():
            for n in names:
                if n not in old.get(kind, []):
                    self.add('medium', 'external-dependency', path, None, '%s needs %s %s' % (top, kind, n),
                             'must be in the borrs/ephem image, or the module does not install')
        for hook in ('pre_init_hook', 'post_init_hook', 'uninstall_hook', 'post_load'):
            if mf.get(hook) and not (base or {}).get(hook):
                self.add('medium', 'install-hook', path, None, '%s has %s = %s' % (top, hook, mf.get(hook)),
                         'code that runs at install: read it')
        assets, old_assets = mf.get('assets') or {}, (base or {}).get('assets') or {}
        for bundle, entries in assets.items():
            for e in entries:
                if e in old_assets.get(bundle, []):
                    continue
                if isinstance(e, (list, tuple)) and e and e[0] in ('replace', 'remove'):
                    self.add('high', 'asset-replace', path, None, '%s: %s in %s' % (top, list(e), bundle),
                             'replaces or removes another module\'s file in a bundle')
                elif 'primary_variables' in bundle or 'secondary_variables' in bundle or '_assets_bootstrap' in bundle:
                    self.add('medium', 'asset-variables', path, None, '%s adds %s to %s' % (top, e, bundle),
                             'changes SCSS variables for the whole interface')

    def scan_paths(self):
        for path, f in self.files.items():
            if f['status'] == 'A' and any(fnmatch.fnmatchcase(path, p) for p in JUNK_PATHS):
                self.add('medium', 'junk-file', path, None, 'committed file that does not belong in the repository', '')
            size = self.src_tree.get(path, 0)
            if f['status'] != 'D' and size > BIG_FILE:
                self.add('medium', 'big-file', path, None, '%.1f MB' % (size / 1e6),
                         'stays in the history of every clone forever')

    # ---------------------------------------------------------- merge
    def check_overlap(self):
        self.overlap = sorted(set(self.files) & self.tgt_changed)
        self.conflicts = []
        if not self.overlap:
            return
        out = self.git.run('merge-tree', self.base, self.tgt_sha, self.src_sha, check=False)
        block_paths, block_conflict = set(), False
        for line in out.split('\n') + ['END']:
            if line and not line[0] in ' +-@\\':
                if block_conflict:
                    self.conflicts.extend(block_paths)
                block_paths, block_conflict = set(), False
                continue
            m = re.match(r'^  (base|our|their)\s+\d+ [0-9a-f]+ (.+)$', line)
            if m:
                block_paths.add(m.group(2))
            elif line.startswith('+<<<<<<<'):
                block_conflict = True
        self.conflicts = sorted(set(self.conflicts))

    # ---------------------------------------------------------- after the merge
    def plan_after(self):
        self.update_mods = sorted(t for t, g in self.groups.items()
                                  if g['module'] and not g['new'] and not g['deleted'] and t in self.tgt_mods)
        self.test_mods = sorted(t for t in self.update_mods
                                if any(p.startswith(t + '/tests/') for p in self.files)
                                or ('%s/tests/__init__.py' % t) in self.src_tree)
        self.installed = {}
        for db in self.args.db or []:
            r = subprocess.run(['docker', 'exec', 'ephem-db', 'psql', '-U', 'odoo', '-d', db, '-tAc',
                                "select name from ir_module_module where state = 'installed'"],
                               capture_output=True, text=True)
            self.installed[db] = set(r.stdout.split()) if r.returncode == 0 else None

    def owner_hint(self, module):
        first = self.git.run('log', '--diff-filter=A', '--format=%an', '--reverse', self.tgt_sha, '--',
                             module + '/__manifest__.py', check=False).splitlines()
        recent = Counter(self.git.run('log', '-n', '40', '--format=%an', self.tgt_sha, '--', module,
                                      check=False).split('\n'))
        recent.pop('', None)
        top = ', '.join('%s %d' % (a, n) for a, n in recent.most_common(3))
        return 'created by %s; recent commits: %s' % (first[0] if first else '?', top or 'none')

    # ---------------------------------------------------------- verdict
    def verdict(self):
        """Two answers: SCOPE (did the branch stay in the developer's area) and RISK (what the code does)."""
        counts = Counter(f['sev'] for f in self.findings)
        classes = Counter(g['cls'].split(':')[0] for g in self.groups.values())
        if classes['core'] or classes['other'] or any(g['deleted'] for g in self.groups.values()):
            scope = 'RED'
        elif classes['unassigned'] or classes['shared'] or classes['path'] or classes['new'] or self.conflicts:
            scope = 'AMBER'
        else:
            scope = 'GREEN'
        risk = 'RED' if counts['high'] else 'AMBER' if counts['medium'] else 'GREEN'
        return {'scope': scope, 'risk': risk}, counts, classes

    # ---------------------------------------------------------- run
    def run(self):
        self.resolve_refs()
        self.load_commits()
        self.pick_profile()
        self.load_files()
        self.classify()
        self.build_model_map()
        self.load_added()
        self.scan_lines()
        self.scan_python()
        self.scan_xml()
        self.scan_acl()
        self.scan_js()
        self.scan_manifests()
        self.scan_paths()
        self.check_overlap()
        self.plan_after()
        self.findings.sort(key=lambda f: (SEV_ORDER[f['sev']], f['rule'], f['file'], f['line'] or 0))

    # ---------------------------------------------------------- output
    def to_json(self):
        v, counts, classes = self.verdict()
        return {
            'repo': self.repo, 'path': self.args.repo, 'source': self.source, 'target': self.target,
            'source_commit': self.commit_info(self.src_sha), 'target_commit': self.commit_info(self.tgt_sha),
            'base_commit': self.commit_info(self.base), 'developer': self.profile.name if self.profile else None,
            'developer_reason': self.profile_reason, 'verdict': v, 'counts': dict(counts),
            'groups': [{k: g[k] for k in ('top', 'cls', 'module', 'new', 'deleted', 'i18n_only', 'add', 'del')}
                       | {'files': len(g['files'])} for g in self.groups.values()],
            'findings': self.findings, 'hooks': self.hooks, 'new_modules': self.new_modules,
            'overlap': self.overlap, 'conflicts': self.conflicts, 'update': self.update_mods,
            'tests': self.test_mods, 'installed': {k: sorted(v) if v is not None else None
                                                   for k, v in self.installed.items()},
            'commits': self.commits, 'notes': self.notes,
        }

    def print_text(self):
        a, limit = self.args, (10 ** 6 if self.args.all else self.args.max)
        v, counts, classes = self.verdict()
        p = print
        p('MERGE REVIEW  %s  into  %s   (repo %s at %s)' % (self.source, self.target, self.repo, a.repo))
        if self.profile:
            p('Developer     %s, %s%s' % (self.profile.name, self.profile_reason,
                                         ('. Focus: ' + self.profile.focus) if self.profile.focus else ''))
        else:
            p('Developer     unknown: no profile matched (use --dev). Everything outside platform modules is "unassigned".')
        for label, sha in (('Branch', self.src_sha), ('Target', self.tgt_sha), ('Base', self.base)):
            c = self.commit_info(sha)
            p('%-13s %s  %s  %s  %s' % (label, c['sha'], c['date'], c['author'], short(c['subject'], 70)))
        p('Commits       %d on the branch only, %d on the target since the base.'
          % (len(self.commits), self.target_ahead))
        if self.fetch_age is not None:
            p('Last fetch    %s ago%s' % (ago(self.fetch_age),
                                         ' (origin refs may be stale: ask the user to fetch)' if self.fetch_age > 6 * 3600 else ''))
        for n in self.notes:
            p('Note          ' + n)
        p('')
        p('SCOPE  %-5s  folders by class: %s' % (v['scope'], ', '.join('%s %d' % (k, n) for k, n in sorted(classes.items()))
                                                  or 'none'))
        p('RISK   %-5s  %d high, %d medium, %d low findings' % (v['risk'], counts['high'], counts['medium'], counts['low']))
        p('')
        # 1. where
        p('1. WHERE THE CHANGES ARE')
        order = ['core', 'other', 'unassigned', 'shared', 'path', 'new', 'own-other', 'own', 'docs']
        titles = {'core': 'PLATFORM (protected): should not change on a developer branch',
                  'other': "ANOTHER DEVELOPER'S area",
                  'unassigned': 'UNASSIGNED modules (nobody listed in owners.ini): decide whose they are',
                  'shared': 'SHARED modules: several teams build on them, read every change',
                  'path': 'OUTSIDE MODULES (scripts, root files)',
                  'new': "NEW modules outside the developer's usual names",
                  'own-other': "the developer's other modules (outside today's focus)",
                  'own': "the developer's own area", 'docs': 'documentation only'}
        bycls = defaultdict(list)
        for g in self.groups.values():
            bycls[g['cls'].split(':')[0]].append(g)
        for cls in order:
            items = bycls.get(cls)
            if not items:
                continue
            p('  %s' % titles[cls])
            for g in items[:limit if cls in ('own', 'own-other', 'docs', 'new') else 10 ** 6]:
                tags = []
                if g['new']:
                    tags.append('new')
                if g['deleted']:
                    tags.append('DELETED')
                if g['i18n_only']:
                    tags.append('translations only')
                if cls == 'other':
                    tags.append(g['cls'].split(':', 1)[1])
                line = '    %-34s %3d files  +%d -%d%s' % (g['top'], len(g['files']), g['add'], g['del'],
                                                        ('  [' + ', '.join(tags) + ']') if tags else '')
                p(line)
                if cls in ('core', 'other', 'unassigned', 'shared', 'path'):
                    if g['module'] and cls in ('unassigned', 'shared'):
                        p('      ' + self.owner_hint(g['top']))
                    for fp in g['files'][:limit]:
                        f = self.files[fp]
                        p('      %s %s  +%d -%d' % (f['status'], fp, f['add'], f['del']))
                    if len(g['files']) > limit:
                        p('      ... and %d more files' % (len(g['files']) - limit))
            if len(items) > limit and cls in ('own', 'own-other', 'docs', 'new'):
                p('    ... and %d more' % (len(items) - limit))
        p('')
        # 2. findings
        p('2. FINDINGS')
        if not [f for f in self.findings if f['sev'] != 'info']:
            p('  none beyond the information lines below')
        byrule = defaultdict(list)
        for f in self.findings:
            byrule[(f['sev'], f['rule'])].append(f)
        for (sev, rule), items in sorted(byrule.items(), key=lambda kv: (SEV_ORDER[kv[0][0]], kv[0][1])):
            p('  %-6s %s (%d)%s' % (sev.upper(), rule, len(items), ('  ' + items[0]['why']) if items[0]['why'] else ''))
            for f in items[:limit]:
                loc = '%s:%s' % (f['file'], f['line']) if f['line'] else f['file']
                p('         %s  %s' % (loc, f['what']))
            if len(items) > limit:
                p('         ... and %d more' % (len(items) - limit))
        p('')
        # 3. new modules
        p('3. NEW MODULES')
        if not self.new_modules:
            p('  none')
        for m in self.new_modules:
            how = 'application' if m['application'] else ''
            if m['auto_install']:
                how = ('bridge, installs itself with %s' % ', '.join(m['gate'])) if m['gate'] \
                    else 'AUTO INSTALL on databases with %s' % ', '.join(m['depends'])
            p('  %-30s %-8s %s  depends: %s' % (m['module'], m['version'], how or 'installed by hand',
                                               ', '.join(m['depends'])))
        p('')
        # 4. hooks
        p('4. HOOKS INTO OTHER MODULES (behaviour that changes where the developer\'s modules are installed)')
        if not self.hooks:
            p('  none')
        for h in self.hooks[:limit * 3]:
            meths = ', '.join(m['name'] + ('()' if True else '') for m in h['methods']) or 'no methods'
            flds = ('; fields: ' + ', '.join(h['fields'][:8]) + (' ...' if len(h['fields']) > 8 else '')) if h['fields'] else ''
            p('  %s:%d  extends %s (%s): %s%s' % (h['file'], h['line'], ', '.join(h['models']),
                                                 ', '.join(self.model_owner_text(x) for x in h['models']), meths, flds))
        if len(self.hooks) > limit * 3:
            p('  ... and %d more' % (len(self.hooks) - limit * 3))
        p('')
        # 5. merge
        p('5. THE MERGE')
        if not self.overlap:
            p('  No file changed on both sides since the base: the merge will be clean.')
        else:
            p('  %d file(s) changed on both sides; %d with conflicts:' % (len(self.overlap), len(self.conflicts)))
            for fp in self.overlap[:limit * 2]:
                p('    %s %s' % ('CONFLICT' if fp in self.conflicts else 'merges  ', fp))
        p('')
        # 6. after
        p('6. AFTER THE MERGE')
        p('  Update (existing modules changed): %s' % (', '.join(self.update_mods) or 'none'))
        for db, mods in self.installed.items():
            if mods is None:
                p('    %s: could not read installed modules' % db)
            else:
                hit = [m for m in self.update_mods if m in mods]
                newhit = [m['module'] for m in self.new_modules if m['module'] in mods]
                p('    installed on %s: %s' % (db, ', '.join(hit) or 'none of them') +
                  ('; new modules already there: ' + ', '.join(newhit) if newhit else ''))
        if self.new_modules:
            p('  New modules: not installed anywhere until someone installs them (bridges follow their gate).')
        if self.test_mods:
            p('  Their tests (run with the -u of the same modules, on a copy):')
            p('    --test-tags ' + ','.join('/' + m for m in self.test_mods))
        if self.new_modules:
            p('  New modules\' tests run only where they are installed: -i them on a database copy.')
        p('')
        # 7. commits
        p('7. COMMITS')
        authors = Counter((c['author'], self.author_label(c['author'], c['email'])) for c in self.commits)
        for (name, label), n in authors.most_common():
            p('  %3d  %s  (%s)' % (n, name, label))
        merges = [c for c in self.commits if c['merge']]
        if merges:
            p('  merge commits: %d' % len(merges))
        for c in self.commits[:limit * 3]:
            p('  %s %s %-16s %s%s' % (c['sha'], c['date'][:10], short(c['author'], 16), 'MERGE ' if c['merge'] else '',
                                      short(c['subject'], 90)))
        if len(self.commits) > limit * 3:
            p('  ... and %d more' % (len(self.commits) - limit * 3))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('source', help='the branch to review, e.g. origin/18_emt_v2')
    ap.add_argument('-i', '--instance', help='1, 2 or 3: use odcaN/ePHEM-core')
    ap.add_argument('--repo', help='path of the git clone (default: odca1/ePHEM-core, or the -i instance)')
    ap.add_argument('--target', help='branch it would merge into (default: the clone\'s current branch)')
    ap.add_argument('--dev', help='owners.ini profile to judge against (default: guessed from branch and authors)')
    ap.add_argument('--owners', default=os.path.join(HERE, 'owners.ini'))
    ap.add_argument('--core', help='an ePHEM-core clone, to resolve hooks when reviewing another repository')
    ap.add_argument('--db', action='append', help='database to check installed modules in (repeatable)')
    ap.add_argument('--odoo-container', action='append',
                    help='running Odoo container to read Odoo\'s own source from (default ephem-N, then ephem-1..3)')
    ap.add_argument('--max', type=int, default=12, help='items shown per list (default 12)')
    ap.add_argument('--all', action='store_true', help='show every item')
    ap.add_argument('--json', help='also write the full report as JSON to this file')
    a = ap.parse_args()
    if not a.repo:
        a.repo = os.path.join(DEPLOY_ROOT, 'odca%s' % (a.instance or '1'), 'ePHEM-core')
    elif not os.path.isabs(a.repo) and not os.path.isdir(a.repo):
        a.repo = os.path.join(DEPLOY_ROOT, a.repo)
    if not os.path.isdir(a.repo):
        sys.exit('no such clone: %s' % a.repo)
    if not a.odoo_container:
        a.odoo_container = (['ephem-%s' % a.instance] if a.instance else []) + ['ephem-1', 'ephem-2', 'ephem-3']
    if not a.core:
        sibling = os.path.join(os.path.dirname(os.path.abspath(a.repo)), 'ePHEM-core')
        if os.path.isdir(sibling) and os.path.abspath(sibling) != os.path.abspath(a.repo):
            a.core = sibling
    r = Review(a)
    r.run()
    r.print_text()
    if a.json:
        with open(a.json, 'w', encoding='utf-8') as fh:
            json.dump(r.to_json(), fh, indent=1, default=list)


if __name__ == '__main__':
    main()

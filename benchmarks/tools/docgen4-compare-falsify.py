#!/usr/bin/env python3
"""Make `docgen4-compare.py` fail once per arm, so that its green means something.

CLAUDE.md: a gate does not check itself, and on the day they were made two "gates
that pass no matter what" were built. This is the same rule applied to a one-shot
comparator. Each case perturbs one input, runs the comparator and reports whether
it went red; the baseline run with nothing perturbed has to be green.

**A case whose perturbation did not land is refused rather than reported.** The
first run of this script printed GREEN for a changed anchor id, and the comparator
was not at fault: the page the perturbation was applied to had almost no
declarations, so the replace matched nothing. A perturbation that changes no bytes
can only produce a green, which is the failure this script exists to rule out.

usage: docgen4-compare-falsify.py [--work DIR] [--tree DIR] [--page PATH]
  --work  the directory `docgen4-compare.py`'s inputs are in: ir/, site/,
          link-index.lidx, links.json, decl-source-urls.tsv
  --tree  doc-gen4's reference tree (default <target>/.lake/build/doc)
  --page  the page under site/ the Q1 cases perturb. It needs several
          declarations and a module docstring, or the cases cannot be built.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / 'docgen4-compare.py'

parser = argparse.ArgumentParser(add_help=True)
parser.add_argument('--work', default='/private/tmp/lean-doc-relay/a1')
parser.add_argument('--tree',
                    default='/Users/haruka/dev/lean-projects/.lake/build/doc')
parser.add_argument('--page',
                    default='InformationTheory/Shannon/Kolmogorov/SufficientStatistic.html')
args = parser.parse_args()

W = pathlib.Path(args.work)
P = W.parent / (W.name + '-falsify')
TREE = args.tree
PAGE = args.page
if P.exists():
    shutil.rmtree(P)
P.mkdir(parents=True)
shutil.copytree(W / 'site', P / 'site')
shutil.copy(W / 'link-index.lidx', P / 'link-index.lidx')
shutil.copy(W / 'links.json', P / 'links.json')
ORIG_PAGE = (W / 'site' / PAGE).read_text(encoding='utf-8')
ORIG_LIDX = (W / 'link-index.lidx').read_text(encoding='utf-8')
ORIG_LINKS = (W / 'links.json').read_text(encoding='utf-8')


def restore():
    (P / 'site' / PAGE).write_text(ORIG_PAGE, encoding='utf-8')
    (P / 'link-index.lidx').write_text(ORIG_LIDX, encoding='utf-8')
    (P / 'links.json').write_text(ORIG_LINKS, encoding='utf-8')


def run():
    r = subprocess.run(
        [sys.executable, str(SCRIPT), '--ir', str(W / 'ir'), '--site', str(P / 'site'),
         '--tree', TREE, '--lidx', str(P / 'link-index.lidx'),
         '--links', str(P / 'links.json'), '--oracle', str(W / 'decl-source-urls.tsv')],
        capture_output=True, text=True)
    said = [l.strip() for l in r.stderr.splitlines() if l.strip()][:3]
    return r.returncode, said


def page(fn):
    # A perturbation that did not land makes a green mean nothing, which is the
    # failure this whole script exists to rule out.
    changed = fn(ORIG_PAGE)
    if changed == ORIG_PAGE:
        raise SystemExit('the perturbation did not change the page')
    (P / 'site' / PAGE).write_text(changed, encoding='utf-8')


cases = []

# 1 an anchor litedoc4 renders that doc-gen4 has no anchor for, and the same
#   declaration going missing from the page it belongs to.
def anchor(html):
    return html.replace('<section class="decl" id="InformationTheory.Kolmogorov.modelCode"',
                        '<section class="decl" id="InformationTheory.Kolmogorov.modelCode_x"', 1)
cases.append(('Q1 anchor: one declaration id changed', anchor, None, None))

# 2 two declarations swapped, so the page order differs where the positions do
#   not tie.
def order(html):
    parts = html.split('<section class="decl" id="')
    if len(parts) < 4:
        raise SystemExit('the page has too few declarations to swap')
    parts[1], parts[2] = parts[2], parts[1]
    return '<section class="decl" id="'.join(parts)
cases.append(('Q1 order: two declarations swapped', order, None, None))

# 3 a word litedoc4 shows that neither doc-gen4 nor the source has.
def invented(html):
    return html.replace('<div class="moddoc">', '<div class="moddoc">Zzyzx notatoken ', 1)
cases.append(('Q1 docstring: a word invented', invented, None, None))

# 4 a word the source still has that litedoc4 stops showing.
def dropped(html):
    at = html.index('<div class="moddoc">') + len('<div class="moddoc">')
    end = html.index('</div>', at)
    body = html[at:end]
    words = body.split(' ')
    return html[:at] + ' '.join(w for w in words if len(w) < 12) + html[end:]
cases.append(('Q1 docstring: the long words dropped', dropped, None, None))

# 5 a source link naming a different file.
def source_link(html):
    return html.replace('/InformationTheory/Shannon/Kolmogorov/SufficientStatistic.lean',
                        '/InformationTheory/Shannon/Kolmogorov/Elsewhere.lean', 1)
cases.append(('Q1 source links: one file path changed', source_link, None, None))


# 6 a root whose URL is not the one doc-gen4 wrote. Two rows, because the two
#   are checked through different fields: doc-gen4's tree has a page for `Init`
#   itself and none for `Mathlib`, whose only oracle is a deeper module.
def links_mathlib(text):
    data = json.loads(text)
    for row in data['rows']:
        if row['root'] == 'Mathlib':
            row['moduleUrl'] = row['moduleUrl'].replace('/Mathlib/', '/Elsewhere/')
    return json.dumps(data)
cases.append(('Q2 roots: Mathlib deep module pointed elsewhere', None, links_mathlib, None))


def links_init(text):
    data = json.loads(text)
    for row in data['rows']:
        if row['root'] == 'Init':
            row['url'] = row['url'].replace('/blob/', '/blob/dead/')
    return json.dumps(data)
cases.append(('Q2 roots: Init pinned to another revision', None, links_init, None))


# 7 a .lidx line range that is not the one doc-gen4 wrote.
def lidx(text):
    out, hit = [], 0
    for line in text.splitlines(True):
        if hit < 40 and line.startswith('\t') and line.count('\t') >= 3:
            fields = line.rstrip('\n').split('\t')
            if fields[2].isdigit() and fields[2] != '0':
                fields[2] = str(int(fields[2]) + 1000)
                line = '\t'.join(fields) + '\n'
                hit += 1
        out.append(line)
    if hit == 0:
        raise SystemExit('no .lidx entry was perturbed')
    return ''.join(out)
cases.append(('Q3 declaration URLs: 40 line ranges shifted', None, None, lidx))

print('falsification of benchmarks/tools/docgen4-compare.py')
print(f'  baseline (nothing perturbed):', run()[0])
for name, page_fn, links_fn, lidx_fn in cases:
    restore()
    if page_fn:
        page(page_fn)
    if links_fn:
        changed = links_fn(ORIG_LINKS)
        if changed == ORIG_LINKS:
            raise SystemExit('the perturbation did not change links.json')
        (P / 'links.json').write_text(changed, encoding='utf-8')
    if lidx_fn:
        changed = lidx_fn(ORIG_LIDX)
        if changed == ORIG_LIDX:
            raise SystemExit('the perturbation did not change the .lidx')
        (P / 'link-index.lidx').write_text(changed, encoding='utf-8')
    rc, said = run()
    print(f'  {"RED " if rc else "GREEN"}  {name}')
    for line in said:
        print(f'         {line[:150]}')
restore()

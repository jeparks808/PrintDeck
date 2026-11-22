#!/usr/bin/env python3
"""Build Resources/ImportedPresets.plist: the user presets (printer, filament and process) saved in ElegooSlicer
and OrcaSlicer on this computer, translated into PrintDeck's slicing-setting keys. PrintDeck adds them to its
own user presets the first time it runs with them (one you delete there stays deleted).

User presets only hold what was changed; the rest comes from the system preset they inherit, so each is
resolved through that slicer's own system profiles (~/.config/<slicer>/system/…, which include the
OrcaFilamentLibrary "Generic … @System" filaments). Presets for printers PrintDeck doesn't slice for (the
Centauri Carbon 2, say) are skipped and listed.

    tools/import-user-presets.py                      # ~/.config/ElegooSlicer and ~/.config/OrcaSlicer
    tools/import-user-presets.py --config DIR [...]   # other slicer config folders
"""
import argparse, datetime, json, os, plistlib, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import importlib.util
_spec = importlib.util.spec_from_file_location('make_profiles', os.path.join(HERE, 'make-profiles.py'))
mp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mp)

OUT = os.path.join(HERE, '..', 'Resources', 'ImportedPresets.plist')
STOCK = os.path.join(HERE, '..', 'Resources', 'StockProfiles.plist')
KINDS = ('machine', 'process', 'filament')
EDITOR = {'machine': 'printer', 'process': 'process', 'filament': 'filament'}


def load_dir(root, kind_from_folder=False):
    """{(kind, name): json} for every preset under root (user presets have no "type": their folder says it)."""
    by = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith('.json'):
                continue
            try:
                j = json.load(open(os.path.join(d, f), encoding='utf-8'))
            except Exception:
                continue
            if not isinstance(j, dict) or 'name' not in j:
                continue
            kind = j.get('type')
            if kind_from_folder or not kind:
                # The nearest process/filament/machine folder up the path (Orca keeps system processes in
                # system/Elegoo/process/ECC/ without a "type").
                parts = os.path.relpath(d, root).split(os.sep)
                found = [p for p in parts if p in KINDS]
                kind = found[-1] if found else kind
            if kind:
                by[(kind, j['name'])] = j
    return by


def resolve(by, kind, name, seen=()):
    j = by.get((kind, name))
    if j is None or name in seen:
        return {}
    base = dict(resolve(by, kind, j['inherits'], seen + (name,))) if j.get('inherits') else {}
    base.update(j)
    return base


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', nargs='*', default=[os.path.expanduser('~/.config/ElegooSlicer'), os.path.expanduser('~/.config/OrcaSlicer')])
    ap.add_argument('--out', default=OUT)
    a = ap.parse_args()
    printers = [p['name'] for p in plistlib.load(open(STOCK, 'rb'))['printers']]

    presets, skipped, seen, differs = [], [], {}, []
    for conf in a.config:
        slicer = os.path.basename(conf.rstrip('/'))
        if not os.path.isdir(os.path.join(conf, 'user')):
            continue
        system = load_dir(os.path.join(conf, 'system'))
        for (kind, name), j in sorted(load_dir(os.path.join(conf, 'user'), kind_from_folder=True).items()):
            if kind not in KINDS or not os.path.isdir(os.path.join(conf, 'user')):
                continue
            by = dict(system)
            by[(kind, name)] = j
            r = resolve(by, kind, name)
            if kind == 'machine':
                parent = r.get('inherits') or ''
                base = j.get('inherits') or ''
                compat = [base] if base in printers else [n for n in printers if mp.val(r, 'printer_model') == 'Elegoo Centauri Carbon'
                                                          and abs(mp.num(r, 'nozzle_diameter', 0) - float(n.split()[-2])) < 1e-6]
                settings = mp.machine_settings(r)
                del parent
            else:
                listed = r.get('compatible_printers') or []
                compat = [c for c in listed if c in printers]
                if not listed and kind == 'filament' and not r.get('compatible_printers_condition'):
                    compat = list(printers)   # a library filament with no printer list fits any printer
                if kind == 'process':
                    settings = mp.process_settings(r)
                else:
                    settings = mp.filament_settings(r)
                    colour = mp.val(r, 'default_filament_colour') or mp.val(r, 'filament_colour')
                    if colour and str(colour).startswith('#') and len(str(colour)) >= 7:
                        settings['filamentColor'] = str(colour)[:7].upper()
                    settings['filamentName'] = name
            if not compat:
                skipped.append('%s %s "%s" (for %s)' % (slicer, EDITOR[kind], name, ', '.join(r.get('compatible_printers') or [r.get('printer_model') or '?'])))
                continue
            key = (EDITOR[kind], name)
            if key in seen:
                # The same name in both slicers (one usually copied from the other): keep the first slicer's
                # (ElegooSlicer, listed first), noting when the translated values differ.
                if seen[key]['settings'] != settings:
                    differs.append('%s "%s": kept %s\'s, %s\'s differs' % (EDITOR[kind], name, seen[key]['from'], slicer))
                continue
            p = {'name': name, 'editor': EDITOR[kind], 'printers': compat, 'printer': compat[0], 'from': slicer,
                 'inherits': j.get('inherits') or '', 'settings': settings}
            seen[(EDITOR[kind], name)] = p
            presets.append(p)

    out = {'date': datetime.datetime.now().replace(microsecond=0), 'presets': presets}
    with open(a.out, 'wb') as fh:
        plistlib.dump(out, fh, fmt=plistlib.FMT_XML)
    for p in presets:
        print('  %-9s %-58s %s' % (p['editor'], p['name'][:58], ', '.join(x.replace('Elegoo Centauri Carbon ', 'CC ') for x in p['printers'])))
    for s in skipped:
        print('  skipped  ' + s)
    for s in differs:
        print('  note     ' + s)
    print('%d presets -> %s (%d skipped)' % (len(presets), os.path.relpath(a.out), len(skipped)))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Build Resources/StockProfiles.plist: ElegooSlicer's stock (factory) profiles for the printers PrintDeck can
slice for, translated into PrintDeck's slicing-setting keys (see PDSliceSettings in PDSlicer.m).

The iPad 1 can't fetch them itself: GitHub only accepts TLS 1.2 ciphers that iOS 5 doesn't have. So this
runs on the build computer, downloads the profiles from GitHub (a sparse, shallow clone of
ELEGOO-3D/ElegooSlicer, resources/profiles/Elegoo only), resolves each profile's `inherits` chain, and maps
the values. Run it again, then `make package install`, to pick up Elegoo's newer profiles.

    tools/make-profiles.py                 # download, then write Resources/StockProfiles.plist
    tools/make-profiles.py --src DIR       # use an existing checkout of resources/profiles/Elegoo
"""
import argparse, json, os, plistlib, re, subprocess, sys, tempfile, datetime

REPO = 'https://github.com/ELEGOO-3D/ElegooSlicer.git'
PRINTER_MODELS = ['Elegoo Centauri Carbon']   # printers PrintDeck's start/end G-code and upload support
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'Resources', 'StockProfiles.plist')
BED_OUT = os.path.join(HERE, '..', 'Sources', 'Common', 'PDBedShape.h')


def fetch(dest):
    subprocess.check_call(['git', 'clone', '-q', '--depth', '1', '--filter=blob:none', '--sparse', REPO, dest])
    subprocess.check_call(['git', '-C', dest, 'sparse-checkout', 'set', 'resources/profiles/Elegoo'])
    commit = subprocess.check_output(['git', '-C', dest, 'log', '-1', '--format=%h %cs']).decode().split()
    return os.path.join(dest, 'resources', 'profiles', 'Elegoo'), commit[0], commit[1]


def load(root):
    by = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith('.json'):
                continue
            try:
                j = json.load(open(os.path.join(d, f), encoding='utf-8'))
            except Exception:
                continue
            if isinstance(j, dict) and 'name' in j:
                by[(j.get('type'), j['name'])] = j
    return by


def resolve(by, kind, name):
    j = by[(kind, name)]
    base = dict(resolve(by, kind, j['inherits'])) if j.get('inherits') else {}
    base.update(j)
    return base


def val(p, k, default=None):
    """First value of a key (Orca stores per-extruder lists); 'nil' and '' count as unset."""
    v = p.get(k)
    if isinstance(v, list):
        v = v[0] if v else None
    if v is None or v in ('nil', ''):
        return default
    return v


def num(p, k, default=None):
    v = val(p, k)
    if v is None:
        return default
    s = str(v).strip()
    try:
        return float(s[:-1]) if s.endswith('%') else float(s)
    except ValueError:
        return default


def r2(x):
    return round(float(x), 3)


def machine_settings(m):
    s = {'nozzle': r2(num(m, 'nozzle_diameter', 0.4)), 'filamentDiameter': 1.75, 'retract': 1}
    for key, ok in (('retractDistance', 'retraction_length'), ('retractSpeed', 'retraction_speed'),
                    ('retractMinTravel', 'retraction_minimum_travel'), ('zHop', 'z_hop')):
        v = num(m, ok)
        if v is not None:
            s[key] = r2(v)
    extra = num(m, 'retract_restart_extra')
    if extra is not None:
        s['retractPrime'] = r2(extra)
    return s


INFILL = {'grid': 1, 'zig-zag': 2, 'rectilinear': 2, 'line': 2, 'alignedrectilinear': 2, 'concentric': 3, 'gyroid': 4}


def process_settings(p):
    lw = num(p, 'line_width') or num(p, 'outer_wall_line_width') or 0.42
    s = {
        'layerHeight': r2(num(p, 'layer_height', 0.2)),
        'firstLayerHeight': r2(num(p, 'initial_layer_print_height', 0.2)),
        'lineWidth': r2(lw),
        'walls': int(num(p, 'wall_loops', 2)),
        'topLayers': int(num(p, 'top_shell_layers', 4)),
        'bottomLayers': int(num(p, 'bottom_shell_layers', 3)),
        'infill': r2(num(p, 'sparse_infill_density', 15)),
        'infillPattern': INFILL.get(val(p, 'sparse_infill_pattern', ''), 0),
        'infillOverlap': r2(num(p, 'infill_wall_overlap', 15)),
        'wallsFirst': 1 if str(val(p, 'wall_infill_order', '')).endswith('infill') and not str(val(p, 'wall_infill_order', '')).startswith('infill') else 0,
        'printSpeed': r2(num(p, 'inner_wall_speed', 120)),
        'outerWallSpeed': r2(num(p, 'outer_wall_speed', 80)),
        'innerWallSpeed': r2(num(p, 'inner_wall_speed', 120)),
        'infillSpeed': r2(num(p, 'sparse_infill_speed', 140)),
        'skinSpeed': r2(min(num(p, 'top_surface_speed', 100), num(p, 'internal_solid_infill_speed', 1000))),
        'firstLayerSpeed': r2(num(p, 'initial_layer_speed', 30)),
        'travelSpeed': r2(num(p, 'travel_speed', 300)),
        'vase': 1 if str(val(p, 'spiral_mode', '0')) == '1' else 0,
    }
    first = num(p, 'initial_layer_line_width')
    if first:
        s['firstLayerWidth'] = round(100.0 * first / lw)
    accel = num(p, 'outer_wall_acceleration') or num(p, 'default_acceleration')
    if accel:
        s['acceleration'] = r2(accel)
    # Support. Orca's threshold is the overhang's slope from horizontal; CuraEngine's angle is from vertical.
    sup = str(val(p, 'enable_support', '0')) == '1'
    s['support'] = 0 if not sup else (1 if str(val(p, 'support_on_build_plate_only', '0')) == '1' else 2)
    th = num(p, 'support_threshold_angle', 30) or 30
    s['supportAngle'] = r2(90 - th)
    s['supportGap'] = r2(num(p, 'support_top_z_distance', 0.2))
    s['supportXY'] = r2(num(p, 'support_object_xy_distance', 0.7))
    spacing = num(p, 'support_base_pattern_spacing')
    if spacing:
        s['supportDensity'] = round(100.0 * lw / (spacing + lw) / 5) * 5
    # Adhesion: raft > brim > skirt > none (Orca's default "auto" brim counts as none).
    loops = int(num(p, 'skirt_loops', 0))
    brim = str(val(p, 'brim_type', 'auto_brim'))
    if int(num(p, 'raft_layers', 0)) > 0:
        s['adhesion'] = 3
    elif brim in ('outer_only', 'inner_only', 'outer_and_inner') and num(p, 'brim_width', 0) > 0:
        s['adhesion'] = 2
        s['brimLines'] = max(1, round(num(p, 'brim_width') / lw))
    elif loops > 0:
        s['adhesion'] = 1
        s['skirtLines'] = loops
        s['skirtDistance'] = r2(num(p, 'skirt_distance', 3))
    else:
        s['adhesion'] = 0
    return s


MATERIALS = ['PLA', 'PETG', 'ABS', 'ASA', 'PC', 'PA', 'TPU']


def material_of(t):
    t = (t or 'PLA').upper()
    if t.startswith('PET'):
        return 'PETG'
    if t.startswith('PA') or t.startswith('PPA'):
        return 'PA'
    for m in MATERIALS:
        if t.startswith(m):
            return m
    return 'PLA'


def filament_settings(f):
    t = val(f, 'filament_type', 'PLA')
    s = {
        'material': material_of(t),
        'nozzleTemp': r2(num(f, 'nozzle_temperature', 210)),
        'bedTemp': r2(num(f, 'hot_plate_temp', 60)),   # the Centauri Carbon's default plate is the high-temp PEI plate
        'flow': round(100 * num(f, 'filament_flow_ratio', 1.0)),
        # Orca runs the fan between min and max by layer time, up to max below fan_cooling_layer_time (often
        # 30-100 s, so most layers of small parts); CuraEngine only ramps when slowing for the minimum layer
        # time. So a long cooling time maps to the max speed.
        'fan': r2(num(f, 'fan_max_speed', 100) if num(f, 'fan_cooling_layer_time', 0) >= 30 else num(f, 'fan_min_speed', 100)),
        'fanMax': r2(num(f, 'fan_max_speed', 100)),
        'minLayerTime': r2(num(f, 'slow_down_layer_time', 6)),
        'minSpeed': r2(num(f, 'slow_down_min_speed', 10)),
        'auxFan': r2(num(f, 'additional_cooling_fan_speed', 0)),
        'chamberFanPct': r2(num(f, 'during_print_exhaust_fan_speed', 0)),
        'filamentDiameter': r2(num(f, 'filament_diameter', 1.75)),
        'filamentDensity': r2(num(f, 'filament_density', 1.24)),
        'filamentName': f['name'].split(' @')[0],
    }
    off = int(num(f, 'close_fan_the_first_x_layers', 1))
    s['fanFullLayer'] = max(1, int(num(f, 'full_fan_speed_layer', 0)), off + 1)
    for key, ok in (('retractDistance', 'filament_retraction_length'), ('retractSpeed', 'filament_retraction_speed'),
                    ('retractMinTravel', 'filament_retraction_minimum_travel'), ('zHop', 'filament_z_hop')):
        v = num(f, ok)
        if v is not None:
            s[key] = r2(v)
    return s


def bed_shape(root, machine, out, commit):
    """PDBedShape.h: the printer's physical plate (ElegooSlicer's bed_model STL, its top face at z = 0) as triangles
    and outline edges, in printer coordinates. Orca centres the model on the printable area."""
    import struct
    stl = os.path.join(root, val(machine, 'bed_model', '') or '')
    if not os.path.isfile(stl):
        print('no bed model; PDBedShape.h left as it is')
        return
    d = open(stl, 'rb').read()
    n = struct.unpack('<I', d[80:84])[0]
    area = [tuple(float(c) for c in p.split('x')) for p in (machine.get('printable_area') or ['0x0', '256x0', '256x256', '0x256'])]
    cx = (min(p[0] for p in area) + max(p[0] for p in area)) / 2
    cy = (min(p[1] for p in area) + max(p[1] for p in area)) / 2
    tris = []
    for i in range(n):
        v = struct.unpack('<12f', d[84 + 50 * i:84 + 50 * i + 48])
        pts = [v[3:6], v[6:9], v[9:12]]
        if all(abs(p[2]) < 1e-3 for p in pts):   # the top face
            tris.append([(round(p[0] + cx, 2), round(p[1] + cy, 2)) for p in pts])
    edges = {}
    for t in tris:
        for a, b in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])):
            k = (min(a, b), max(a, b))
            edges[k] = edges.get(k, 0) + 1
    outline = [k for k, c in sorted(edges.items()) if c == 1]
    with open(out, 'w') as fh:
        fh.write('// Generated by tools/make-profiles.py from ElegooSlicer %s (%s). Do not edit.\n' % (commit, os.path.basename(stl)))
        fh.write('// The Centauri Carbon\'s physical plate in printer mm (it reaches past the 0-256 mm printable area):\n')
        fh.write('// top-face triangles (x, y per corner) and its outline (x0, y0, x1, y1 per edge).\n')
        fh.write('static const float PDBedTris[%d] = {\n' % (len(tris) * 6))
        for t in tris:
            fh.write('\t%s,\n' % ', '.join('%g, %g' % p for p in t))
        fh.write('};\nstatic const float PDBedOutline[%d] = {\n' % (len(outline) * 4))
        for a, b in outline:
            fh.write('\t%g, %g, %g, %g,\n' % (a[0], a[1], b[0], b[1]))
        fh.write('};\n#define PDBedTriCount %d\n#define PDBedEdgeCount %d\n' % (len(tris), len(outline)))
    print('%d plate triangles, %d outline edges -> %s' % (len(tris), len(outline), os.path.relpath(out)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', help='existing resources/profiles/Elegoo directory')
    ap.add_argument('--out', default=OUT)
    a = ap.parse_args()
    tmp = None
    if a.src:
        root, commit, date = a.src, 'local', datetime.date.today().isoformat()
    else:
        tmp = tempfile.mkdtemp(prefix='elegooslicer-')
        root, commit, date = fetch(os.path.join(tmp, 'es'))
    by = load(root)

    printers, processes, filaments = [], [], []
    machines = sorted(n for (k, n), j in by.items() if k == 'machine' and str(j.get('instantiation')) == 'true'
                      and n.endswith('nozzle') and val(resolve(by, k, n), 'printer_model') in PRINTER_MODELS)
    names = set(machines)
    for n in machines:
        m = resolve(by, 'machine', n)
        printers.append({'name': n, 'model': val(m, 'printer_model', n), 'nozzle': r2(num(m, 'nozzle_diameter', 0.4)),
                         'defaultProcess': val(m, 'default_print_profile', ''),
                         'defaultFilament': val(m, 'default_filament_profile', ''), 'settings': machine_settings(m)})
    for (k, n), j in sorted(by.items()):
        if str(j.get('instantiation')) != 'true':
            continue
        r = resolve(by, k, n)   # compatible_printers may be inherited
        compat = [c for c in (r.get('compatible_printers') or []) if c in names]
        if not compat:
            continue
        if k == 'process':
            processes.append({'name': n, 'title': n.split(' @')[0], 'printers': compat, 'settings': process_settings(r)})
        elif k == 'filament':
            filaments.append({'name': n, 'title': n.split(' @')[0], 'vendor': val(r, 'filament_vendor', ''),
                              'type': val(r, 'filament_type', ''), 'printers': compat, 'settings': filament_settings(r)})
    processes.sort(key=lambda p: (float(re.match(r'([\d.]+)', p['title']).group(1)) if re.match(r'[\d.]+', p['title']) else 0, p['title']))
    filaments.sort(key=lambda f: f['title'])
    out = {'source': 'ElegooSlicer (github.com/ELEGOO-3D/ElegooSlicer)', 'commit': commit, 'date': date,
           'materials': MATERIALS, 'printers': printers, 'processes': processes, 'filaments': filaments}
    if printers:
        m = resolve(by, 'machine', machines[0])
        model = by.get(('machine_model', val(m, 'printer_model', '')), {})   # bed_model lives on the printer model
        bed_shape(root, dict(m, **model), BED_OUT, commit)
    with open(a.out, 'wb') as fh:
        plistlib.dump(out, fh, fmt=plistlib.FMT_XML)
    print('%d printers, %d quality profiles, %d filaments (ElegooSlicer %s, %s) -> %s'
          % (len(printers), len(processes), len(filaments), commit, date, os.path.relpath(a.out)))
    if tmp:
        subprocess.call(['rm', '-rf', tmp])


if __name__ == '__main__':
    main()

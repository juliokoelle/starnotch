"""
Astra (Starnotch mascot) - procedural Blender build + render. Round 3: five-point glass star.

Usage (headless):
  Blender -b -P astra.py -- [--colorways nova,aurora|all] [--states neutral,happy|all]
                            [--out DIR] [--samples N] [--res 1024] [--no-halo] [--save-blend PATH]
                            [--skip-existing]
  Full set (6 colorways x 13 states = 78 PNGs):
  Blender -b -P astra.py -- --colorways all --states all --skip-existing

Scene (all generated from code):
  AstraRoot (empty, carries pose)            -> one transform for everything below
    AstraBody   glass shell (transmission + coat + rim glow), five-arm inflated star
    AstraCore   shrunken inner star, emissive, fades at its silhouette (light inside)
    AstraSparkles  tiny emissive 4-point stars between core and shell
    AstraPlate  dark glossy face plate patch on the front surface; eyes/mouth/blush
                come from a generated SDF texture (R = white features, G = blush)
  Glint lights are glossy-only and light-linked to the shell; the plate has one
  light of its own whose position is solved so the glint lands at a chosen spot.
"""
import bpy, math, os, sys, time, argparse
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------- params
TILT = -6.0  # overall in-plane tilt of the star (deg)
SHAPE = dict(
    # five arms: (angle deg, length, base radius, tip radius, curl, z-lift)
    #   tapered (base radius >> tip radius) so it reads as a star even at 20 px.
    #   curl bends the arm sideways (+ = counter-clockwise), lift curls the tip forward (+) / back (-)
    arms=[(90 + TILT,  1.02, 0.60, 0.36,  0.10,  0.12),    # top tip: gently curled forward
          (18 + TILT,  0.97, 0.58, 0.35, -0.03,  0.00),
          (-54 + TILT, 0.93, 0.59, 0.36,  0.03, -0.03),
          (-126 + TILT, 0.96, 0.59, 0.36, -0.03,  0.02),
          (162 + TILT, 1.00, 0.58, 0.35,  0.05, -0.02)],
    core=0.74,          # central disc radius
    smooth=0.26,        # smooth-union radius (fillet between arms)
    inflate=1.50,       # balloon inflation (front height = inflate * sqrt(phi))
    dome=0.08,
    back=0.75,          # back side depth factor
    bend=0.10,          # arms curl backwards overall
    plate_c=(0.0, -0.10), plate_ab=(0.58, 0.44), plate_bulge=0.015,
)

COLORWAYS = {
    # radial ramp core -> mid -> edge, top-left accent, bottom accent, rim glow colour,
    # inner-light colour (core), blush, rim lights A/B, plate colour, glow multiplier. Linear RGB.
    "nova":   dict(core=(0.01, 0.015, 0.45), mid=(0.03, 0.08, 1.00), edge=(0.40, 0.10, 1.00),
                   top=(0.70, 0.25, 1.00), bottom=(1.00, 0.30, 0.45), glow=(0.80, 0.35, 1.00),
                   inner=(0.02, 0.07, 1.00), tipglow=(1.00, 0.25, 0.85), warm=(1.0, 0.42, 0.40), blush=(1.0, 0.30, 0.55),
                   rimA=(1.0, 0.35, 0.75), rimB=(0.30, 0.45, 1.0), glow_k=1.0, plate=(0.004, 0.005, 0.022)),
    "aurora": dict(core=(0.55, 0.02, 0.35), mid=(1.00, 0.10, 0.45), edge=(1.00, 0.42, 0.10),
                   top=(0.80, 0.10, 0.90), bottom=(1.00, 0.42, 0.02), glow=(1.00, 0.45, 0.30),
                   inner=(1.00, 0.06, 0.45), tipglow=(1.00, 0.50, 0.04), warm=(1.0, 0.50, 0.10),
                   blush=(1.0, 0.35, 0.45),
                   bot_k=(-0.70, 0.30),     # pink top -> orange from the middle down
                   rimA=(1.0, 0.55, 0.25), rimB=(0.65, 0.30, 1.0), glow_k=1.0, plate=(0.020, 0.006, 0.025)),
    "cosmo":  dict(core=(0.008, 0.005, 0.025), mid=(0.05, 0.025, 0.15), edge=(0.30, 0.15, 0.80),
                   top=(0.35, 0.30, 0.80), bottom=(0.45, 0.15, 0.60), glow=(0.45, 0.30, 1.00),
                   inner=(0.03, 0.015, 0.10), tipglow=(0.40, 0.20, 1.00), warm=(0.55, 0.30, 0.90), blush=(0.8, 0.35, 0.9),
                   rimA=(0.70, 0.45, 1.0), rimB=(0.35, 0.40, 1.0), glow_k=0.35, plate=(0.004, 0.004, 0.012)),
    "sol":    dict(core=(0.55, 0.10, 0.01), mid=(1.00, 0.33, 0.03), edge=(1.00, 0.58, 0.14),
                   top=(1.00, 0.80, 0.30), bottom=(1.00, 0.18, 0.22), glow=(1.00, 0.50, 0.15),
                   inner=(1.00, 0.35, 0.05), tipglow=(1.00, 0.80, 0.35), warm=(1.0, 0.50, 0.15), blush=(1.0, 0.30, 0.25),
                   rimA=(1.0, 0.70, 0.30), rimB=(1.0, 0.35, 0.40), glow_k=1.0, plate=(0.030, 0.010, 0.006)),
    "mint":   dict(core=(0.00, 0.22, 0.14), mid=(0.02, 0.80, 0.45), edge=(0.20, 1.00, 0.75),
                   top=(0.10, 0.40, 1.00), bottom=(0.10, 1.00, 0.30), glow=(0.15, 1.00, 0.70),
                   inner=(0.05, 0.90, 0.50), tipglow=(0.40, 1.00, 0.85), warm=(0.25, 1.0, 0.45), blush=(1.0, 0.45, 0.55),
                   rimA=(0.30, 1.0, 0.70), rimB=(0.30, 0.55, 1.0), glow_k=0.9, plate=(0.004, 0.018, 0.022)),
    "rose":   dict(core=(1.00, 0.40, 0.58), mid=(1.00, 0.52, 0.70), edge=(1.00, 0.72, 0.86),
                   top=(1.00, 0.68, 0.90), bottom=(1.00, 0.55, 0.65), glow=(1.00, 0.62, 0.82),
                   inner=(1.00, 0.30, 0.55), tipglow=(1.00, 0.62, 0.80), warm=(1.0, 0.55, 0.65), blush=(1.0, 0.30, 0.45),
                   rimA=(1.0, 0.55, 0.80), rimB=(0.75, 0.45, 1.0), glow_k=0.55, plate=(0.030, 0.008, 0.022)),
}
STATES = ["neutral", "happy", "joyful", "sleepy", "surprised", "excited", "confused",
          "angry", "thinking", "sleep", "love", "determined", "peek"]


# --------------------------------------------------------------------------- 2D SDF
def sd_uneven_capsule(px, py, r1, r2, h):
    px = np.abs(px)
    b = (r1 - r2) / h
    a = math.sqrt(1.0 - b * b)
    k = -b * px + a * py
    d_lo = np.hypot(px, py) - r1
    d_hi = np.hypot(px, py - h) - r2
    d_mid = a * px + b * py - r1
    return np.where(k < 0, d_lo, np.where(k > a * h, d_hi, d_mid))


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)


def _arm_frame(x, y, ang):
    t = math.radians(ang) - math.pi / 2       # rotate so arm points along +y
    c, s = math.cos(-t), math.sin(-t)
    return c * x - s * y, s * x + c * y


def star_sdf(x, y, S):
    d = np.hypot(x, y) - S["core"]
    for ang, L, rb, rt, curl, lift in S["arms"]:
        qx, qy = _arm_frame(x, y, ang)
        qx = qx + curl * np.clip(qy, 0, None) ** 2      # bend the arm sideways
        d = smin(d, sd_uneven_capsule(qx, qy, rb, rt, L), S["smooth"])
    return d


_FIELD = {}


def _key(S, tag):
    return (tag, id(S))


def _smooth_sdf_grid(S, n=900, ext=2.2, sigma=0.06):
    key = _key(S, "sdf")
    if key in _FIELD: return _FIELD[key]
    xs = np.linspace(-ext, ext, n)
    X, Y = np.meshgrid(xs, xs)
    D = star_sdf(X, Y, S)
    pad = 64
    Dp = np.pad(D, pad, mode="edge")
    sg = sigma / (xs[1] - xs[0])
    fy = np.fft.fftfreq(Dp.shape[0])[:, None]; fx = np.fft.fftfreq(Dp.shape[1])[None, :]
    G = np.exp(-2 * (np.pi * sg) ** 2 * (fx ** 2 + fy ** 2))
    Db = np.real(np.fft.ifft2(np.fft.fft2(Dp) * G))[pad:-pad, pad:-pad]
    _FIELD[key] = (xs, Db)
    return _FIELD[key]


def _interp(xs, G, x, y):
    n = len(xs); h = xs[1] - xs[0]
    fx = np.clip((np.asarray(x) - xs[0]) / h, 0, n - 1.001)
    fy = np.clip((np.asarray(y) - xs[0]) / h, 0, n - 1.001)
    i0 = fx.astype(int); j0 = fy.astype(int); tx = fx - i0; ty = fy - j0
    return (G[j0, i0] * (1 - tx) * (1 - ty) + G[j0, i0 + 1] * tx * (1 - ty) +
            G[j0 + 1, i0] * (1 - tx) * ty + G[j0 + 1, i0 + 1] * tx * ty)


def sdf_smooth(x, y, S):
    xs, D = _smooth_sdf_grid(S)
    return _interp(xs, D, x, y)


def _sstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def _poisson_grid(S, ext=2.2):
    """Balloon inflation: lap(phi) = -1 inside the star, phi = 0 outside
    (coarse-to-fine Jacobi). sqrt(phi) gives a smooth, ridge-free puffy surface."""
    key = _key(S, "phi")
    if key in _FIELD: return _FIELD[key]
    phi = None
    for n, iters in ((96, 4000), (192, 1500), (384, 800), (768, 400)):
        xs = np.linspace(-ext, ext, n); h = xs[1] - xs[0]
        X, Y = np.meshgrid(xs, xs)
        inside = sdf_smooth(X, Y, S) < 0
        phi = np.zeros((n, n)) if phi is None else np.kron(phi, np.ones((2, 2)))[:n, :n]
        phi *= inside
        for _ in range(iters):
            nb = (np.roll(phi, 1, 0) + np.roll(phi, -1, 0) + np.roll(phi, 1, 1) + np.roll(phi, -1, 1))
            phi = np.where(inside, 0.25 * (nb + h * h), 0.0)
    _FIELD[key] = (xs, phi)
    return _FIELD[key]


def front_height(x, y, S):
    xs, phi = _poisson_grid(S)
    h = S["inflate"] * np.sqrt(np.maximum(_interp(xs, phi, x, y), 0.0))
    d = np.maximum(-sdf_smooth(x, y, S), 0.0)
    h = h + S["dome"] * np.exp(-(x * x + y * y) / 0.6) * _sstep(0, 0.5, d)
    cx, cy = S["plate_c"]; a, b = S["plate_ab"]
    e = ((x - cx) / a) ** 2 + ((y - cy) / b) ** 2
    h = h + S["plate_bulge"] * np.clip(1 - e, 0, 1) ** 2
    return h


def z_offset(x, y, S, rmax):
    """bend: arms curl back overall, individual tips lift forward/back."""
    rho = np.hypot(x, y) / rmax
    off = -S["bend"] * rho ** 2
    ang = np.arctan2(y, x)
    for a, L, rb, rt, curl, lift in S["arms"]:
        da = np.angle(np.exp(1j * (ang - math.radians(a))))
        off = off + lift * np.exp(-(da / 0.45) ** 2) * rho ** 2.5
    return off


def contour(S, n_phi):
    phi = np.linspace(0, 2 * np.pi, n_phi, endpoint=False)
    lo = np.zeros(n_phi); hi = np.full(n_phi, 3.0)
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        inside = sdf_smooth(mid * np.cos(phi), mid * np.sin(phi), S) < 0
        lo = np.where(inside, mid, lo); hi = np.where(inside, hi, mid)
    return phi, lo


def build_star_mesh(name, S, n_phi=600, n_u=110, rmax_ref=None, zscale=1.0):
    phi, rmax = contour(S, n_phi)
    rref = rmax_ref or float(rmax.max())
    u = np.linspace(0, 1, n_u + 1)[1:]
    t = 1 - (1 - u) ** 2                               # dense near rim
    T, P = np.meshgrid(t, phi, indexing="ij")
    X = T * rmax[None, :] * np.cos(P)
    Y = T * rmax[None, :] * np.sin(P)
    H = front_height(X, Y, S) * zscale
    H[-1, :] = 0.0
    off = z_offset(X, Y, S, rref)
    h0 = float(front_height(np.zeros(1), np.zeros(1), S)[0]) * zscale
    o0 = 0.0
    verts = [(0.0, 0.0, h0 + o0)]
    verts += [tuple(v) for v in np.stack([X, Y, H + off], -1).reshape(-1, 3)]
    nf = len(verts)
    verts += [tuple(v) for v in np.stack([X[:-1], Y[:-1], -S["back"] * H[:-1] + off[:-1]], -1).reshape(-1, 3)]
    verts.append((0.0, 0.0, -S["back"] * h0 + o0)); bc = len(verts) - 1

    def fi(i, j): return 1 + i * n_phi + (j % n_phi)
    def bi(i, j): return fi(i, j) if i == n_u - 1 else nf + i * n_phi + (j % n_phi)
    faces = []
    for j in range(n_phi):
        faces.append((0, fi(0, j), fi(0, j + 1)))
        faces.append((bc, bi(0, j + 1), bi(0, j)))
    for i in range(n_u - 1):
        for j in range(n_phi):
            faces.append((fi(i, j), fi(i + 1, j), fi(i + 1, j + 1), fi(i, j + 1)))
            faces.append((bi(i, j), bi(i, j + 1), bi(i + 1, j + 1), bi(i + 1, j)))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces); me.update()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me, float(rmax.max())


def build_plate_mesh(S, rmax, n_t=48, n_phi=256, lift=0.006, grow=1.06):
    cx, cy = S["plate_c"]; a, b = S["plate_ab"]
    phi = np.linspace(0, 2 * np.pi, n_phi, endpoint=False)
    t = np.linspace(0, 1, n_t + 1)[1:]
    T, P = np.meshgrid(t, phi, indexing="ij")
    X = cx + grow * a * T * np.cos(P); Y = cy + grow * b * T * np.sin(P)
    Z = front_height(X, Y, S) + z_offset(X, Y, S, rmax) + lift
    z0 = float(front_height(np.array([cx]), np.array([cy]), S)[0] + z_offset(np.array([cx]), np.array([cy]), S, rmax)[0]) + lift
    verts = [(cx, cy, z0)] + [tuple(v) for v in np.stack([X, Y, Z], -1).reshape(-1, 3)]
    def vi(i, j): return 1 + i * n_phi + (j % n_phi)
    faces = [(0, vi(0, j), vi(0, j + 1)) for j in range(n_phi)]
    for i in range(n_t - 1):
        for j in range(n_phi):
            faces.append((vi(i, j), vi(i + 1, j), vi(i + 1, j + 1), vi(i, j + 1)))
    me = bpy.data.meshes.new("AstraPlate"); me.from_pydata(verts, [], faces); me.update()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return me


def core_shape(S):
    C = dict(S)
    C["arms"] = [(a, L * 0.94, rb * 0.58, rt * 0.68, curl, lift) for a, L, rb, rt, curl, lift in S["arms"]]
    C["core"] = S["core"] * 0.55
    C["smooth"] = 0.20
    C["inflate"] = S["inflate"] * 0.55
    C["dome"] = 0.0; C["plate_bulge"] = 0.0
    return C


def build_sparkles(S, rmax, n=10, seed=11):
    rng = np.random.default_rng(seed)
    cx, cy = S["plate_c"]; a, b = S["plate_ab"]
    pts = []
    while len(pts) < n:
        x, y = rng.uniform(-1.4, 1.4, 2)
        if sdf_smooth(np.array([x]), np.array([y]), S)[0] > -0.10: continue
        if ((x - cx) / a) ** 2 + ((y - cy) / b) ** 2 < 1.4: continue
        h = float(front_height(np.array([x]), np.array([y]), S)[0])
        z = h * rng.uniform(0.35, 0.7) + float(z_offset(np.array([x]), np.array([y]), S, rmax)[0])
        pts.append((x, y, z, rng.uniform(0.010, 0.024), rng.uniform(0, 0.8)))
    verts, faces = [], []
    for x, y, z, r, rot in pts:                 # flat 4-point star facing +z (camera)
        base = len(verts); verts.append((x, y, z))
        for k in range(8):
            ang = rot + k * math.pi / 4
            rr = r if k % 2 == 0 else r * 0.22
            verts.append((x + rr * math.cos(ang), y + rr * math.sin(ang), z))
        for k in range(8):
            faces.append((base, base + 1 + k, base + 1 + (k + 1) % 8))
    me = bpy.data.meshes.new("AstraSparkles"); me.from_pydata(verts, [], faces); me.update()
    return me


# --------------------------------------------------------------------------- face texture (SDF)
def _seg(px, py, ax, ay, bx, by, r):
    pax, pay, bax, bay = px - ax, py - ay, bx - ax, by - ay
    h = np.clip((pax * bax + pay * bay) / (bax * bax + bay * bay), 0, 1)
    return np.hypot(pax - bax * h, pay - bay * h) - r


def _arc(px, py, cx, cy, R, a0, a1, r):
    a0, a1 = math.radians(a0), math.radians(a1)
    ang = np.arctan2(py - cy, px - cx)
    am = (a0 + a1) / 2; hw = (a1 - a0) / 2
    da = np.angle(np.exp(1j * (ang - am)))
    d_arc = np.abs(np.hypot(px - cx, py - cy) - R) - r
    e0 = np.hypot(px - (cx + R * math.cos(a0)), py - (cy + R * math.sin(a0))) - r
    e1 = np.hypot(px - (cx + R * math.cos(a1)), py - (cy + R * math.sin(a1))) - r
    return np.where(np.abs(da) <= hw, d_arc, np.minimum(e0, e1))


def _ellipse(px, py, cx, cy, rx, ry):
    return (np.hypot((px - cx) / rx, (py - cy) / ry) - 1) * min(rx, ry)


def _heart(px, py, cx, cy, s):
    x = np.abs(px - cx) / s; y = (py - cy) / s + 0.55
    d1 = np.hypot(x - 0.25, y - 0.75) - math.sqrt(2) / 4
    m = 0.5 * np.maximum(x + y, 0)
    d2 = np.sqrt(np.minimum(x ** 2 + (y - 1) ** 2, (x - m) ** 2 + (y - m) ** 2)) * np.sign(x - y)
    return np.where(y + x > 1, d1, d2) * s


BLUSH_STATES = {"happy", "love", "sleep", "joyful"}


def face_fields(state, px, py):
    """px,py relative to plate centre. returns (sdf of white features, blush intensity 0..1)."""
    ex, ey = 0.155, 0.012
    W = 0.034
    U = []
    for sgn in (-1, 1):
        cx = sgn * ex
        if state in ("neutral", "peek"):
            U.append(_seg(px, py, cx - 0.006 * sgn, ey - 0.080, cx + 0.006 * sgn, ey + 0.080, 0.060))
        elif state == "happy":
            U.append(_arc(px, py, cx, ey - 0.035, 0.072, 15, 165, W))
        elif state == "joyful":
            U.append(_seg(px, py, cx - 0.065, ey - 0.030, cx, ey + 0.040, W))
            U.append(_seg(px, py, cx, ey + 0.040, cx + 0.065, ey - 0.030, W))
        elif state == "sleepy":
            U.append(_arc(px, py, cx, ey + 0.040, 0.072, 195, 345, W))
        elif state == "sleep":
            U.append(_arc(px, py, cx, ey + 0.085, 0.11, 238, 302, W))
        elif state == "surprised":
            U.append(_ellipse(px, py, cx, ey + 0.015, 0.072, 0.105))
        elif state == "excited":
            tip = cx - sgn * 0.02
            U.append(_seg(px, py, cx + sgn * 0.055, ey + 0.058, tip - sgn * 0.030, ey, W))
            U.append(_seg(px, py, tip - sgn * 0.030, ey, cx + sgn * 0.055, ey - 0.058, W))
        elif state == "confused":
            U.append(np.abs(np.hypot(px - cx, py - ey) - 0.066) - 0.019)
            U.append(np.hypot(px - cx, py - ey) - 0.028)
        elif state == "angry":
            U.append(_seg(px, py, cx, ey - 0.055, cx, ey - 0.005, 0.050))
            U.append(_seg(px, py, cx + sgn * 0.095, ey + 0.150, cx - sgn * 0.050, ey + 0.085, 0.026))
        elif state == "determined":
            U.append(_seg(px, py, cx, ey - 0.050, cx, ey + 0.020, 0.055))
            U.append(_seg(px, py, cx + sgn * 0.090, ey + 0.135, cx - sgn * 0.055, ey + 0.110, 0.024))
        elif state == "thinking":
            U.append(_seg(px, py, cx, ey - 0.060, cx, ey + 0.080, 0.058))
        elif state == "love":
            U.append(_heart(px, py, cx, ey, 0.105))
        else:
            raise ValueError(state)
    # mouths
    my = -0.185
    if state == "surprised":
        U.append(np.abs(_ellipse(px, py, 0.0, my, 0.030, 0.036)) - 0.011)
    elif state == "thinking":
        U.append(_seg(px, py, 0.015, my + 0.005, 0.070, my - 0.008, 0.012))
    elif state == "joyful":
        U.append(_arc(px, py, 0.0, my + 0.03, 0.035, 205, 335, 0.012))
    white = np.minimum.reduce(U)
    blush = np.zeros_like(px)
    if state in BLUSH_STATES:
        for sgn in (-1, 1):
            q = ((px - sgn * 0.285) / 0.075) ** 2 + ((py - (ey - 0.115)) / 0.038) ** 2
            blush = np.maximum(blush, np.exp(-q * 1.6))
    return white, blush


FACE_BOX = (-0.62, 0.62, -0.46, 0.46)    # plate-relative region covered by the face texture


def make_face_image(state, res=1024):
    x0, x1, y0, y1 = FACE_BOX
    xs = np.linspace(x0, x1, res); ys = np.linspace(y0, y1, res)
    PX, PY = np.meshgrid(xs, ys)               # row 0 = bottom (Blender image order)
    d, blush = face_fields(state, PX, PY)
    cov = np.clip(0.5 - d / (1.2 * (x1 - x0) / res), 0, 1)
    img = bpy.data.images.get("AstraFace") or bpy.data.images.new("AstraFace", res, res, alpha=False)
    rgba = np.stack([cov, blush, np.zeros_like(cov), np.ones_like(cov)], -1).astype(np.float32)
    img.pixels.foreach_set(rgba.ravel()); img.update()
    return img


# --------------------------------------------------------------------------- materials
def _n(nt, typ, name, loc):
    n = nt.nodes.new(typ); n.name = n.label = name; n.location = loc; return n


def _gradient(nt, rmax, loc=(-1400, 300)):
    """radial ramp + top-left / bottom accents in object space -> colour socket, rad socket."""
    L = nt.links.new
    x0, y0 = loc
    tc = _n(nt, "ShaderNodeTexCoord", "tc", (x0 - 200, y0))
    sep = _n(nt, "ShaderNodeSeparateXYZ", "sep", (x0, y0 - 300)); L(tc.outputs["Object"], sep.inputs[0])
    xy = _n(nt, "ShaderNodeVectorMath", "xy", (x0, y0)); xy.operation = "MULTIPLY"
    xy.inputs[1].default_value = (1, 1, 0); L(tc.outputs["Object"], xy.inputs[0])
    vl = _n(nt, "ShaderNodeVectorMath", "len", (x0 + 200, y0)); vl.operation = "LENGTH"; L(xy.outputs[0], vl.inputs[0])
    rn = _n(nt, "ShaderNodeMapRange", "rad", (x0 + 400, y0)); rn.inputs["From Max"].default_value = rmax
    L(vl.outputs["Value"], rn.inputs["Value"])
    ramp = _n(nt, "ShaderNodeValToRGB", "ramp", (x0 + 600, y0)); L(rn.outputs[0], ramp.inputs[0])
    ramp.color_ramp.elements[0].position = 0.30; ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements.new(0.70)
    tf = _n(nt, "ShaderNodeMath", "topf", (x0 + 200, y0 - 300)); tf.operation = "MULTIPLY_ADD"
    L(sep.outputs["Y"], tf.inputs[0]); tf.inputs[1].default_value = 0.50; tf.inputs[2].default_value = -0.30
    tfx = _n(nt, "ShaderNodeMath", "topf2", (x0 + 400, y0 - 300)); tfx.operation = "MULTIPLY_ADD"; tfx.use_clamp = True
    L(sep.outputs["X"], tfx.inputs[0]); tfx.inputs[1].default_value = -0.20; L(tf.outputs[0], tfx.inputs[2])
    bf = _n(nt, "ShaderNodeMath", "botf", (x0 + 200, y0 - 500)); bf.operation = "MULTIPLY_ADD"; bf.use_clamp = True
    L(sep.outputs["Y"], bf.inputs[0]); bf.inputs[1].default_value = -0.85; bf.inputs[2].default_value = -0.25
    m1 = _n(nt, "ShaderNodeMix", "mixTop", (x0 + 800, y0)); m1.data_type = "RGBA"
    L(tfx.outputs[0], m1.inputs["Factor"]); L(ramp.outputs["Color"], m1.inputs["A"])
    m2 = _n(nt, "ShaderNodeMix", "mixBot", (x0 + 1000, y0)); m2.data_type = "RGBA"
    L(bf.outputs[0], m2.inputs["Factor"]); L(m1.outputs["Result"], m2.inputs["A"])
    return m2.outputs["Result"], rn.outputs[0]


def build_shell_material(rmax):
    """glass shell: transmission + coat, tinted by the gradient, rim glow + thin rim line."""
    mat = bpy.data.materials.new("AstraGlass"); mat.use_nodes = True
    nt = mat.node_tree; nt.nodes.clear(); L = nt.links.new
    out = _n(nt, "ShaderNodeOutputMaterial", "out", (1600, 0))
    base, rad = _gradient(nt, rmax)
    lw = _n(nt, "ShaderNodeLayerWeight", "lw", (-600, -400)); lw.inputs["Blend"].default_value = 0.5
    rp = _n(nt, "ShaderNodeMath", "rimpow", (-400, -400)); rp.operation = "POWER"
    L(lw.outputs["Facing"], rp.inputs[0]); rp.inputs[1].default_value = 3.0
    gk = _n(nt, "ShaderNodeMath", "glowmix", (-200, -400)); gk.operation = "MULTIPLY_ADD"
    L(rp.outputs[0], gk.inputs[0]); gk.inputs[1].default_value = 2.2; gk.inputs[2].default_value = 0.04
    gs = _n(nt, "ShaderNodeMath", "glowk", (0, -400)); gs.operation = "MULTIPLY"
    L(gk.outputs[0], gs.inputs[0]); gs.inputs[1].default_value = 1.0
    gm = _n(nt, "ShaderNodeMix", "glowcol", (0, -150)); gm.data_type = "RGBA"
    L(rp.outputs[0], gm.inputs["Factor"]); L(base, gm.inputs["A"])

    g = _n(nt, "ShaderNodeBsdfPrincipled", "body", (300, 200))
    # tint: lighter version of the gradient so transmitted light keeps its colour
    tint = _n(nt, "ShaderNodeMix", "tint", (100, 300)); tint.data_type = "RGBA"
    tint.inputs["Factor"].default_value = 0.15; L(base, tint.inputs["A"]); tint.inputs["B"].default_value = (1, 1, 1, 1)
    L(tint.outputs["Result"], g.inputs["Base Color"])
    g.inputs["Transmission Weight"].default_value = 1.0
    g.inputs["Roughness"].default_value = 0.05
    g.inputs["IOR"].default_value = 1.33
    g.inputs["Coat Weight"].default_value = 1.0
    g.inputs["Coat Roughness"].default_value = 0.02
    L(gm.outputs["Result"], g.inputs["Emission Color"]); L(gs.outputs[0], g.inputs["Emission Strength"])

    lw2 = _n(nt, "ShaderNodeLayerWeight", "lw2", (-200, 600)); lw2.inputs["Blend"].default_value = 0.5
    rp2 = _n(nt, "ShaderNodeMath", "rim2pow", (0, 600)); rp2.operation = "POWER"
    L(lw2.outputs["Facing"], rp2.inputs[0]); rp2.inputs[1].default_value = 7.0
    rs2 = _n(nt, "ShaderNodeMath", "rim2k", (200, 600)); rs2.operation = "MULTIPLY"
    L(rp2.outputs[0], rs2.inputs[0]); rs2.inputs[1].default_value = 3.5
    rc2 = _n(nt, "ShaderNodeMix", "rim2col", (200, 800)); rc2.data_type = "RGBA"
    rc2.inputs["Factor"].default_value = 0.70; L(gm.outputs["Result"], rc2.inputs["A"]); rc2.inputs["B"].default_value = (1, 1, 1, 1)
    em2 = _n(nt, "ShaderNodeEmission", "rim2", (400, 700))
    L(rc2.outputs["Result"], em2.inputs["Color"]); L(rs2.outputs[0], em2.inputs["Strength"])
    add = _n(nt, "ShaderNodeAddShader", "bodyrim", (900, 300))
    L(g.outputs[0], add.inputs[0]); L(em2.outputs[0], add.inputs[1])
    # thin absorbing volume: thicker glass = deeper colour
    vol = _n(nt, "ShaderNodeVolumeAbsorption", "absorb", (900, -200))
    vol.inputs["Density"].default_value = 0.35
    L(add.outputs[0], out.inputs["Surface"]); L(vol.outputs[0], out.inputs["Volume"])
    return mat


def build_core_material(rmax):
    """inner light: emission brightest toward the tips, fades out at its own silhouette."""
    mat = bpy.data.materials.new("AstraCoreLight"); mat.use_nodes = True
    nt = mat.node_tree; nt.nodes.clear(); L = nt.links.new
    out = _n(nt, "ShaderNodeOutputMaterial", "out", (1400, 0))
    base, rad = _gradient(nt, rmax)
    cm = _n(nt, "ShaderNodeMix", "innercol", (-200, 300)); cm.data_type = "RGBA"
    sq = _n(nt, "ShaderNodeMath", "radsq", (-200, 0)); sq.operation = "POWER"
    L(rad, sq.inputs[0]); sq.inputs[1].default_value = 2.0
    L(sq.outputs[0], cm.inputs["Factor"])                         # inner colour -> tip glow colour
    st = _n(nt, "ShaderNodeMath", "inner_strength", (0, 0)); st.operation = "MULTIPLY_ADD"
    L(sq.outputs[0], st.inputs[0]); st.inputs[1].default_value = 5.5; st.inputs[2].default_value = 0.20
    gk = _n(nt, "ShaderNodeMath", "glowk", (200, 0)); gk.operation = "MULTIPLY"
    L(st.outputs[0], gk.inputs[0]); gk.inputs[1].default_value = 1.0
    mixc = _n(nt, "ShaderNodeMix", "withgrad", (0, 300)); mixc.data_type = "RGBA"
    mixc.inputs["Factor"].default_value = 0.50; L(cm.outputs["Result"], mixc.inputs["A"]); L(base, mixc.inputs["B"])
    em = _n(nt, "ShaderNodeEmission", "em", (400, 200))
    L(mixc.outputs["Result"], em.inputs["Color"]); L(gk.outputs[0], em.inputs["Strength"])
    lw = _n(nt, "ShaderNodeLayerWeight", "lw", (200, -300)); lw.inputs["Blend"].default_value = 0.5
    fp = _n(nt, "ShaderNodeMath", "fadepow", (400, -300)); fp.operation = "POWER"
    L(lw.outputs["Facing"], fp.inputs[0]); fp.inputs[1].default_value = 0.6
    tr = _n(nt, "ShaderNodeBsdfTransparent", "tr", (400, -100))
    mix = _n(nt, "ShaderNodeMixShader", "mix", (800, 0))
    L(fp.outputs[0], mix.inputs[0]); L(em.outputs[0], mix.inputs[1]); L(tr.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return mat


def build_sparkle_material():
    mat = bpy.data.materials.new("AstraSparkle"); mat.use_nodes = True
    nt = mat.node_tree; nt.nodes.clear()
    out = _n(nt, "ShaderNodeOutputMaterial", "out", (400, 0))
    em = _n(nt, "ShaderNodeEmission", "em", (0, 0))
    em.inputs["Color"].default_value = (1, 0.92, 1, 1); em.inputs["Strength"].default_value = 14.0
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    return mat


def build_plate_material(S):
    mat = bpy.data.materials.new("AstraPlate"); mat.use_nodes = True
    nt = mat.node_tree; nt.nodes.clear(); L = nt.links.new
    out = _n(nt, "ShaderNodeOutputMaterial", "out", (1600, 0))
    tc = _n(nt, "ShaderNodeTexCoord", "tc", (-1600, 0))
    cx, cy = S["plate_c"]; a, b = S["plate_ab"]
    mp = _n(nt, "ShaderNodeMapping", "platemap", (-1400, -300))
    mp.inputs["Location"].default_value = (-cx / a, -cy / b, 0); mp.inputs["Scale"].default_value = (1 / a, 1 / b, 0)
    L(tc.outputs["Object"], mp.inputs["Vector"])
    pl = _n(nt, "ShaderNodeVectorMath", "plen", (-1200, -300)); pl.operation = "LENGTH"; L(mp.outputs[0], pl.inputs[0])
    pm = _n(nt, "ShaderNodeMapRange", "pmask", (-1000, -300)); pm.interpolation_type = "SMOOTHERSTEP"
    pm.inputs["From Min"].default_value = 1.04; pm.inputs["From Max"].default_value = 0.94
    L(pl.outputs["Value"], pm.inputs["Value"])
    x0, x1, y0, y1 = FACE_BOX
    em_ = _n(nt, "ShaderNodeMapping", "facemap", (-1400, -700))
    em_.inputs["Location"].default_value = (-(cx + x0) / (x1 - x0), -(cy + y0) / (y1 - y0), 0)
    em_.inputs["Scale"].default_value = (1 / (x1 - x0), 1 / (y1 - y0), 1)
    L(tc.outputs["Object"], em_.inputs["Vector"])
    img = _n(nt, "ShaderNodeTexImage", "face", (-1200, -700)); img.extension = "CLIP"
    L(em_.outputs[0], img.inputs["Vector"])
    sp = _n(nt, "ShaderNodeSeparateColor", "facesep", (-900, -700)); L(img.outputs["Color"], sp.inputs[0])
    # base colour: plate -> white features
    pc = _n(nt, "ShaderNodeMix", "platecol", (-600, -400)); pc.data_type = "RGBA"
    L(sp.outputs["Red"], pc.inputs["Factor"]); pc.inputs["B"].default_value = (1, 1, 1, 1)
    # emission: white features * 3 + blush colour * 1.2
    ew = _n(nt, "ShaderNodeMix", "emcol", (-600, -800)); ew.data_type = "RGBA"
    L(sp.outputs["Red"], ew.inputs["Factor"]); ew.inputs["B"].default_value = (1, 0.97, 1, 1)
    bsum = _n(nt, "ShaderNodeMath", "blushk", (-700, -1000)); bsum.operation = "MULTIPLY"
    L(sp.outputs["Green"], bsum.inputs[0]); bsum.inputs[1].default_value = 0.9
    ws = _n(nt, "ShaderNodeMath", "whitek", (-700, -1150)); ws.operation = "MULTIPLY"
    L(sp.outputs["Red"], ws.inputs[0]); ws.inputs[1].default_value = 3.0
    es = _n(nt, "ShaderNodeMath", "emstr", (-500, -1100)); es.operation = "ADD"
    L(bsum.outputs[0], es.inputs[0]); L(ws.outputs[0], es.inputs[1])
    p = _n(nt, "ShaderNodeBsdfPrincipled", "plate", (0, -400))
    L(pc.outputs["Result"], p.inputs["Base Color"])
    p.inputs["Roughness"].default_value = 0.5
    p.inputs["Specular IOR Level"].default_value = 0.05
    p.inputs["Coat Weight"].default_value = 0.5
    p.inputs["Coat Roughness"].default_value = 0.06
    L(ew.outputs["Result"], p.inputs["Emission Color"]); L(es.outputs[0], p.inputs["Emission Strength"])
    tr = _n(nt, "ShaderNodeBsdfTransparent", "tr", (0, 0))
    mix = _n(nt, "ShaderNodeMixShader", "mix", (800, 0))
    L(pm.outputs[0], mix.inputs[0]); L(tr.outputs[0], mix.inputs[1]); L(p.outputs[0], mix.inputs[2])
    L(mix.outputs[0], out.inputs["Surface"])
    return mat


def _set_grad(nt, c):
    els = sorted(nt.nodes["ramp"].color_ramp.elements, key=lambda e: e.position)
    els[0].color = (*c["core"], 1); els[1].color = (*c["mid"], 1); els[2].color = (*c["edge"], 1)
    nt.nodes["mixTop"].inputs["B"].default_value = (*c["top"], 1)
    nt.nodes["mixBot"].inputs["B"].default_value = (*c["bottom"], 1)
    slope, icpt = c.get("bot_k", (-0.85, -0.25))
    nt.nodes["botf"].inputs[1].default_value = slope; nt.nodes["botf"].inputs[2].default_value = icpt


def apply_colorway(name):
    c = COLORWAYS[name]
    g = bpy.data.materials["AstraGlass"].node_tree
    _set_grad(g, c)
    g.nodes["glowcol"].inputs["B"].default_value = (*c["glow"], 1)
    g.nodes["glowk"].inputs[1].default_value = c["glow_k"]
    g.nodes["absorb"].inputs["Color"].default_value = (*c["mid"], 1)
    k = bpy.data.materials["AstraCoreLight"].node_tree
    _set_grad(k, c)
    k.nodes["innercol"].inputs["A"].default_value = (*c["inner"], 1)
    k.nodes["innercol"].inputs["B"].default_value = (*c["tipglow"], 1)
    k.nodes["glowk"].inputs[1].default_value = c["glow_k"]
    p = bpy.data.materials["AstraPlate"].node_tree
    p.nodes["platecol"].inputs["A"].default_value = (*c["plate"], 1)
    p.nodes["emcol"].inputs["A"].default_value = (*c["blush"], 1)
    bpy.data.objects["RimA"].data.color = c["rimA"]
    bpy.data.objects["RimB"].data.color = c["rimB"]


# --------------------------------------------------------------------------- scene
def _aim(ob, loc, target):
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()


def add_area(name, loc, target, size, power, color, shape="DISK"):
    ld = bpy.data.lights.new(name, "AREA"); ld.shape = shape; ld.size = size
    ld.energy = power; ld.color = color
    ob = bpy.data.objects.new(name, ld); bpy.context.scene.collection.objects.link(ob)
    _aim(ob, loc, target); ob.visible_camera = False
    return ob


def _surface_point(me, mw, local_xy, front=True):
    """nearest front vertex to local (x,y) -> world position & world normal."""
    n = len(me.vertices)
    co = np.empty(n * 3); me.vertices.foreach_get("co", co); co = co.reshape(-1, 3)
    no = np.empty(n * 3); me.vertices.foreach_get("normal", no); no = no.reshape(-1, 3)
    sel = no[:, 2] > 0.05 if front else np.ones(n, bool)
    idx = np.where(sel)[0]
    d = np.hypot(co[idx, 0] - local_xy[0], co[idx, 1] - local_xy[1])
    i = idx[np.argmin(d)]
    p = mw @ Vector(co[i]); nrm = (mw.to_3x3() @ Vector(no[i])).normalized()
    return p, nrm


def place_glint(name, me, mw, cam, local_xy, dist, size, power, receivers):
    """put a glossy-only light exactly where its reflection lands on local_xy."""
    p, nrm = _surface_point(me, mw, local_xy)
    v = (p - cam.location).normalized()
    r = v - 2 * v.dot(nrm) * nrm
    ob = add_area(name, tuple(p + r * dist), tuple(p), size, power, (1, 1, 1))
    ob.visible_diffuse = False; ob.visible_transmission = False; ob.visible_volume_scatter = False
    ob.light_linking.receiver_collection = receivers
    return ob


def build_scene(S):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    root = bpy.data.objects.new("AstraRoot", None); sc.collection.objects.link(root)
    root.rotation_euler = (math.radians(90 - 6), 0, math.radians(-8))   # front -> camera, slight 3/4

    me, rmax = build_star_mesh("AstraBody", S)
    body = bpy.data.objects.new("AstraBody", me); sc.collection.objects.link(body); body.parent = root
    me.materials.append(build_shell_material(rmax))

    C = core_shape(S)
    cme, _ = build_star_mesh("AstraCore", C, n_phi=360, n_u=60, rmax_ref=rmax)
    core = bpy.data.objects.new("AstraCore", cme); sc.collection.objects.link(core); core.parent = root
    cme.materials.append(build_core_material(rmax))
    core.visible_shadow = False

    spm = build_sparkles(S, rmax)
    spk = bpy.data.objects.new("AstraSparkles", spm); sc.collection.objects.link(spk); spk.parent = root
    spm.materials.append(build_sparkle_material()); spk.visible_shadow = False

    pme = build_plate_mesh(S, rmax)
    plate = bpy.data.objects.new("AstraPlate", pme); sc.collection.objects.link(plate); plate.parent = root
    pme.materials.append(build_plate_material(S))
    bpy.data.materials["AstraPlate"].node_tree.nodes["face"].image = make_face_image("neutral")

    # camera
    cd = bpy.data.cameras.new("Cam"); cd.lens = 85
    cam = bpy.data.objects.new("Cam", cd); sc.collection.objects.link(cam); sc.camera = cam
    _aim(cam, (0, -8.6, 0.75), (0, 0, 0))

    # base lights (soft, low): key + coloured rims
    base_lights = [add_area("Key", (-4.5, -5.0, 5.0), (0, 0, 0), 3.0, 120, (1.0, 0.97, 0.95)),
                   add_area("RimA", (4.5, 3.0, 1.5), (0, 0, 0), 2.5, 1600, (1.0, 0.4, 0.8), shape="RECTANGLE"),
                   add_area("RimB", (-4.5, 3.0, -0.5), (0, 0, 0), 2.5, 1400, (0.3, 0.45, 1.0), shape="RECTANGLE")]

    # glint lights: glossy only, linked to the shell only (never touch the plate)
    bpy.context.view_layer.update()
    shell_rx = bpy.data.collections.new("GlintReceivers"); shell_rx.objects.link(body)
    plate_rx = bpy.data.collections.new("PlateGlintReceivers"); plate_rx.objects.link(plate)
    for lo in base_lights:                     # the plate only ever sees its own single glint
        lo.light_linking.receiver_collection = shell_rx
    mw = body.matrix_world
    arms = S["arms"]
    def tip_xy(i, side, frac=0.92, outward=0.55):
        a, L, rb, rt, curl, lift = arms[i]
        t = math.radians(a + side)
        r = (L + rt) * frac
        return (r * math.cos(t) * 1.0, r * math.sin(t))
    targets = [(0, 12, 0.86), (4, 14, 0.84), (1, 12, 0.86), (3, -12, 0.82), (2, -12, 0.80)]
    for k, (i, side, fr) in enumerate(targets):
        place_glint(f"Glint{k}", me, mw, cam, tip_xy(i, side, fr), 6.0, 0.45, 650, shell_rx)
    # one soft glint on the plate, upper-left, clear of the left eye
    cx, cy = S["plate_c"]; a, b = S["plate_ab"]
    pw = plate.matrix_world
    place_glint("PlateGlint", pme, pw, cam, (cx - 0.60 * a, cy + 0.62 * b), 6.0, 0.5, 200, plate_rx)

    # world: dark navy + soft coloured spots (only visible in reflections; film is transparent)
    w = bpy.data.worlds.new("Night"); sc.world = w; w.use_nodes = True
    wn = w.node_tree; bg = wn.nodes["Background"]
    geo = wn.nodes.new("ShaderNodeNewGeometry")
    neg = wn.nodes.new("ShaderNodeVectorMath"); neg.operation = "SCALE"; neg.inputs["Scale"].default_value = -1.0
    wn.links.new(geo.outputs["Incoming"], neg.inputs[0])
    sepw = wn.nodes.new("ShaderNodeSeparateXYZ"); rw = wn.nodes.new("ShaderNodeValToRGB")
    wn.links.new(neg.outputs[0], sepw.inputs[0]); wn.links.new(sepw.outputs["Z"], rw.inputs[0])
    rw.color_ramp.elements[0].position = -0.2; rw.color_ramp.elements[0].color = (0.004, 0.004, 0.012, 1)
    rw.color_ramp.elements[1].position = 1.0; rw.color_ramp.elements[1].color = (0.05, 0.04, 0.10, 1)
    acc = rw.outputs["Color"]
    spots = [((0.95, 0.25, 0.15), 45, 2.5, (1.0, 0.45, 0.85)),     # pink rim right
             ((-0.95, 0.25, -0.1), 45, 2.2, (0.35, 0.5, 1.0)),     # blue rim left
             ((0.2, 0.4, -1.0), 60, 1.5, (1.0, 0.55, 0.35))]       # warm from below/behind
    for dvec, ang, stren, col in spots:
        dv = np.array(dvec, float); dv /= np.linalg.norm(dv)
        dp = wn.nodes.new("ShaderNodeVectorMath"); dp.operation = "DOT_PRODUCT"
        dp.inputs[1].default_value = tuple(dv); wn.links.new(neg.outputs[0], dp.inputs[0])
        mr = wn.nodes.new("ShaderNodeMapRange"); mr.interpolation_type = "SMOOTHSTEP"
        mr.inputs["From Min"].default_value = math.cos(math.radians(ang))
        mr.inputs["From Max"].default_value = math.cos(math.radians(ang * 0.35))
        mr.inputs["To Max"].default_value = stren
        wn.links.new(dp.outputs["Value"], mr.inputs["Value"])
        cm = wn.nodes.new("ShaderNodeMix"); cm.data_type = "RGBA"; cm.blend_type = "MULTIPLY"
        cm.inputs["Factor"].default_value = 1.0; cm.inputs["B"].default_value = (*col, 1)
        cv = wn.nodes.new("ShaderNodeCombineXYZ")
        for k in range(3): wn.links.new(mr.outputs[0], cv.inputs[k])
        wn.links.new(cv.outputs[0], cm.inputs["A"])
        mx = wn.nodes.new("ShaderNodeMix"); mx.data_type = "RGBA"; mx.blend_type = "ADD"; mx.clamp_result = False
        mx.inputs["Factor"].default_value = 1.0
        wn.links.new(acc, mx.inputs["A"]); wn.links.new(cm.outputs["Result"], mx.inputs["B"])
        acc = mx.outputs["Result"]
    wn.links.new(acc, bg.inputs["Color"]); bg.inputs["Strength"].default_value = 1.0

    # render settings
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    try:
        prefs.compute_device_type = "METAL"; prefs.get_devices()
        try: prefs.kernel_optimization_level = "OFF"     # avoids a flaky background specialisation crash
        except Exception: pass
        for dv in prefs.devices: dv.use = True
        sc.cycles.device = "GPU"
    except Exception as e:
        print("GPU setup failed, CPU:", e)
    sc.cycles.samples = 256
    sc.cycles.use_adaptive_sampling = True; sc.cycles.adaptive_threshold = 0.01
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 12; sc.cycles.transmission_bounces = 12; sc.cycles.transparent_max_bounces = 16
    sc.cycles.glossy_bounces = 4; sc.cycles.volume_bounces = 0
    sc.cycles.caustics_reflective = False; sc.cycles.caustics_refractive = False
    sc.render.film_transparent = True
    sc.render.resolution_x = sc.render.resolution_y = 1024
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.image_settings.color_depth = "8"
    sc.view_settings.view_transform = "Standard"; sc.view_settings.look = "None"
    return sc, root, body, plate


# --------------------------------------------------------------------------- post
def _blur(a, sigma):
    h, w = a.shape[:2]
    fy = np.fft.fftfreq(h)[:, None]; fx = np.fft.fftfreq(w)[None, :]
    g = np.exp(-2 * (np.pi * sigma) ** 2 * (fx ** 2 + fy ** 2))
    if a.ndim == 3:
        return np.stack([np.real(np.fft.ifft2(np.fft.fft2(a[..., c]) * g)) for c in range(a.shape[2])], -1)
    return np.real(np.fft.ifft2(np.fft.fft2(a) * g))


def postprocess(path, halo=True, peek_cut=None, warm=(1.0, 0.5, 0.35)):
    img = bpy.data.images.load(path, check_existing=False)
    img.colorspace_settings.name = "Non-Color"      # raw values in and out, no double gamma
    w, h = img.size
    px = np.empty(w * h * 4, np.float32); img.pixels.foreach_get(px)
    px = px.reshape(h, w, 4).astype(np.float64)
    rgb, a = px[..., :3], px[..., 3:4]
    if halo:
        k = w / 1024; P = 160
        pre = np.pad(rgb * a, ((P, P), (P, P), (0, 0))); ap = np.pad(a[..., 0], P)
        layers = []
        for sig, gain in ((20, 0.95), (60, 0.40)):          # tight bloom + wide bloom
            B = _blur(pre, sig * k)[P:-P, P:-P]; BA = _blur(ap, sig * k)[P:-P, P:-P][..., None]
            col = np.clip(np.where(BA > 1e-4, B / np.maximum(BA, 1e-4), 0) * 1.2, 0, 1)
            layers.append((np.clip(BA * gain, 0, 1), col))
        # warm under-glow: alpha blurred wide and shifted down
        BU = _blur(ap, 45 * k)[P:-P, P:-P]
        BU = np.roll(BU, -int(55 * k), axis=0)[..., None]                       # row 0 = bottom
        layers.append((np.clip(BU * 0.55, 0, 1), np.broadcast_to(np.array(warm), rgb.shape)))
        hsum = sum(h for h, _ in layers)
        hcol = sum(h * c for h, c in layers) / np.maximum(hsum, 1e-6)
        ha = (1 - np.prod([1 - h for h, _ in layers], axis=0)) * (1 - a)
        out_a = a + ha
        rgb = (rgb * a + hcol * ha) / np.maximum(out_a, 1e-6); a = out_a
    if peek_cut is not None:
        rows = np.arange(h)[:, None, None]                 # row 0 = bottom
        a = a * np.clip((rows - peek_cut) / 6.0, 0, 1)
    px = np.concatenate([np.clip(rgb, 0, 1), np.clip(a, 0, 1)], -1).astype(np.float32)
    img.pixels.foreach_set(px.ravel())
    img.filepath_raw = path; img.file_format = "PNG"; img.save()
    bpy.data.images.remove(img)


def peek_cut_row(sc, plate, S):
    """image row (from bottom) just below the eyes."""
    from bpy_extras.object_utils import world_to_camera_view
    bpy.context.view_layer.update()
    cx, cy = S["plate_c"]
    p, _ = _surface_point(plate.data, plate.matrix_world, (cx, cy - 0.30))
    return int(world_to_camera_view(sc, sc.camera, p).y * sc.render.resolution_y)


# --------------------------------------------------------------------------- main
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--colorways", default="nova")
    ap.add_argument("--states", default="neutral")
    ap.add_argument("--out", default=os.path.join(HERE, "renders"))
    ap.add_argument("--samples", type=int, default=256)
    ap.add_argument("--res", type=int, default=1024)
    ap.add_argument("--no-halo", action="store_true")
    ap.add_argument("--save-blend", default=os.path.join(HERE, "astra.blend"))
    ap.add_argument("--suffix", default="")
    ap.add_argument("--skip-existing", action="store_true")
    args = ap.parse_args(argv)
    cws = list(COLORWAYS) if args.colorways == "all" else args.colorways.split(",")
    sts = STATES if args.states == "all" else args.states.split(",")
    os.makedirs(args.out, exist_ok=True)

    sc, root, body, plate = build_scene(SHAPE)
    sc.cycles.samples = args.samples
    sc.render.resolution_x = sc.render.resolution_y = args.res
    apply_colorway(cws[0])
    if args.save_blend:
        bpy.data.images["AstraFace"].pack()
        bpy.ops.wm.save_as_mainfile(filepath=args.save_blend, compress=True)
    cut = peek_cut_row(sc, plate, SHAPE)
    face_node = bpy.data.materials["AstraPlate"].node_tree.nodes["face"]
    times = []
    for cw in cws:
        apply_colorway(cw)
        for st in sts:
            path = os.path.join(args.out, f"astra_{cw}_{st}{args.suffix}.png")
            if args.skip_existing and os.path.exists(path):
                continue
            face_node.image = make_face_image("neutral" if st == "peek" else st)
            # sleep: whole character gently relaxed (local x wider, local y lower)
            root.scale = (1.08, 0.86, 1.0) if st == "sleep" else (1, 1, 1)
            sc.render.filepath = path
            t0 = time.time()
            bpy.ops.render.render(write_still=True)
            postprocess(path, halo=not args.no_halo, peek_cut=cut if st == "peek" else None,
                        warm=COLORWAYS[cw].get("warm", COLORWAYS[cw]["bottom"]))
            dt = time.time() - t0; times.append(dt)
            print(f"RENDERED {path} {dt:.1f}s", flush=True)
    if times:
        print(f"AVG {sum(times)/len(times):.1f}s over {len(times)} images", flush=True)


if __name__ == "__main__":
    main()

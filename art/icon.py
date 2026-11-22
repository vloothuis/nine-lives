# Render the Nine Lives app icon: blender -b -P art/icon.py -- out.png
import bpy, math, sys
from mathutils import Vector

out = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

def toon(name, base, shade, light=None, steps=0.5):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    d = nt.nodes.new("ShaderNodeBsdfDiffuse")
    s2r = nt.nodes.new("ShaderNodeShaderToRGB")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "CONSTANT"
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = shade
    ramp.color_ramp.elements[1].position = steps
    ramp.color_ramp.elements[1].color = base
    if light:
        e = ramp.color_ramp.elements.new(0.9)
        e.color = light
    sep = nt.nodes.new("ShaderNodeRGBToBW")
    em = nt.nodes.new("ShaderNodeEmission")
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(d.outputs[0], s2r.inputs[0])
    nt.links.new(s2r.outputs[0], sep.inputs[0])
    nt.links.new(sep.outputs[0], ramp.inputs[0])
    nt.links.new(ramp.outputs[0], em.inputs[0])
    nt.links.new(em.outputs[0], o.inputs[0])
    return m

def flat(name, color):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs[0].default_value = color
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(em.outputs[0], o.inputs[0])
    return m

ink = flat("ink", (0.04, 0.03, 0.06, 1))
ink.use_backface_culling = True

def outline(obj, width):
    mod = obj.modifiers.new("outline", "SOLIDIFY")
    mod.thickness = width
    mod.offset = 1
    mod.use_flip_normals = True
    mod.material_offset = len(obj.data.materials)
    obj.data.materials.append(ink) if False else None

def make(obj, mat, width=0.035):
    obj.data.materials.append(mat)
    obj.data.materials.append(ink)
    mod = obj.modifiers.new("outline", "SOLIDIFY")
    mod.thickness = width
    mod.offset = 1
    mod.use_flip_normals = True
    mod.use_rim = False
    mod.material_offset = 1
    for p in obj.data.polygons:
        p.use_smooth = True
    return obj

def sphere(loc, scale, mat, seg=64, width=0.035):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=seg, ring_count=seg // 2, location=loc)
    o = bpy.context.object
    o.scale = scale
    bpy.ops.object.transform_apply(scale=True)
    return make(o, mat, width)

fur = toon("fur", (1.0, 0.62, 0.22, 1), (0.82, 0.36, 0.14, 1), (1.0, 0.78, 0.45, 1), 0.38)
cream = toon("cream", (1.0, 0.93, 0.8, 1), (0.88, 0.74, 0.6, 1))
pink = toon("pink", (1.0, 0.55, 0.62, 1), (0.85, 0.38, 0.5, 1))
eyew = toon("eyew", (1, 1, 1, 1), (0.8, 0.85, 0.95, 1))
green = flat("green", (0.55, 0.9, 0.35, 1))
dark = flat("dark", (0.04, 0.03, 0.06, 1))
plate = flat("plate", (0.40, 0.32, 0.88, 1))

# Background plate (rounded square)
bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0.6, 0))
p = bpy.context.object
p.scale = (4.0, 0.2, 4.0)
bpy.ops.object.transform_apply(scale=True)
bv = p.modifiers.new("bevel", "BEVEL")
bv.width = 0.6
bv.segments = 24
bv.limit_method = "NONE"
for poly in p.data.polygons:
    poly.use_smooth = True
p.data.materials.append(plate)

# Cat head
sphere((0, -0.05, 0), (0.72, 0.62, 0.55), fur)
# Ears
for sx in (-1, 1):
    bpy.ops.mesh.primitive_cone_add(vertices=48, radius1=0.26, depth=0.5,
        location=(sx * 0.46, 0, 0.5), rotation=(0, sx * math.radians(25), 0))
    e = bpy.context.object
    e.scale = (1, 0.55, 1)
    bpy.ops.object.transform_apply(scale=True)
    bv = e.modifiers.new("b", "BEVEL"); bv.width = 0.05; bv.segments = 6
    make(e, fur, 0.035)
    bpy.ops.mesh.primitive_cone_add(vertices=48, radius1=0.14, depth=0.3,
        location=(sx * 0.46, -0.16, 0.48), rotation=(math.radians(-8), sx * math.radians(25), 0))
    ei = bpy.context.object
    ei.scale = (1, 0.4, 1)
    bpy.ops.object.transform_apply(scale=True)
    ei.data.materials.append(pink)
# Muzzle
sphere((0, -0.62, -0.16), (0.3, 0.16, 0.2), cream, width=0.025)
# Eyes: small, round and glossy
for sx in (-1, 1):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, location=(sx * 0.3, -0.585, 0.1))
    e_ = bpy.context.object
    e_.scale = (0.075, 0.035, 0.095)
    bpy.ops.object.transform_apply(scale=True)
    for p_ in e_.data.polygons: p_.use_smooth = True
    e_.data.materials.append(dark)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, location=(sx * 0.3 - 0.022, -0.615, 0.135))
    hl = bpy.context.object
    hl.scale = (0.025, 0.012, 0.03)
    bpy.ops.object.transform_apply(scale=True)
    hl.data.materials.append(eyew)
# Nose
bpy.ops.mesh.primitive_cone_add(vertices=3, radius1=0.07, depth=0.04,
    location=(0, -0.76, -0.08), rotation=(math.radians(90), math.radians(180), 0))
n = bpy.context.object
n.data.materials.append(pink)

# Mouth: short line from the nose, then a "w" smile on the muzzle
def surf(x, z):
    t = 1 - (x / 0.3) ** 2 - ((z + 0.16) / 0.2) ** 2
    return -0.62 - 0.16 * math.sqrt(max(t, 0.0)) - 0.008
def path(pts, name):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = 0.013
    cu.bevel_resolution = 4
    cu.use_fill_caps = True
    sp = cu.splines.new("POLY")
    sp.points.add(len(pts) - 1)
    for pt, (x, z) in zip(sp.points, pts):
        pt.co = (x, surf(x, z), z, 1)
    ob = bpy.data.objects.new(name, cu)
    bpy.context.collection.objects.link(ob)
    ob.data.materials.append(dark)
path([(0, -0.115), (0, -0.165)], "philtrum")
for sx in (-1, 1):
    pts = []
    for i in range(13):
        t = i / 12
        pts.append((sx * 0.15 * t, -0.165 - 0.075 * math.sin(math.pi * t) + 0.03 * t))
    path(pts, "smile")

# Whiskers: tapered, fanned out from the muzzle
for sx in (-1, 1):
    for ang in (20, 2, -16):
        r = math.radians(ang)
        d = Vector((sx * math.cos(r), 0, math.sin(r)))
        start = Vector((sx * 0.3, -0.68, -0.12 + ang * 0.003))
        length = 0.55
        bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=0.016, radius2=0.004, depth=length,
            location=start + d * (length / 2),
            rotation=(0, math.atan2(d.x, d.z), 0))
        w = bpy.context.object
        for p_ in w.data.polygons: p_.use_smooth = True
        w.data.materials.append(dark)
# Forehead stripes
for dx in (-0.12, 0, 0.12):
    bpy.ops.mesh.primitive_cylinder_add(vertices=16, radius=0.03, depth=0.2 if dx == 0 else 0.15,
        location=(dx, -0.36, 0.44), rotation=(math.radians(-30), 0, math.radians(dx * 120)))
    s = bpy.context.object
    s.data.materials.append(toon("stripe", (0.62, 0.24, 0.1, 1), (0.5, 0.18, 0.08, 1)))

# Light & camera
bpy.ops.object.light_add(type="SUN", location=(2, -3, 4))
L = bpy.context.object
L.rotation_euler = (math.radians(50), math.radians(10), math.radians(30))
L.data.energy = 3
bpy.ops.object.camera_add(location=(0, -8, 0), rotation=(math.radians(90), 0, 0))
cam = bpy.context.object
cam.data.type = "ORTHO"
cam.data.ortho_scale = 2.4
scene.camera = cam

scene.render.resolution_x = scene.render.resolution_y = 1024
scene.render.film_transparent = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.engine = "BLENDER_EEVEE"
scene.view_settings.view_transform = "Standard"
scene.eevee.taa_render_samples = 64
scene.render.filepath = out
bpy.ops.render.render(write_still=True)

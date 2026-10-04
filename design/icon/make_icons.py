import cairosvg
MOON="#ECF1FF"; NAVY1="#14234A"; NAVY2="#060B1E"; GREEN="#8FE36A"

def bg(rounded=False):
    r = 'rx="224"' if rounded else ''
    return f'''<defs>
 <radialGradient id="g" cx="50%" cy="38%" r="75%"><stop offset="0" stop-color="{NAVY1}"/><stop offset="1" stop-color="{NAVY2}"/></radialGradient>
 <radialGradient id="eyeG" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#C9F7A8"/><stop offset="0.55" stop-color="{GREEN}"/><stop offset="1" stop-color="#3E8F2C"/></radialGradient>
 <linearGradient id="greenHead" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#B9EE8C"/><stop offset="1" stop-color="#5DB843"/></linearGradient>
 <radialGradient id="eyeN" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#2B3F78"/><stop offset="1" stop-color="#0A1330"/></radialGradient>
</defs>
<rect width="1024" height="1024" {r} fill="url(#g)"/>'''

def head(eye_fill, cy=430, s=1.0, moon=MOON, face_fill=None):
    face_fill = face_fill or moon
    def T(x,y): return f"{512+(x-512)*s:.1f},{cy+(y-430)*s:.1f}"
    face = (f'M{T(318,412)} C{T(380,372)} {T(440,390)} {T(512,392)} C{T(584,390)} {T(644,372)} {T(706,412)} '
            f'C{T(706,500)} {T(604,610)} {T(546,700)} L{T(512,742)} L{T(478,700)} C{T(420,610)} {T(318,500)} {T(318,412)} Z')
    ant = (f'<path d="M{T(494,396)} C{T(478,280)} {T(400,190)} {T(262,128)}" stroke="{moon}" stroke-width="{10*s:.1f}" fill="none" stroke-linecap="round"/>'
           f'<path d="M{T(530,396)} C{T(546,280)} {T(624,190)} {T(762,128)}" stroke="{moon}" stroke-width="{10*s:.1f}" fill="none" stroke-linecap="round"/>')
    eyes = ''
    for ex, rot in ((338, -28), (686, 28)):
        cx, cyy = T(ex, 400).split(',')
        eyes += (f'<ellipse cx="{cx}" cy="{cyy}" rx="{98*s:.1f}" ry="{116*s:.1f}" transform="rotate({rot} {cx} {cyy})" fill="{face_fill}"/>'
                 f'<ellipse cx="{cx}" cy="{cyy}" rx="{78*s:.1f}" ry="{96*s:.1f}" transform="rotate({rot} {cx} {cyy})" fill="{eye_fill}"/>')
        hx, hy = float(cx)-24*s, float(cyy)-34*s
        eyes += f'<circle cx="{hx:.1f}" cy="{hy:.1f}" r="{15*s:.1f}" fill="#FFFFFF" opacity="0.9"/>'
    ocelli = ''.join(f'<circle cx="{T(x,y).split(",")[0]}" cy="{T(x,y).split(",")[1]}" r="{9*s:.1f}" fill="#1E2D55" opacity="0.55"/>'
                     for x,y in ((512,430),(490,452),(534,452)))
    jaw = f'<path d="M{T(482,680)} Q{T(512,700)} {T(542,680)}" stroke="#8C98BE" stroke-width="{6*s:.1f}" fill="none" stroke-linecap="round" opacity="0.8"/>'
    return ant + f'<path d="{face}" fill="{face_fill}"/>' + ocelli + jaw + eyes

def corners(moon=MOON, inset=150, L=120, w=18):
    a, b = inset, 1024-inset
    p = [f'M{a},{a+L} L{a},{a} L{a+L},{a}', f'M{b-L},{a} L{b},{a} L{b},{a+L}',
         f'M{a},{b-L} L{a},{b} L{a+L},{b}', f'M{b-L},{b} L{b},{b} L{b},{b-L}']
    return ''.join(f'<path d="{d}" stroke="{moon}" stroke-width="{w}" fill="none" stroke-linecap="round" stroke-linejoin="round" opacity="0.9"/>' for d in p)

def arms(moon=MOON):
    # сложенные «молитвенные» передние лапы под головой
    l = (f'<path d="M430,700 C380,760 360,850 420,900 L470,880 C430,840 440,790 480,740 Z" fill="{moon}"/>'
         f'<path d="M594,700 C644,760 664,850 604,900 L554,880 C594,840 584,790 544,740 Z" fill="{moon}"/>')
    return l

def svg(body, rounded=False):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{bg(rounded)}{body}</svg>'

variants = {
  "A_green_eyes_frame": head("url(#eyeG)", cy=480, s=0.95) + corners(),
  "B_navy_eyes_frame":  head("url(#eyeN)", cy=480, s=0.95) + corners(),
  "C_green_head_frame": head("url(#eyeN)", cy=480, s=0.95, face_fill="url(#greenHead)") + corners(),
}
for name, body in variants.items():
    open(f"{name}.svg","w").write(svg(body))
    cairosvg.svg2png(bytestring=svg(body).encode(), write_to=f"{name}.png", output_width=1024, output_height=1024)
    cairosvg.svg2png(bytestring=svg(body, rounded=True).encode(), write_to=f"{name}_preview.png", output_width=360, output_height=360)
print("ok")

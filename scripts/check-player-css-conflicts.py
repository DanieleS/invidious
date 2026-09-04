#!/usr/bin/env python3
"""
Cerca i punti dove player.css prova a dire la sua su una proprietà che
video.js (o un suo plugin) gestisce già, e perde.

Perde in due casi:
  - la regola dell'altro ha specificità più alta;
  - la regola dell'altro ha `!important`;
  - la regola dell'altro sta in un foglio caricato DOPO il nostro
    (quality-selector.css), e ha specificità pari o superiore.
"""
import re
import sys

# ordine di caricamento, come in components/player_sources.ecr
BEFORE = [
    "assets/videojs/video.js/video-js.css",
    "assets/videojs/videojs-http-source-selector/videojs-http-source-selector.css",
    "assets/videojs/videojs-markers/videojs.markers.css",
    "assets/videojs/videojs-share/videojs-share.css",
    "assets/videojs/videojs-vtt-thumbnails/videojs-vtt-thumbnails.css",
    "assets/videojs/videojs-mobile-ui/videojs-mobile-ui.css",
]
OURS = "assets/css/player.css"
AFTER = ["assets/css/quality-selector.css"]


def strip_comments(css):
    return re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def rules(css):
    """(selettore, proprietà, valore, important) per ogni dichiarazione."""
    css = strip_comments(css)
    # le @media si appiattiscono: a noi interessa il conflitto, non quando
    css = re.sub(r"@media[^{]*\{", "", css)
    out = []
    for block in re.finditer(r"([^{}]+)\{([^{}]*)\}", css):
        selectors, body = block.group(1), block.group(2)
        decls = []
        for decl in body.split(";"):
            if ":" not in decl:
                continue
            prop, _, value = decl.partition(":")
            prop = prop.strip().lower()
            if not prop or prop.startswith("--"):
                continue
            decls.append((prop, value.strip().rstrip("!important").strip(),
                          "!important" in value))
        for sel in selectors.split(","):
            sel = sel.strip()
            if not sel:
                continue
            for prop, value, imp in decls:
                out.append((sel, prop, value, imp))
    return out


def specificity(sel):
    s = sel
    ids = len(re.findall(r"#[\w-]+", s))
    # :not(x) conta quello che ha dentro
    inside = " ".join(re.findall(r":not\(([^)]*)\)", s))
    s_no_not = re.sub(r":not\([^)]*\)", " ", s) + " " + inside
    classes = len(re.findall(r"\.[\w-]+", s_no_not))
    classes += len(re.findall(r"\[[^\]]+\]", s_no_not))
    classes += len(re.findall(r"(?<!:):(?!:)[a-z-]+", s_no_not))
    elements = len(re.findall(r"(?:^|[\s>+~])([a-z][\w-]*)", s_no_not))
    elements += len(re.findall(r"::[a-z-]+", s_no_not))
    return (ids, classes, elements)


def key_classes(sel):
    """Le classi dell'ultimo pezzo del selettore: chi viene davvero colpito."""
    last = re.split(r"[\s>+~]+", sel.strip())[-1]
    return set(re.findall(r"\.([\w-]+)", last))


def load(paths):
    out = []
    for p in paths:
        try:
            css = open(p, encoding="utf-8").read()
        except OSError:
            continue
        for sel, prop, value, imp in rules(css):
            out.append((p.split("/")[-1], sel, prop, value, imp))
    return out


ours = load([OURS])
before = load(BEFORE)
after = load(AFTER)

conflicts = []
for _, our_sel, our_prop, our_val, our_imp in ours:
    if our_imp:
        continue  # con !important abbiamo già vinto apposta
    our_spec = specificity(our_sel)
    our_keys = key_classes(our_sel)
    if not our_keys:
        continue

    for origin, sel, prop, value, imp in before:
        if prop != our_prop:
            continue
        if not (key_classes(sel) & our_keys):
            continue
        their_spec = specificity(sel)
        if imp or their_spec > our_spec:
            conflicts.append((our_sel, our_prop, our_val, origin, sel, value,
                              "!important" if imp else "%s > %s" % (their_spec, our_spec)))

    for origin, sel, prop, value, imp in after:
        if prop != our_prop:
            continue
        if not (key_classes(sel) & our_keys):
            continue
        their_spec = specificity(sel)
        if imp or their_spec >= our_spec:
            conflicts.append((our_sel, our_prop, our_val, origin, sel, value,
                              "caricato dopo di noi"))

seen = set()
print("%d conflitti\n" % len(conflicts))
for c in conflicts:
    k = (c[0], c[1], c[4])
    if k in seen:
        continue
    seen.add(k)
    print("NOSTRA  %s { %s: %s }" % (c[0], c[1], c[2]))
    print("PERDE   %s  [%s]" % (c[6], c[3]))
    print("        %s { %s: %s }" % (c[4][:150], c[1], c[5]))
    print()

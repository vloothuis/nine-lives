import itertools, random
random.seed(7)
parts = ["foo","bar","baz","b*","*","**","?ar","[ab]*","*.go","x\\*y","[^f]oo","[","."]
paths_parts = ["foo","bar","baz","bx","t.go","x*y","oo"]
out=[]
pats=set()
for n in range(1,4):
    for combo in itertools.product(parts, repeat=n):
        for root in ("", "/"):
            pats.add(root+"/".join(combo))
pats=sorted(pats)
paths=set()
for n in range(1,5):
    for combo in itertools.product(paths_parts, repeat=n):
        paths.add("/"+"/".join(combo))
paths=sorted(paths)
for p in pats:
    for s in random.sample(paths, 12):
        out.append(f"M\t{p}\t{s}")
for _ in range(20000):
    k=random.randint(1,4)
    ps=[("!" if random.random()<0.35 else "")+random.choice(pats) for _ in range(k)]
    out.append("L\t"+"\x1f".join(ps)+"\t"+random.choice(paths))
open("/tmp/nl-filtergen/in.txt","w").write("\n".join(out)+"\n")
print(len(out))

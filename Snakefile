KMERLEN = '20'
HASH_SIZE = "1e8"
METRICS = ['wip'] #, 'ip']
SETS = {}
ALLRUNS = set()
RUNPROJECTS = {}
SETPROJECTS = {}
for project, setruns in config.items():
    for setname, runs in setruns.items():
        SETPROJECTS[setname] = project
        SETS[setname] = runs
        for r in runs:
            ALLRUNS.add(r)
            RUNPROJECTS[r] = project

localrules: all, clean, sicklereads, mashdist

## BEGIN RULES
rule all:
    input:
        expand("data/kwip/{set}_{metric}.{mat}", set=SETS.keys(), metric=METRICS, mat=["dist", "kern"]),
        ["data/mash/{project}/{set}.dist".format(project=p, set=s)
             for s, p in SETPROJECTS.items()],

rule clean:
    shell:
        "rm -rf data .snakemake"

rule sra:
    output:
        "data/sra/{project}/{run}.sra",
    log:
        "data/log/getrun/{project}-{run}.log"
    shell:
        "wget -nv -c -O {output}"
        "   https://sra-download.ncbi.nlm.nih.gov/srapub/{wildcards.run}"
        " >{log} 2>&1"

rule sicklereads:
    input:
        "data/sra/{project}/{run}.sra",
    output:
        "data/tmp/reads/{project}/{run}_il.fastq",
    log:
        "data/log/sickle/{project}-{run}.log"
    shell:
        "( fastq-dump"
        "   --split-spot"
        "   --skip-technical"
        "   --stdout"
        "   --readids"
        "   --defline-seq '@$sn/$ri'"
        "   --defline-qual '+'"
        "   {input}"
        "| sickle se"
        "   -t sanger"
        "   -q 28"
        "   -l 1"  # Keep all reads
        "   -f /dev/stdin"
        "   -o {output}"
        ") >{log} 2>&1"


rule sketch:
    input:
        "data/tmp/reads/{project}/{run}_il.fastq"
    output:
        "data/counts/{project}/{run}.ct"
    params:
        x=HASH_SIZE,
        N='1',
        k=KMERLEN,
    threads:
        16
    log:
        "data/log/counts/{project}-{run}.log"
    benchmark:
        "data/benchmarks/sketch/{project}-{run}.tsv"
    shell:
        "load-into-counting.py"
        "   -N {params.N}"
        "   -x {params.x}"
        "   -k {params.k}"
        "   -T {threads}"
        "   -f"
        "   -b"
        "   -s tsv"
        "   {output}"
        "   {input}"
        "   >{log} 2>&1"


rule kwip:
    input:
        lambda wc: ["data/counts/{project}/{run}.ct".format(project=RUNPROJECTS[r], run=r)
                    for r in SETS[wc.set]]
    output:
        d="data/kwip/{set}_{metric}.dist",
        k="data/kwip/{set}_{metric}.kern"
    params:
        metric=lambda w: '-U' if w.metric == 'ip' else '',
    log:
        "data/log/kwip/{set}-{metric}.log"
    benchmark:
        "data/benchmarks/kwip/{set}-{metric}.tsv"
    threads:
        16
    shell:
        "kwip"
        " {params.metric}"
        " -d {output.d}"
        " -k {output.k}"
        " -t {threads}"
        " {input}"
        " >{log} 2>&1"


rule kwip_stats:
    input:
        lambda wc: ["data/counts/{project}/{run}.ct".format(project=RUNPROJECTS[r], run=r)
                    for r in SETS[wc.set]]
    output:
        "data/kwip/{set}.stat"
    log:
        "data/log/kwip-stats/{set}.log"
    threads:
        16
    shell:
        "kwip-stats"
        " -o {output}"
        " -t {threads}"
        " {input}"
        " >{log} 2>&1"

rule mashsketch:
    input:
        lambda wc: ["data/tmp/reads/{project}/{run}_il.fastq".format(project=RUNPROJECTS[r], run=r)
                    for r in SETS[wc.set]]
    output:
        sketch=temp("data/tmp/mashsketch/{project}/{set}_allsketch.msh"),
    log:
        "data/log/mashsketch/{project}-{set}.log"
    benchmark:
        "data/bench/mashsketch/{project}-{set}.tsv"
    threads:
        16
    params:
        min_abund='2',
        k=KMERLEN,
        sketch_size=10000,
    shell:
        "(mash sketch "
        "   -p {threads} "
        "   -s {params.sketch_size} "
        "   -k {params.k}"
        "   -o {output.sketch} "
        "   -m {params.min_abund} "
        "   {input}"
        ") >{log} 2>&1"


rule mash:
    input:
        sketch=temp("data/tmp/mashsketch/{project}/{set}_allsketch.msh"),
    output:
        mashdist="data/mash/{project}/{set}.mashdist",
    benchmark:
        "data/benchmarks/mash/{project}_{set}.tsv",
    log:
        "data/log/mash/{project}_{set}.log",
    threads:
        16
    shell:
        "(mash dist -p {threads} {input} {input}"
        " > {output.mashdist}"
        ") >{log} 2>&1"


rule mashdist:
    input:
        "data/mash/{project}/{set}.mashdist",
    output:
        "data/mash/{project}/{set}.dist",
    run:
        from collections import defaultdict
        from os.path import basename
        def fname2id(fname):
            fname = basename(fname)
            exts = [".gz", ".fastq" "_il"]
            for ext in exts:
                if fname.endswith(ext):
                    fname = fname[:-len(ext)]
            return fname

        dists = defaultdict(dict)
        with open(input[0]) as fh:
            for line in fh:
                dist = line.strip().split('\t')
                id1 = fname2id(dist[0])
                id2 = fname2id(dist[1])
                dist = float(dist[2])
                dists[id1][id2] = dist

        with open(output[0], 'w') as ofile:
            ids = [''] + list(sorted(dists.keys()))
            print(*ids, sep='\t', file=ofile)
            for id1, row in sorted(dists.items()):
                rowdists = [it[1] for it in sorted(row.items())]
                print(id1, *rowdists, sep='\t', file=ofile)

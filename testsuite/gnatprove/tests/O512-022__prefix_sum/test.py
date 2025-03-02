from test_support import prove_all

contains_manual_proof = False

options = [
    "--function-sandboxing=off",
    "--proof-warnings",
    "-u",
    "prefixsum.adb",
    "prefixsum_expanded.adb",
    "prefixsum_general.adb",
    "--counterexamples=off",
]


def replay():
    prove_all(procs=0, steps=0, vc_timeout=20, opt=options)


if __name__ == "__main__":
    prove_all(replay=True, opt=options)

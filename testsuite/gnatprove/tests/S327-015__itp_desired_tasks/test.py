from test_support import prove_all

# This test checks that manual proof task/parser extension work by calling
# replay on session that contains transformation with arguments making use of
# this.

contains_manual_proof = True


def replay():
    prove_all(procs=10, counterexample=False, prover=["cvc5", "z3"])


if __name__ == "__main__":
    prove_all(replay=True)

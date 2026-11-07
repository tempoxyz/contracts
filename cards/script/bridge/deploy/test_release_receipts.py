#!/usr/bin/env python3
"""Offline receipt regressions: python3 cards/script/bridge/deploy/test_release_receipts.py."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
CAST = shutil.which("cast")
FACTORY = "0x" + "11" * 20
ROUTER_FACTORY = "0x" + "22" * 20
PROGRAM_ID = "0x" + "33" * 32
HASH = "0x" + "ab" * 32
OTHER_HASH = "0x" + "cd" * 32
CREATION_CODE = "0x6000"
CREATE2_DEPLOYER = "0x4e59b44847b379578588920ca78fbf26c0b4956c"


def cast(*args):
    # Only pure encoding/hashing commands are used, never an RPC.
    assert args[0] in ("keccak", "abi-encode", "calldata")
    return subprocess.check_output([CAST, *args], text=True, timeout=60).strip()


def address_topic(address):
    return "0x" + "0" * 24 + address[2:]


def create2(creator, salt, init):
    digest = cast("keccak", "0xff" + creator[2:] + salt[2:] + cast("keccak", init)[2:])
    return "0x" + digest[-40:]


# Real release.sh runs in an isolated directory. These fixtures reject unknown commands, so no
# broadcast, RPC or source-verifier request can escape the test; only cast's pure codecs run.
COMMANDS = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["RECEIPT_TEST_ROOT"])
fixture = json.loads((root / "fixture.json").read_text())
command, args = Path(sys.argv[0]).name, sys.argv[1:]
sent = root / "broadcast-done"
verified = root / "verified"
if command == "cast":
    if args == ["chain-id"]:
        print(42431)
    elif args == ["rpc", "tempo_forkSchedule"]:
        print('{"active":"T4"}')
    elif len(args) == 2 and args[0] == "code":
        missing = fixture["missingAfter"] if sent.exists() else fixture["missing"]
        print("0x" if args[1].lower() in missing else "0x6000")
    elif args and args[0] in ("keccak", "abi-encode", "calldata", "to-check-sum-address"):
        os.execv(os.environ["RECEIPT_TEST_CAST"], ["cast", *args])
    else:
        sys.exit("unexpected cast command")
elif command == "forge" and args[0] == "inspect":
    print("0x6000")
elif command == "forge" and args[0] == "script":
    if "--verify" in args:
        sys.exit("program verification must wait for receipt evidence")
    path = Path("broadcast/DeployBridgeProgram.s.sol/42431")
    if "--broadcast" not in args:
        path /= "dry-run"
    path.mkdir(parents=True)
    (path / "run-latest.json").write_text(json.dumps(fixture["sequence"]))
    if "--broadcast" in args:
        Path(os.environ["OUT"]).write_text(json.dumps(fixture["output"]))
    sent.touch()
elif command == "forge" and args[0] == "verify-contract":
    with (root / "verify-args.jsonl").open("a") as output:
        output.write(json.dumps(args) + "\n")
    verified.touch()
elif command == "curl":
    # Only the program needs verification; the factory and provider already have source matches.
    address = args[-1].split("?")[0].split("/")[-1].lower()
    print(json.dumps({"match": "perfect"} if verified.exists() or
                     address != fixture["output"]["program"] else {}))
else:
    sys.exit("unexpected fixture command")
'''


class ReleaseReceipts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CAST or not shutil.which("jq"):
            raise RuntimeError("cast and jq are required for offline receipt tests")
        cls.topic = cast("keccak", "ProgramDeployed(address,bytes32,address)")
        cls.salt = cast("keccak", "tempoxyz/earn shared factory release")
        factory_init = CREATION_CODE + cast("abi-encode", "f(address)", ROUTER_FACTORY)[2:]
        provider_init = CREATION_CODE + cast(
            "abi-encode", "f(address,bytes32)", FACTORY, PROGRAM_ID
        )[2:]
        cls.card_factory = create2(CREATE2_DEPLOYER, cls.salt, factory_init)
        cls.provider = create2(CREATE2_DEPLOYER, cls.salt, provider_init)
        program_init = CREATION_CODE + cast(
            "abi-encode", "f(address,address)", cls.provider, ROUTER_FACTORY
        )[2:]
        program_salt = cast(
            "keccak", cast("abi-encode", "f(bytes32,address)", PROGRAM_ID, cls.provider)
        )
        cls.program = create2(cls.card_factory, program_salt, program_init)
        cls.factory_init = factory_init
        cls.provider_init = provider_init
        cls.call = cast("calldata", "deploy(bytes32,address)", PROGRAM_ID, cls.provider)

    def event(self):
        return {
            "address": self.card_factory,
            "data": "0x",
            "removed": False,
            "topics": [
                self.topic,
                address_topic(self.program),
                PROGRAM_ID,
                address_topic(self.provider),
            ],
            "transactionHash": HASH,
        }

    def receipt(self, logs=None):
        return {"transactionHash": HASH, "status": "0x1", "logs": [] if logs is None else logs}

    def classify(self, receipt):
        args = ["jq", "-r"]
        for key, value in {
            "factory": self.card_factory,
            "program": self.program,
            "programId": PROGRAM_ID,
            "provider": self.provider,
            "topic": self.topic,
        }.items():
            args.extend(["--arg", key, value])
        return subprocess.run(
            [*args, "-f", str(HERE / "program-receipt.jq")],
            input=json.dumps(receipt), text=True, capture_output=True, timeout=60,
        )

    def fixture(self, logs=None):
        return {
            "missing": [self.program],
            "missingAfter": [],
            "output": {
                "cardFactory": self.card_factory,
                "provider": self.provider,
                "program": self.program,
                # Forge's simulation predicted creation, even if someone else later won the race.
                "created": True,
            },
            "sequence": {
                "transactions": [{
                    "hash": HASH,
                    "transaction": {"to": self.card_factory, "input": self.call},
                }],
                "receipts": [self.receipt(logs)],
            },
        }

    def release(self, fixture, broadcast=True):
        with tempfile.TemporaryDirectory(prefix="bridge-release-receipts-") as directory:
            root = Path(directory)
            scripts = root / "cards/script/bridge/deploy"
            scripts.mkdir(parents=True)
            for name in ("release.sh", "program-receipt.jq"):
                shutil.copyfile(HERE / name, scripts / name)
            (root / "fixture.json").write_text(json.dumps(fixture))
            binaries = root / "bin"
            binaries.mkdir()
            for command in ("cast", "forge", "curl"):
                path = binaries / command
                path.write_text(COMMANDS)
                path.chmod(0o755)
            result = root / "result.json"
            env = {
                **os.environ,
                "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                "RECEIPT_TEST_ROOT": str(root),
                "RECEIPT_TEST_CAST": CAST,
                "DEPLOYER_PRIVATE_KEY": "synthetic-unused-key",
                "FACTORY": FACTORY,
                "SPENDER_ID": PROGRAM_ID,
                "ROUTER_FACTORY": ROUTER_FACTORY,
                "RESULT": str(result),
                "TEMPO_RPC_URL": "https://offline.invalid",
                "TEMPO_RPC_USERNAME": "",
                "TEMPO_RPC_PASSWORD": "",
                "GITHUB_ACTIONS": "false",
            }
            run = subprocess.run(
                ["bash", str(scripts / "release.sh"), "moderato", "bridgeProgram",
                 *(["--broadcast"] if broadcast else [])],
                cwd=root, env=env, capture_output=True, text=True, timeout=180,
            )
            state = json.loads(result.read_text())
            verify = root / "verify-args.jsonl"
            calls = (
                [json.loads(line) for line in verify.read_text().splitlines()]
                if verify.exists() else []
            )
            return run, state, calls

    def test_exact_event_is_creation_evidence(self):
        receipt = self.receipt([self.event()])
        for case in (receipt, json.loads(json.dumps(receipt).replace("ab", "AB"))):
            with self.subTest(receipt=case):
                result = self.classify(case)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "true")

    def test_successful_noop_is_reuse(self):
        result = self.classify(self.receipt())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "false")

    def test_unrelated_or_removed_events_are_not_creation_evidence(self):
        event = self.event()
        cases = [
            {**event, "address": FACTORY},
            {**event, "data": "0x00"},
            {**event, "removed": True},
            {**event, "transactionHash": OTHER_HASH},
            {**event, "topics": event["topics"][:-1]},
            {**event, "topics": [*event["topics"], HASH]},
        ]
        for index in range(4):
            changed = copy.deepcopy(event)
            changed["topics"][index] = "0x" + "ef" * 32
            cases.append(changed)
        for log in cases:
            with self.subTest(log=log):
                result = self.classify(self.receipt([log]))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "false")

    def test_incomplete_or_duplicate_receipt_evidence_fails(self):
        cases = [
            {"transactionHash": HASH, "status": "0x1"},
            {**self.receipt([self.event()]), "status": "0x0"},
            self.receipt([self.event(), self.event()]),
        ]
        for receipt in cases:
            with self.subTest(receipt=receipt):
                self.assertNotEqual(self.classify(receipt).returncode, 0)

    def test_creating_hash_is_recorded_and_forwarded_to_verifier(self):
        run, state, calls = self.release(self.fixture([self.event()]))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(state["output"]["created"])
        self.assertTrue(state["contracts"][2]["created"])
        self.assertEqual(state["contracts"][2]["transaction"], HASH)
        self.assertEqual(len(calls), 1)
        index = calls[0].index("--creation-transaction-hash")
        self.assertEqual(calls[0][index + 1], HASH)
        self.assertIn("(created)", run.stdout)

    def test_noop_hash_is_never_recorded_or_forwarded_to_verifier(self):
        run, state, calls = self.release(self.fixture())
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(state["output"]["created"])
        self.assertFalse(state["contracts"][2]["created"])
        self.assertFalse(state["contracts"][2]["existed"])
        self.assertNotIn("transaction", state["contracts"][2])
        self.assertEqual(len(calls), 1)
        self.assertNotIn("--creation-transaction-hash", calls[0])
        self.assertNotIn(HASH, calls[0])
        self.assertIn("CardSpender", run.stdout)
        self.assertIn("(already deployed)", run.stdout)
        self.assertNotIn("(created)", run.stdout)

    def test_another_receipts_event_cannot_certify_noop(self):
        fixture = self.fixture()
        other = self.receipt([self.event()])
        other["transactionHash"] = OTHER_HASH
        other["logs"][0]["transactionHash"] = OTHER_HASH
        fixture["sequence"]["receipts"].append(other)
        run, state, calls = self.release(fixture)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(state["output"]["created"])
        self.assertNotIn("transaction", state["contracts"][2])
        self.assertNotIn("--creation-transaction-hash", calls[0])

    def test_preexisting_program_remains_reuse(self):
        fixture = self.fixture()
        fixture["missing"] = []
        fixture["output"]["created"] = False
        fixture["sequence"] = {"transactions": [], "receipts": []}
        run, state, calls = self.release(fixture)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(state["existed"])
        self.assertFalse(state["output"]["created"])
        self.assertTrue(all(not item["created"] for item in state["contracts"]))
        self.assertNotIn("--creation-transaction-hash", calls[0])

    def test_direct_creations_keep_their_receipt_hashes(self):
        fixture = self.fixture([self.event()])
        for name, address, init, byte in (
            ("CardFactory", self.card_factory, self.factory_init, "dd"),
            ("BridgeProvider", self.provider, self.provider_init, "ee"),
        ):
            tx_hash = "0x" + byte * 32
            fixture["missing"].append(address)
            fixture["sequence"]["transactions"].insert(0, {
                "hash": tx_hash, "transactionType": "CREATE2", "contractName": name,
                "contractAddress": address, "transaction": {"input": self.salt + init[2:]},
            })
            fixture["sequence"]["receipts"].append({"transactionHash": tx_hash, "status": "0x1"})
        run, state, _ = self.release(fixture)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(all(item["created"] for item in state["contracts"]))
        self.assertEqual([item["transaction"] for item in state["contracts"]],
                         ["0x" + "dd" * 32, "0x" + "ee" * 32, HASH])

    def test_missing_failed_or_ambiguous_receipt_blocks_release(self):
        for receipts in (
            [],
            [{**self.receipt([self.event()]), "status": "0x0"}],
            [self.receipt(), self.receipt([self.event()])],
            [{"transactionHash": HASH, "status": "0x1"}],
        ):
            with self.subTest(receipts=receipts):
                fixture = self.fixture()
                fixture["sequence"]["receipts"] = receipts
                run, state, calls = self.release(fixture)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn("error", state)
                self.assertNotIn("transaction", state["contracts"][2])
                self.assertEqual(calls, [])

    def test_noop_still_requires_deployed_code(self):
        fixture = self.fixture()
        fixture["missingAfter"] = [self.program]
        run, state, calls = self.release(fixture)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("has no code after the broadcast", state["error"])
        self.assertEqual(calls, [])

    def test_dry_run_needs_no_receipt_and_claims_no_creation(self):
        fixture = self.fixture()
        fixture["sequence"]["receipts"] = []
        run, state, calls = self.release(fixture, broadcast=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn("transaction", state["contracts"][2])
        self.assertNotIn("created", state["contracts"][2])
        self.assertIn("(would be created)", run.stdout)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)

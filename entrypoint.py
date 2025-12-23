#!/usr/bin/env python3
"""Assert-P4 Entrypoint - Runs P4 assertion verification and outputs JSON results"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
import glob

def run_cmd(cmd, timeout=60, cwd=None):
    """Run command with Python 3.5+ compatible subprocess"""
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        universal_newlines=True
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
        return proc.returncode, stdout, stderr
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise

def main():
    if len(sys.argv) < 2:
        print(json.dumps({
            "error": "Usage: assert-p4 <p4_file> [forwarding_rules.txt] [timeout_seconds]",
            "verdict": "error"
        }), file=sys.stderr)
        sys.exit(1)

    p4_file = sys.argv[1]
    forwarding_rules = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].isdigit() else None
    timeout = int(sys.argv[-1]) if sys.argv[-1].isdigit() else 300

    # Validate input file
    if not os.path.isfile(p4_file):
        print(json.dumps({"error": "P4 file not found: {}".format(p4_file), "verdict": "error"}))
        sys.exit(1)

    # Create temp directory for working files
    with tempfile.TemporaryDirectory() as work_dir:
        basename = os.path.splitext(os.path.basename(p4_file))[0]
        json_file = os.path.join(work_dir, "{}.json".format(basename))
        c_file = os.path.join(work_dir, "{}.c".format(basename))
        bc_file = os.path.join(work_dir, "{}.bc".format(basename))
        klee_out_dir = os.path.join(work_dir, "klee-out")

        start_time = time.time()
        full_log = []

        # Step 1: Compile P4 to JSON using p4c-bm2-ss
        try:
            returncode, stdout, stderr = run_cmd(
                ["p4c-bm2-ss", p4_file, "--toJSON", json_file],
                timeout=60
            )
            p4c_output = stdout + stderr
            full_log.append("=== P4C Compilation ===\n{}".format(p4c_output))
        except subprocess.TimeoutExpired:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({"verdict": "error", "time_ms": elapsed_ms, "details": "P4C timeout"}))
            sys.exit(1)
        except Exception as e:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({"verdict": "error", "time_ms": elapsed_ms, "details": "P4C error: {}".format(e)}))
            sys.exit(1)

        if returncode != 0 or not os.path.isfile(json_file):
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({
                "verdict": "error",
                "time_ms": elapsed_ms,
                "details": "P4C compilation failed:\n{}".format(p4c_output)
            }))
            sys.exit(1)

        # Step 2: Translate JSON to C using P4_to_C.py
        try:
            p4_to_c_cmd = ["python", "/assert-p4/src/P4_to_C.py", json_file]
            if forwarding_rules and os.path.isfile(forwarding_rules):
                p4_to_c_cmd.append(forwarding_rules)
            
            returncode, stdout, stderr = run_cmd(
                p4_to_c_cmd,
                timeout=120,
                cwd="/assert-p4/src"
            )
            full_log.append("=== P4 to C Translation ===\nstderr: {}".format(stderr))
        except subprocess.TimeoutExpired:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({"verdict": "error", "time_ms": elapsed_ms, "details": "P4 to C translation timeout"}))
            sys.exit(1)
        except Exception as e:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({"verdict": "error", "time_ms": elapsed_ms, "details": "P4 to C translation error: {}".format(e)}))
            sys.exit(1)

        if returncode != 0:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({
                "verdict": "error",
                "time_ms": elapsed_ms,
                "details": "P4 to C translation failed:\n{}".format(stderr)
            }))
            sys.exit(1)

        # Write C code to file
        with open(c_file, 'w') as f:
            f.write(stdout)

        # Step 3: Compile C to LLVM bitcode using clang
        try:
            returncode, stdout, stderr = run_cmd(
                ["clang", "-emit-llvm", "-g", "-c", c_file, "-o", bc_file],
                timeout=60
            )
            clang_output = stdout + stderr
            full_log.append("=== Clang Compilation ===\n{}".format(clang_output))
        except subprocess.TimeoutExpired:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({"verdict": "error", "time_ms": elapsed_ms, "details": "Clang compilation timeout"}))
            sys.exit(1)
        except Exception as e:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({"verdict": "error", "time_ms": elapsed_ms, "details": "Clang error: {}".format(e)}))
            sys.exit(1)

        if returncode != 0 or not os.path.isfile(bc_file):
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({
                "verdict": "error",
                "time_ms": elapsed_ms,
                "details": "Clang compilation failed:\n{}".format(clang_output)
            }))
            sys.exit(1)

        # Step 4: Run KLEE symbolic execution
        timed_out = False
        try:
            returncode, stdout, stderr = run_cmd(
                ["klee", "--search=dfs", "--output-dir=" + klee_out_dir, "--optimize", bc_file],
                timeout=timeout
            )
            klee_output = stdout + stderr
            full_log.append("=== KLEE Execution ===\n{}".format(klee_output))
        except subprocess.TimeoutExpired:
            klee_output = "Timeout after {}s".format(timeout)
            full_log.append("=== KLEE Execution (Timeout) ===\n{}".format(klee_output))
            timed_out = True
            returncode = -1

        elapsed_ms = int((time.time() - start_time) * 1000)

        # Parse KLEE output for assertion failures
        assertion_errors = []
        err_files = []
        if os.path.isdir(klee_out_dir):
            # Check for .assert.err files
            err_files = glob.glob(os.path.join(klee_out_dir, "*.assert.err"))
            for err_file in err_files:
                try:
                    with open(err_file, 'r') as f:
                        assertion_errors.append(f.read())
                except:
                    pass

        # Determine verdict
        if "ASSERTION FAIL" in klee_output or "abort failure" in klee_output or err_files:
            verdict = "false"
        elif timed_out:
            verdict = "unknown"
        elif "KLEE: done:" in klee_output and not assertion_errors:
            verdict = "true"
        elif returncode != 0:
            verdict = "error"
        else:
            verdict = "true"

        # Build result
        result = {
            "verdict": verdict,
            "time_ms": elapsed_ms,
            "details": "\n".join(full_log)
        }

        if assertion_errors:
            result["assertion_errors"] = assertion_errors

        print(json.dumps(result))

if __name__ == "__main__":
    main()

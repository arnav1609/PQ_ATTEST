# PQ-Attest: Python Reference Model Explanation

This document explains the code that has been implemented in the project so far. 

The codebase currently contains a **from-scratch software reference model in Python** for Keccak-based cryptography. Specifically, it builds up the stack from the core Keccak permutation all the way to **KMAC128**, which is then used as a Key Derivation Function (KDF) for a system called **PQ-Attest**. Finally, it generates "Golden Test Vectors" to help test and verify future hardware implementations (like SystemVerilog).

Here is a breakdown of each file and how they build on top of each other:

## 1. `software/keccak_ref.py` (The Core Engine)
This file implements the foundational **Keccak-f[1600]** permutation function, which is the mathematical core of the SHA-3 family of algorithms.
- **State Representation:** It manages a 1600-bit state represented as a 5x5 grid of 64-bit lanes.
- **Transformations:** It faithfully implements the 5 internal step mappings of Keccak:
  - `theta(state)`: Provides diffusion by mixing columns.
  - `rho(state)`: Provides dispersion by rotating lanes.
  - `pi(state)`: Rearranges the lanes.
  - `chi(state)`: Provides non-linearity using XOR, NOT, and AND gates.
  - `iota(state)`: Breaks symmetry by adding round constants.
- **`keccak_f1600(state)`**: Chains the above transformations over 24 rounds.

## 2. `software/sha3_256_ref.py` (Standard Hashing)
This builds on top of `keccak_ref.py` to provide a standard **SHA3-256** implementation.
- **Padding:** Implements the `sha3_pad` function using the standard `0x06` domain separation suffix and `10*1` padding.
- **Sponge Construction:** 
  - `absorb_block`: XORs 136-byte blocks of the input message into the Keccak state.
  - `squeeze`: Extracts the 32-byte (256-bit) digest from the state after processing.
- The `if __name__ == "__main__":` block runs tests comparing its output to Python's built-in `hashlib.sha3_256` to ensure it is mathematically correct.

## 3. `software/kmac128_ref.py` (Advanced MAC & KDF)
This file implements the **NIST SP 800-185** standard functions (cSHAKE and KMAC) and uses them to create a Key Derivation Function.
- **Encoding Utils:** Implements `left_encode`, `right_encode`, `encode_string`, and `bytepad`, which are required by the SP 800-185 standard to format data before hashing.
- **`cSHAKE128`**: A customizable variant of SHAKE128 that takes a `function_name` and `customization` string to separate different cryptographic domains.
- **`kmac128`**: A Keyed-Hash Message Authentication Code built on top of cSHAKE128.
- **`derive_tile_key`**: This is the **PQ-Attest specific** function. It uses `kmac128` to derive a unique cryptographic key for a specific hardware "tile". It combines a `root_secret` with a `tile_id`, `epoch`, and `context` string to ensure every context gets a cryptographically separated, unique key.

## 4. `software/kdf_vectors.py` & `kdf_vectors.txt` (Verification/Testing)
This script is used to generate known-good outputs ("Golden Vectors") that will be used to test other implementations of the hardware (e.g., in SystemVerilog).
- It runs the `derive_tile_key` function through 6 different test cases (varying the tile ID, epoch, context, and output key length).
- **`verify_expected_vectors`**: Checks the outputs against hardcoded frozen values to prevent regressions.
- **`write_sv_vectors`**: Outputs the results to `kdf_vectors.txt` in a simple pipe-separated format (`ROOT_SECRET | TILE_ID | ... | EXPECTED_KEY`) so that a hardware testbench can easily read them using `$fscanf()` and verify the hardware behaves exactly like this Python reference.

---
## Summary of the Flow
1. **Keccak Permutation** (`keccak_ref.py`)
2. ↳ **Sponge Construction** (`kmac128_ref.py` / `sha3_256_ref.py`)
3. ↳ **KMAC128** (`kmac128_ref.py`)
4. ↳ **Tile Key Derivation** (`kmac128_ref.py`)
5. ↳ **Test Vector Generation** (`kdf_vectors.py`) -> Outputs to `kdf_vectors.txt`

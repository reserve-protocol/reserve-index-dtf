#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)
TOOLS_DIR=${CERTORA_TOOLS_DIR:-"$ROOT_DIR/.certora"}
DOWNLOADS_DIR="$TOOLS_DIR/downloads"
BIN_DIR="$TOOLS_DIR/bin"
SOURCE_DIR="$TOOLS_DIR/CertoraProver"
INSTALL_DIR="$TOOLS_DIR/prover"
VERSION_FILE="$TOOLS_DIR/version"

CERTORA_VERSION=8.9.0
CERTORA_COMMIT=b03323ecdc2dd73a9f0904012eac8b5027eaa65f
JAVA_VERSION=21.0.12.1
RUST_VERSION=1.98.1
INSTALL_VERSION="$CERTORA_COMMIT-toolchain-1"

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo "The automated setup currently supports Linux x86_64 only." >&2
    echo "For other platforms, build CertoraProver $CERTORA_VERSION using certora/README.md." >&2
    exit 1
fi

for command in curl git python3 sha256sum tar unzip; do
    if ! command -v "$command" >/dev/null; then
        echo "Missing required command: $command" >&2
        exit 1
    fi
done

installation_complete() {
    local file
    for file in \
        "$TOOLS_DIR/jdk/bin/java" \
        "$TOOLS_DIR/venv/bin/python" \
        "$BIN_DIR/z3" \
        "$BIN_DIR/cvc4" \
        "$BIN_DIR/cvc5" \
        "$BIN_DIR/yices-smt2" \
        "$BIN_DIR/solc8.28" \
        "$INSTALL_DIR/certoraRun.py"; do
        [[ -x $file ]] || return 1
    done
    [[ -f $INSTALL_DIR/emv.jar ]]
}

if [[ -f $VERSION_FILE ]] && [[ $(<"$VERSION_FILE") == "$INSTALL_VERSION" ]] && installation_complete; then
    echo "CertoraProver $CERTORA_VERSION is already installed in $TOOLS_DIR"
    exit 0
fi

mkdir -p "$DOWNLOADS_DIR" "$BIN_DIR"

download() {
    local url=$1
    local checksum=$2
    local destination=$3

    if [[ ! -f $destination ]] || ! echo "$checksum  $destination" | sha256sum --check --status; then
        curl --fail --location --retry 3 --output "$destination" "$url"
    fi
    echo "$checksum  $destination" | sha256sum --check --status
}

download_github_asset() {
    local url=$1
    local checksum=$2
    local destination=$3

    if [[ ! -f $destination ]] || ! echo "$checksum  $destination" | sha256sum --check --status; then
        curl --fail --location --retry 3 \
            --header "Accept: application/octet-stream" \
            --output "$destination" \
            "$url"
    fi
    echo "$checksum  $destination" | sha256sum --check --status
}

echo "Installing the local Certora toolchain in $TOOLS_DIR"

JDK_ARCHIVE="$DOWNLOADS_DIR/temurin-jdk-$JAVA_VERSION.tar.gz"
download \
    "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz" \
    ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94 \
    "$JDK_ARCHIVE"
rm -rf "$TOOLS_DIR/jdk"
mkdir "$TOOLS_DIR/jdk"
tar --extract --gzip --file "$JDK_ARCHIVE" --strip-components=1 --directory "$TOOLS_DIR/jdk"

Z3_ARCHIVE="$DOWNLOADS_DIR/z3-4.13.4.zip"
download \
    "https://github.com/Z3Prover/z3/releases/download/z3-4.13.4/z3-4.13.4-x64-glibc-2.35.zip" \
    93f91f9c6f4a00a041c19fc7a74adc1f441c8244ce70d486e19abcd89c6a014b \
    "$Z3_ARCHIVE"
unzip -p "$Z3_ARCHIVE" z3-4.13.4-x64-glibc-2.35/bin/z3 > "$BIN_DIR/z3"
chmod +x "$BIN_DIR/z3"

CVC5_ARCHIVE="$DOWNLOADS_DIR/cvc5-1.3.4.zip"
download \
    "https://github.com/cvc5/cvc5/releases/download/cvc5-1.3.4/cvc5-Linux-x86_64-static.zip" \
    dcdbfada0ce493ee98259c0816e0daafc561c223aadb3af298c2968e73ea39c6 \
    "$CVC5_ARCHIVE"
unzip -p "$CVC5_ARCHIVE" cvc5-Linux-x86_64-static/bin/cvc5 > "$BIN_DIR/cvc5"
chmod +x "$BIN_DIR/cvc5"

download_github_asset \
    "https://api.github.com/repos/cvc5/cvc5/releases/assets/24275597" \
    d38a79cf984592785eda41ec888d94ca107ac1f13058740238041e28c8472e51 \
    "$BIN_DIR/cvc4"
chmod +x "$BIN_DIR/cvc4"

YICES_ARCHIVE="$DOWNLOADS_DIR/yices-2.7.0.tar.gz"
download \
    "https://github.com/SRI-CSL/yices2/releases/download/yices-2.7.0/yices-2.7.0-x86_64-pc-linux-gnu-static-gmp.tar.gz" \
    49566b6f817692820538df78fe406878400d79810631c9372b2495bc81d3e00a \
    "$YICES_ARCHIVE"
tar --extract --gzip --file "$YICES_ARCHIVE" \
    --strip-components=2 \
    --to-stdout \
    yices-2.7.0/bin/yices-smt2 > "$BIN_DIR/yices-smt2"
chmod +x "$BIN_DIR/yices-smt2"

download \
    "https://github.com/argotorg/solidity/releases/download/v0.8.28/solc-static-linux" \
    9a0fb7e0db2c0641dbae1c5cc645dc686820c83af516226abb1c0a2f76636f25 \
    "$BIN_DIR/solc8.28"
chmod +x "$BIN_DIR/solc8.28"
ln -sfn solc8.28 "$BIN_DIR/solc"

RUSTUP_INIT="$DOWNLOADS_DIR/rustup-init-1.29.1"
download \
    "https://static.rust-lang.org/rustup/archive/1.29.1/x86_64-unknown-linux-gnu/rustup-init" \
    dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71 \
    "$RUSTUP_INIT"
chmod +x "$RUSTUP_INIT"
RUSTUP_HOME="$TOOLS_DIR/rustup" CARGO_HOME="$TOOLS_DIR/cargo" \
    "$RUSTUP_INIT" --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION" -y

rm -rf "$SOURCE_DIR" "$INSTALL_DIR"
git -c url."https://github.com/".insteadOf="git@github.com:" clone \
    --branch "$CERTORA_VERSION" \
    --depth 1 \
    --recurse-submodules \
    https://github.com/Certora/CertoraProver.git \
    "$SOURCE_DIR"

if [[ $(git -C "$SOURCE_DIR" rev-parse HEAD) != "$CERTORA_COMMIT" ]]; then
    echo "CertoraProver tag $CERTORA_VERSION does not match the expected commit." >&2
    exit 1
fi

printf '\ndistributionSha256Sum=%s\n' \
    f581709a9c35e9cb92e16f585d2c4bc99b2b1a5f85d2badbd3dc6bff59e1e6dd \
    >> "$SOURCE_DIR/gradle/wrapper/gradle-wrapper.properties"

rm -rf "$TOOLS_DIR/venv"
python3 -m venv "$TOOLS_DIR/venv"
"$TOOLS_DIR/venv/bin/pip" install \
    --disable-pip-version-check \
    --requirement "$ROOT_DIR/certora/requirements.txt"

(
    cd "$SOURCE_DIR"
    export JAVA_HOME="$TOOLS_DIR/jdk"
    export RUSTUP_HOME="$TOOLS_DIR/rustup"
    export CARGO_HOME="$TOOLS_DIR/cargo"
    export RUSTUP_TOOLCHAIN="$RUST_VERSION"
    export CERTORA="$INSTALL_DIR"
    export PATH="$JAVA_HOME/bin:$CARGO_HOME/bin:$BIN_DIR:$PATH"
    ./gradlew copy-assets --no-daemon
)

printf '%s\n' "$INSTALL_VERSION" > "$VERSION_FILE"
echo "CertoraProver $CERTORA_VERSION installed successfully."

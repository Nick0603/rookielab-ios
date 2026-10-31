#!/usr/bin/env bash
# 建置時把 Stockfish 的評估檔（NNUE）放進 App：沒有就下載到 ios/Vendor/nnue（不進 git），
# 檢查 SHA-256 跟檔名一致（Stockfish 的檔名就是內容雜湊的前 12 碼），再複製進 App bundle。
set -euo pipefail
DIR="${SRCROOT:-$(cd "$(dirname "$0")" && pwd)}/Vendor/nnue"
mkdir -p "$DIR"
for name in nn-1111cefa1111.nnue nn-37f18f62d772.nnue; do
  f="$DIR/$name"
  want="${name:3:12}"
  if [[ ! -f "$f" ]] || [[ "$(shasum -a 256 "$f" | cut -c1-12)" != "$want" ]]; then
    echo "下載 $name"
    curl -fsSL --retry 3 "https://tests.stockfishchess.org/api/nn/$name" -o "$f.tmp"
    got="$(shasum -a 256 "$f.tmp" | cut -c1-12)"
    [[ "$got" == "$want" ]] || { echo "error: $name 的雜湊不符（$got）"; rm -f "$f.tmp"; exit 1; }
    mv "$f.tmp" "$f"
  fi
  if [[ -n "${TARGET_BUILD_DIR:-}" ]]; then
    dst="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
    mkdir -p "$dst"
    cp -f "$f" "$dst/$name"
  fi
done

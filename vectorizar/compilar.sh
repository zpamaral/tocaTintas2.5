#!/bin/sh
# Compila o vectorizar para ../Resources, de onde o Xcode o copia para dentro da
# aplicação (como o bs2b_bridge, o raop_play e o cava). O modelo,
# clap_audio.mlmodelc, tem de estar na mesma pasta.
cd "$(dirname "$0")" || exit 1
clang -fobjc-arc -O2 -Wall -o ../Resources/vectorizar vectorizar.m -framework Foundation -framework CoreML -framework AudioToolbox -framework Accelerate -lsqlite3 && echo "feito: $(cd ../Resources && pwd)/vectorizar"

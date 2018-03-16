#!/bin/sh

curl -O https://raw.githubusercontent.com/BrunnerLivio/pokemongo-game-master/master/versions/latest/GAME_MASTER.json

json2yaml.rb GAME_MASTER.json >GAME_MASTER.yaml

patch <legacy_moves.patch && \
  diff -u GAME_MASTER.yaml.orig GAME_MASTER.yaml >legacy_moves.patch
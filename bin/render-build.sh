#!/usr/bin/env bash
# Render の Build Command から呼ばれるスクリプト。
# 失敗したら即座に停止する。
set -o errexit

bundle install

# Tailwind のビルドを含むアセットのプリコンパイル
bundle exec rails assets:precompile
bundle exec rails assets:clean

# DBの作成(未作成なら)+ マイグレーション/スキーマ適用
# primary / cache / queue / cable を同一DBに用意する
bundle exec rails db:prepare

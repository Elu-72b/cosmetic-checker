# CLAUDE.md — cosmetic-checker 開発ルール

化粧品の全成分表を撮影し、成分を危険度1(緑)〜5(赤)で色分け表示するRailsアプリ。

## 技術スタック

- Ruby on Rails 8 / PostgreSQL(pg_trgm) / Tailwind CSS / Stimulus / Turbo
- Gemini Flash API(画像からの成分抽出・成分情報の生成)
- Docker(開発) / Render(本番)

## Git運用ルール(必ず守る)

- **1フェーズ=1ブランチ=1PR**。ブランチ名は `feature/phaseN-xxx` 形式
- 1コミット=1つの意味のある変更。コミットメッセージは日本語で簡潔に
- `db:migrate` 後は `db/schema.rb` を、gem追加時は `Gemfile.lock` を必ずセットでコミット
- **`.env` は絶対にコミットしない**(APIキーが入っている)
- mainへの直接コミットはフェーズ0のみ。以降は必ずPR経由

## 設計上の原則(必ず守る)

- **画像は保存しない**: アップロード画像はメモリ上でBase64化してGeminiへ送るのみ。Active Storageやtmp保存は使わない
- **キャッシュ優先の検索**: 成分検索は「①DB完全一致 → ②pg_trgmあいまい検索 → ③Gemini APIで生成しDB保存」の順。②までで見つかればAPIを呼ばない
- **AI生成データの明示**: Gemini生成の成分情報は `ai_generated: true` を付け、画面に「AI生成」と表示する
- **出典と免責事項**: 成分詳細には出典(source / source_url)を表示。全ページに免責事項パーシャル(`shared/_disclaimer`)を表示
- 危険度の判定は @docs/RISK_CRITERIA.md の基準に従う。根拠不明な場合はデフォルト3

## コーディング規約

- 外部API呼び出しはサービスクラス(`app/services/`)に分離する
- API失敗時はアプリを止めず、該当成分のみ「情報を取得できませんでした」表示にする
- ビューの共通部品はパーシャル化する(バッジ一覧・免責事項など)

## 詳細ドキュメント

- 実装手順・フェーズ別コミット計画: @docs/DETAILED_PLAN.md
- フェーズ別チェックリスト(簡潔版): @docs/IMPLEMENTATION_PLAN.md
- 危険度1〜5の判定基準: @docs/RISK_CRITERIA.md
